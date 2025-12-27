defmodule PgGaConf.PatternMatcher do
  @moduledoc """
  Matches databases to workload patterns and returns validated knobs.

  This is the main entry point for the pattern-based knob selection system.
  At tuning time, it:

  1. Profiles the target database
  2. Finds the nearest validated pattern
  3. If similarity > threshold, returns the pattern's validated knobs
  4. Otherwise, signals that direct Sobol validation is needed

  ## Usage

      # Get knobs for a database
      case PatternMatcher.get_knobs_for_database(db_id, repo, profile_opts) do
        {:ok, %{knobs: knobs, source: :pattern_match}} ->
          # Use these knobs for optimization
          knobs

        {:needs_validation, reason} ->
          # No good pattern match, run Sobol directly
          PatternMatcher.handle_no_match(db_id, repo, benchmark_opts)
      end
  """

  require Logger

  import Ecto.Query

  alias PgGaConf.Workload.RichProfiler
  alias PgGaConf.PatternDiscovery
  alias PgGaConf.PatternValidation
  alias PgGaConf.Schema.{DatabaseProfile, WorkloadPattern, PatternAssignment}

  @similarity_threshold 0.85

  @doc """
  Get the knobs to use for optimizing a database.

  Returns either validated knobs from a matching pattern, or signals
  that direct validation is needed.

  ## Options

  - `:similarity_threshold` - Minimum similarity for pattern match (default: 0.85)
  - `:profile_opts` - Options passed to RichProfiler.profile/2

  ## Returns

  - `{:ok, result}` where result contains:
    - `knobs`: List of knob names (strings)
    - `source`: `:pattern_match` or `:custom`
    - `pattern_id`: Pattern ID if matched
    - `similarity`: Similarity score if matched
    - `description`: Pattern description if matched

  - `{:needs_validation, reason}` if no good match and Sobol should be run
  """
  @spec get_knobs_for_database(String.t(), Ecto.Repo.t(), Ecto.Repo.t(), keyword()) ::
          {:ok, map()} | {:needs_validation, map()}
  def get_knobs_for_database(db_id, profile_repo, pattern_repo, opts \\ []) do
    threshold = Keyword.get(opts, :similarity_threshold, @similarity_threshold)
    profile_opts = Keyword.get(opts, :profile_opts, [])

    # Step 1: Profile the database
    case RichProfiler.profile(profile_repo, profile_opts) do
      {:ok, profile} ->
        # Step 2: Save profile to history
        save_profile(db_id, profile, pattern_repo)

        # Step 3: Check for existing custom validation
        case get_custom_validation(db_id, pattern_repo) do
          {:ok, custom_knobs} ->
            Logger.info("Database #{db_id} has custom validated knobs")
            {:ok, %{knobs: custom_knobs, source: :custom}}

          :not_found ->
            # Step 4: Find nearest validated pattern
            find_matching_pattern(db_id, profile.feature_vector, pattern_repo, threshold)
        end

      {:error, reason} ->
        Logger.error("Failed to profile database #{db_id}: #{inspect(reason)}")
        {:needs_validation, %{reason: :profile_failed, error: reason}}
    end
  end

  @doc """
  Handle a database that doesn't match any pattern well.

  Runs Sobol analysis directly on the database and stores the results
  as custom validated knobs.

  ## Options

  - `:benchmark_fn` - Function to evaluate a config (required)
  - `:restart_fn` - Function to restart postgres (required)
  - `:sobol_samples` - Number of Sobol samples (default: 32)
  """
  @spec handle_no_match(String.t(), Ecto.Repo.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def handle_no_match(db_id, repo, opts) do
    benchmark_fn = Keyword.fetch!(opts, :benchmark_fn)
    restart_fn = Keyword.fetch!(opts, :restart_fn)
    samples = Keyword.get(opts, :sobol_samples, 32)
    threshold = Keyword.get(opts, :importance_threshold, 0.05)

    Logger.info("Running direct Sobol validation for database #{db_id}")

    knob_space = PgGaConf.KnobSpace.subset(PatternValidation.starter_knobs())

    case PgGaConf.Sobol.analyze(knob_space, benchmark_fn,
           n_samples: samples,
           restart_fn: restart_fn
         ) do
      {:ok, indices} ->
        validated_knobs =
          indices
          |> Enum.filter(fn {_knob, %{st: st}} -> st >= threshold end)
          |> Enum.sort_by(fn {_knob, %{st: st}} -> st end, :desc)
          |> Enum.map(fn {knob, _} -> Atom.to_string(knob) end)

        Logger.info("Database #{db_id}: validated #{length(validated_knobs)} knobs")

        # Save as custom validation
        save_custom_validation(db_id, validated_knobs, indices, repo)

        {:ok, %{knobs: validated_knobs, source: :direct_sobol}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get the current pattern assignment for a database.
  """
  @spec get_assignment(String.t(), Ecto.Repo.t()) :: PatternAssignment.t() | nil
  def get_assignment(db_id, repo) do
    repo.get(PatternAssignment, db_id)
    |> repo.preload(:pattern)
  end

  @doc """
  Reassign a database to the best matching pattern.
  """
  @spec reassign(String.t(), Ecto.Repo.t(), keyword()) :: {:ok, map()} | {:needs_validation, map()}
  def reassign(db_id, repo, opts \\ []) do
    threshold = Keyword.get(opts, :similarity_threshold, @similarity_threshold)

    # Get latest profile
    case get_latest_profile(db_id, repo) do
      {:ok, profile} ->
        find_matching_pattern(db_id, profile.feature_vector, repo, threshold)

      {:error, reason} ->
        {:needs_validation, %{reason: reason}}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp find_matching_pattern(db_id, feature_vector, repo, threshold) do
    # Get all validated patterns
    validated_patterns =
      from(p in WorkloadPattern,
        where: not is_nil(p.validated_knobs),
        select: p
      )
      |> repo.all()

    if Enum.empty?(validated_patterns) do
      Logger.info("No validated patterns available")
      {:needs_validation, %{reason: :no_patterns}}
    else
      # Find best match
      matches =
        validated_patterns
        |> Enum.map(fn pattern ->
          similarity = PatternDiscovery.cosine_similarity(feature_vector, pattern.centroid_vector)
          {pattern, similarity}
        end)
        |> Enum.sort_by(fn {_, sim} -> sim end, :desc)

      {best_pattern, best_similarity} = hd(matches)

      if best_similarity >= threshold do
        Logger.info(
          "Database #{db_id} matches pattern #{best_pattern.id} " <>
            "(similarity: #{Float.round(best_similarity, 3)})"
        )

        # Update assignment
        upsert_assignment(db_id, best_pattern.id, best_similarity, repo)

        {:ok,
         %{
           pattern_id: best_pattern.id,
           similarity: best_similarity,
           knobs: best_pattern.validated_knobs,
           source: :pattern_match,
           description: best_pattern.description
         }}
      else
        Logger.info(
          "Database #{db_id} has no good pattern match " <>
            "(best: #{Float.round(best_similarity, 3)} < #{threshold})"
        )

        {:needs_validation,
         %{
           best_pattern_id: best_pattern.id,
           best_similarity: best_similarity,
           reason: :low_similarity
         }}
      end
    end
  end

  defp save_profile(db_id, profile, repo) do
    %DatabaseProfile{}
    |> DatabaseProfile.changeset(%{
      db_id: db_id,
      feature_vector: profile.feature_vector,
      schema_features: profile.schema_features,
      query_features: profile.query_features,
      execution_features: profile.execution_features,
      io_features: profile.io_features,
      index_features: profile.index_features,
      runtime_features: profile.runtime_features,
      scale_features: profile.scale_features,
      has_pg_stat_statements: profile.has_pg_stat_statements,
      pg_version: profile.pg_version
    })
    |> repo.insert()
  end

  defp get_latest_profile(db_id, repo) do
    query =
      from(p in DatabaseProfile,
        where: p.db_id == ^db_id,
        order_by: [desc: p.captured_at],
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :no_profile}
      profile -> {:ok, profile}
    end
  end

  defp get_custom_validation(db_id, repo) do
    case repo.get(PatternAssignment, db_id) do
      %PatternAssignment{custom_validated_knobs: knobs}
      when is_list(knobs) and length(knobs) > 0 ->
        {:ok, knobs}

      _ ->
        :not_found
    end
  end

  defp save_custom_validation(db_id, knobs, indices, repo) do
    serialized_indices =
      Map.new(indices, fn {knob, %{s1: s1, st: st}} ->
        {Atom.to_string(knob), %{"s1" => s1, "st" => st}}
      end)

    repo.insert!(
      %PatternAssignment{
        db_id: db_id,
        custom_validated_knobs: knobs,
        custom_sobol_indices: serialized_indices,
        custom_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      on_conflict:
        {:replace, [:custom_validated_knobs, :custom_sobol_indices, :custom_validated_at]},
      conflict_target: :db_id
    )
  end

  defp upsert_assignment(db_id, pattern_id, similarity, repo) do
    repo.insert!(
      %PatternAssignment{
        db_id: db_id,
        pattern_id: pattern_id,
        similarity: similarity,
        assigned_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      on_conflict: {:replace, [:pattern_id, :similarity, :assigned_at]},
      conflict_target: :db_id
    )
  end
end
