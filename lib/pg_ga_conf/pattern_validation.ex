defmodule PgGaConf.PatternValidation do
  @moduledoc """
  Validates discovered patterns using Sobol sensitivity analysis.

  For each pattern, selects a representative database (closest to centroid)
  and runs Sobol analysis to determine which knobs actually matter for
  that workload pattern. The validated knobs are then stored on the pattern
  for reuse by all databases matching that pattern.

  ## Usage

      # Validate a specific pattern
      {:ok, pattern} = PatternValidation.validate_pattern(pattern, repo, benchmark_opts)

      # Get queue of patterns needing validation
      patterns = PatternValidation.get_validation_queue(repo)

      # Run validation job on all pending patterns
      PatternValidation.validate_pending(repo, benchmark_opts)
  """

  require Logger

  import Ecto.Query

  alias PgGaConf.Sobol
  alias PgGaConf.KnobSpace
  alias PgGaConf.PatternDiscovery
  alias PgGaConf.Schema.{WorkloadPattern, PatternAssignment, DatabaseProfile}

  @starter_knobs [
    # Memory - always relevant
    :shared_buffers,
    :work_mem,
    :effective_cache_size,
    :maintenance_work_mem,
    :hash_mem_multiplier,

    # Planner - affects query execution
    :random_page_cost,
    :effective_io_concurrency,
    :default_statistics_target,

    # Checkpointing - write workloads
    :checkpoint_completion_target,
    :max_wal_size,

    # Parallelism - complex queries
    :max_parallel_workers_per_gather,
    :max_parallel_workers,

    # Autovacuum - write/update workloads
    :autovacuum_vacuum_cost_limit,
    :autovacuum_vacuum_scale_factor,

    # WAL - write workloads
    :wal_buffers,
    :synchronous_commit
  ]

  @sobol_samples 32
  @importance_threshold 0.05

  @doc """
  Returns the starter knob set used for Sobol validation.
  """
  @spec starter_knobs() :: [atom()]
  def starter_knobs, do: @starter_knobs

  @doc """
  Validate a pattern using Sobol sensitivity analysis.

  Selects the representative database (closest to centroid), runs Sobol
  analysis, and stores the validated knobs on the pattern.

  ## Options

  - `:benchmark_fn` - Function that evaluates a config and returns a score (required)
  - `:restart_fn` - Function to restart postgres with new config (required)
  - `:sobol_samples` - Number of Sobol samples (default: 32)
  - `:importance_threshold` - ST threshold for knob inclusion (default: 0.05)
  """
  @spec validate_pattern(WorkloadPattern.t(), Ecto.Repo.t(), keyword()) ::
          {:ok, WorkloadPattern.t()} | {:error, term()}
  def validate_pattern(%WorkloadPattern{} = pattern, repo, opts) do
    benchmark_fn = Keyword.fetch!(opts, :benchmark_fn)
    restart_fn = Keyword.fetch!(opts, :restart_fn)
    samples = Keyword.get(opts, :sobol_samples, @sobol_samples)
    threshold = Keyword.get(opts, :importance_threshold, @importance_threshold)

    Logger.info("Validating pattern #{pattern.id} (#{pattern.member_count} members)")

    # Find representative database
    case find_representative(pattern, repo) do
      {:ok, representative} ->
        Logger.info("Using database #{representative.db_id} as representative")

        # Run Sobol analysis
        knob_space = KnobSpace.subset(@starter_knobs)

        case Sobol.analyze(knob_space, benchmark_fn,
               n_samples: samples,
               restart_fn: restart_fn
             ) do
          {:ok, indices} ->
            # Extract important knobs
            validated_knobs =
              indices
              |> Enum.filter(fn {_knob, %{st: st}} -> st >= threshold end)
              |> Enum.sort_by(fn {_knob, %{st: st}} -> st end, :desc)
              |> Enum.map(fn {knob, _} -> Atom.to_string(knob) end)

            Logger.info(
              "Pattern #{pattern.id}: validated #{length(validated_knobs)} knobs: " <>
                Enum.join(validated_knobs, ", ")
            )

            # Update pattern
            pattern
            |> WorkloadPattern.changeset(%{
              validated_knobs: validated_knobs,
              sobol_indices: serialize_indices(indices),
              sobol_validated_at: DateTime.utc_now() |> DateTime.truncate(:second),
              sobol_db_id: representative.db_id
            })
            |> repo.update()

          {:error, reason} ->
            Logger.error("Sobol analysis failed for pattern #{pattern.id}: #{inspect(reason)}")
            {:error, {:sobol_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Find patterns that need validation, ordered by member count (largest first).
  """
  @spec get_validation_queue(Ecto.Repo.t(), keyword()) :: [WorkloadPattern.t()]
  def get_validation_queue(repo, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    query =
      from(p in WorkloadPattern,
        where: is_nil(p.validated_knobs),
        order_by: [desc: p.member_count],
        limit: ^limit
      )

    repo.all(query)
  end

  @doc """
  Validate all pending patterns in the queue.
  """
  @spec validate_pending(Ecto.Repo.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_pending(repo, opts) do
    queue = get_validation_queue(repo, opts)

    results =
      Enum.map(queue, fn pattern ->
        case validate_pattern(pattern, repo, opts) do
          {:ok, validated} ->
            {:ok, validated.id}

          {:error, reason} ->
            {:error, {pattern.id, reason}}
        end
      end)

    successes = Enum.filter(results, &match?({:ok, _}, &1)) |> length()
    failures = Enum.filter(results, &match?({:error, _}, &1))

    {:ok,
     %{
       validated: successes,
       failed: length(failures),
       failures: failures
     }}
  end

  @doc """
  Check if a pattern needs revalidation.

  A pattern needs revalidation if:
  - It has never been validated
  - Its centroid has drifted significantly since validation
  """
  @spec needs_revalidation?(WorkloadPattern.t(), Ecto.Repo.t()) :: boolean()
  def needs_revalidation?(%WorkloadPattern{validated_knobs: nil}, _repo), do: true

  def needs_revalidation?(%WorkloadPattern{} = pattern, repo) do
    # Check if the current centroid differs significantly from when validated
    case get_current_centroid(pattern, repo) do
      {:ok, current_centroid} ->
        drift = PatternDiscovery.cosine_distance(pattern.centroid_vector, current_centroid)
        # Revalidate if drift > 0.15
        drift > 0.15

      _ ->
        false
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp find_representative(%WorkloadPattern{id: pattern_id, centroid_vector: centroid}, repo) do
    # Get all assignments for this pattern with their profiles
    assignments =
      from(a in PatternAssignment,
        where: a.pattern_id == ^pattern_id,
        select: a.db_id
      )
      |> repo.all()

    if Enum.empty?(assignments) do
      {:error, :no_members}
    else
      # Find the profile closest to centroid
      profiles =
        from(p in DatabaseProfile,
          where: p.db_id in ^assignments,
          distinct: p.db_id,
          order_by: [desc: p.captured_at]
        )
        |> repo.all()

      if Enum.empty?(profiles) do
        {:error, :no_profiles}
      else
        closest =
          profiles
          |> Enum.min_by(fn p ->
            PatternDiscovery.cosine_distance(p.feature_vector, centroid)
          end)

        {:ok, closest}
      end
    end
  end

  defp get_current_centroid(%WorkloadPattern{id: pattern_id}, repo) do
    # Get current member profiles and recompute centroid
    assignments =
      from(a in PatternAssignment,
        where: a.pattern_id == ^pattern_id,
        select: a.db_id
      )
      |> repo.all()

    if Enum.empty?(assignments) do
      {:error, :no_members}
    else
      profiles =
        from(p in DatabaseProfile,
          where: p.db_id in ^assignments,
          distinct: p.db_id,
          order_by: [desc: p.captured_at],
          select: p.feature_vector
        )
        |> repo.all()

      if Enum.empty?(profiles) do
        {:error, :no_profiles}
      else
        centroid = compute_centroid(profiles)
        {:ok, centroid}
      end
    end
  end

  defp compute_centroid(vectors) do
    n = length(vectors)
    dim = length(hd(vectors))

    Enum.reduce(vectors, List.duplicate(0.0, dim), fn vec, acc ->
      Enum.zip(acc, vec) |> Enum.map(fn {a, v} -> a + v end)
    end)
    |> Enum.map(&(&1 / n))
  end

  defp serialize_indices(indices) do
    Map.new(indices, fn {knob, %{s1: s1, st: st}} ->
      {Atom.to_string(knob), %{"s1" => s1, "st" => st}}
    end)
  end
end
