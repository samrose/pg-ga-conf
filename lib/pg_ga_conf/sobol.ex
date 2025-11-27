defmodule PgGaConf.Sobol do
  @moduledoc """
  Sobol sensitivity analysis orchestration.

  Coordinates Sobol variance-based global sensitivity analysis via the Julia backend.
  Uses workload fingerprints for caching - similar workloads can reuse sensitivity results.

  ## Workflow

  1. Extract workload fingerprint
  2. Check cache for similar fingerprint (similarity > threshold)
  3. If cache hit: return cached sensitivity indices
  4. If cache miss: run full Sobol analysis via Julia
  5. Cache results with fingerprint

  ## Sensitivity Indices

  Returns first-order (Si) and total-order (STi) Sobol indices:
  - Si: Direct effect of parameter (independent contribution)
  - STi: Total effect including interactions with other parameters
  - High STi - Si gap indicates strong parameter interactions

  ## Usage

  ```elixir
  # Analyze sensitivity for specific knobs
  {:ok, indices} = PgGaConf.Sobol.analyze(knobs, benchmark_fn)

  # Get important knobs (STi > threshold)
  important = PgGaConf.Sobol.filter_important(indices, threshold: 0.05)
  ```
  """

  alias PgGaConf.{Julia, Fingerprint, KnobSpace}
  alias PgGaConf.Benchmark.Pgbench
  alias PgGaConf.Schema.SobolCache

  require Logger

  @default_n_samples 128
  @similarity_threshold 0.95
  @importance_threshold 0.05

  @type sensitivity_indices :: %{
          atom() => %{
            s1: float(),
            st: float()
          }
        }

  @doc """
  Run Sobol sensitivity analysis for the given knob space.

  ## Options

  - `:n_samples` - Number of Sobol samples (default: 128, creates 2*(n+1)*n_samples evaluations)
  - `:use_cache` - Whether to check/store cache (default: true)
  - `:similarity_threshold` - Cache hit threshold (default: 0.95)
  - `:fingerprint` - Pre-computed fingerprint (optional)
  - `:repo` - Ecto repo for cache storage (default: PgGaConf.Repo)
  - `:restart_fn` - Function to call when restart-required params change (optional)
                    Called with config map containing only restart-required params.
                    If provided, enables batched evaluation to minimize restarts.
  - `:on_batch_start` - Optional callback when a new batch starts (for progress reporting)
                        Called with (batch_index, total_batches, restart_param_values)

  ## Benchmark Function

  The benchmark_fn receives a config map and returns {:ok, score} or {:error, reason}.
  Lower scores are better.
  """
  @spec analyze(map(), (map() -> {:ok, float()} | {:error, term()}), keyword()) ::
          {:ok, sensitivity_indices()} | {:error, term()}
  def analyze(knob_space, benchmark_fn, opts \\ []) do
    n_samples = Keyword.get(opts, :n_samples, @default_n_samples)
    use_cache = Keyword.get(opts, :use_cache, true)
    similarity_threshold = Keyword.get(opts, :similarity_threshold, @similarity_threshold)
    repo = Keyword.get(opts, :repo, PgGaConf.Repo)
    restart_fn = Keyword.get(opts, :restart_fn)
    on_batch_start = Keyword.get(opts, :on_batch_start)

    with {:ok, fingerprint} <- get_fingerprint(opts),
         {:ok, indices} <-
           maybe_cached_analysis(
             knob_space,
             benchmark_fn,
             fingerprint,
             n_samples,
             use_cache,
             similarity_threshold,
             repo,
             restart_fn,
             on_batch_start
           ) do
      {:ok, indices}
    end
  end

  @doc """
  Filter knobs by importance based on total-order index (STi).

  ## Options

  - `:threshold` - Minimum STi to be considered important (default: 0.05)
  - `:top_k` - Return only top K most important knobs (optional)
  """
  @spec filter_important(sensitivity_indices(), keyword()) :: [atom()]
  def filter_important(indices, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @importance_threshold)
    top_k = Keyword.get(opts, :top_k)

    important =
      indices
      |> Enum.filter(fn {_name, %{st: st}} -> st >= threshold end)
      |> Enum.sort_by(fn {_name, %{st: st}} -> st end, :desc)
      |> Enum.map(fn {name, _} -> name end)

    if top_k do
      Enum.take(important, top_k)
    else
      important
    end
  end

  @doc """
  Get reduced knob space containing only important knobs.
  """
  @spec reduce_knob_space(map(), sensitivity_indices(), keyword()) :: map()
  def reduce_knob_space(knob_space, indices, opts \\ []) do
    important_knobs = filter_important(indices, opts)
    Map.take(knob_space, important_knobs)
  end

  @doc """
  Quick analysis using predefined knob sets based on workload type.

  Skips Sobol and uses domain knowledge about important knobs per workload type.
  Useful when Sobol analysis is too expensive.
  """
  @spec quick_reduce(workload_type :: Fingerprint.workload_type()) :: map()
  def quick_reduce(:oltp), do: KnobSpace.oltp_knobs()
  def quick_reduce(:olap), do: KnobSpace.olap_knobs()
  def quick_reduce(:mixed), do: KnobSpace.mixed_knobs()

  # Private functions

  defp get_fingerprint(opts) do
    case Keyword.get(opts, :fingerprint) do
      nil -> Fingerprint.extract(Keyword.get(opts, :repo))
      fp -> {:ok, fp}
    end
  end

  defp maybe_cached_analysis(
         knob_space,
         benchmark_fn,
         fingerprint,
         n_samples,
         use_cache,
         similarity_threshold,
         repo,
         restart_fn,
         on_batch_start
       ) do
    knob_names = Map.keys(knob_space)

    if use_cache do
      case find_similar_cache(fingerprint, knob_names, similarity_threshold, repo) do
        {:ok, cached_indices} ->
          Logger.info("Sobol cache hit - reusing cached sensitivity indices")
          {:ok, cached_indices}

        :not_found ->
          Logger.info("Sobol cache miss - running full analysis")

          with {:ok, indices} <- run_sobol_analysis(knob_space, benchmark_fn, n_samples, restart_fn, on_batch_start) do
            save_to_cache(fingerprint, knob_names, indices, repo)
            {:ok, indices}
          end
      end
    else
      run_sobol_analysis(knob_space, benchmark_fn, n_samples, restart_fn, on_batch_start)
    end
  end

  defp find_similar_cache(fingerprint, knob_names, threshold, repo) do
    # Get all cache entries with matching knob set
    knob_set = Enum.sort(knob_names) |> Enum.map(&Atom.to_string/1)

    import Ecto.Query

    query =
      from(s in SobolCache,
        where: s.knob_names == ^knob_set
      )

    case repo.all(query) do
      [] ->
        :not_found

      entries ->
        # Find entry with highest similarity above threshold
        entries
        |> Enum.map(fn entry ->
          case Fingerprint.deserialize(entry.fingerprint) do
            {:ok, cached_fp} ->
              similarity = Fingerprint.similarity(fingerprint, cached_fp)
              {similarity, entry}

            _ ->
              {0.0, entry}
          end
        end)
        |> Enum.filter(fn {sim, _} -> sim >= threshold end)
        |> Enum.max_by(fn {sim, _} -> sim end, fn -> nil end)
        |> case do
          nil -> :not_found
          {_sim, entry} -> deserialize_indices(entry.sensitivity_indices)
        end
    end
  rescue
    # Handle case where table doesn't exist yet
    _ -> :not_found
  end

  defp save_to_cache(fingerprint, knob_names, indices, repo) do
    knob_set = Enum.sort(knob_names) |> Enum.map(&Atom.to_string/1)

    attrs = %{
      fingerprint: Fingerprint.serialize(fingerprint),
      knob_names: knob_set,
      sensitivity_indices: serialize_indices(indices),
      workload_type: Atom.to_string(Fingerprint.classify(fingerprint))
    }

    %SobolCache{}
    |> SobolCache.changeset(attrs)
    |> repo.insert()
  rescue
    e ->
      Logger.warning("Failed to save Sobol cache: #{inspect(e)}")
      :ok
  end

  defp run_sobol_analysis(knob_space, benchmark_fn, n_samples, restart_fn, on_batch_start) do
    # Convert knob space to Julia format
    julia_knobs = encode_knob_space_for_julia(knob_space)

    # Generate Sobol samples via Julia
    with {:ok, %{"samples" => samples, "matrices" => matrices}} <-
           Julia.generate_sobol_samples(julia_knobs, n_samples) do
      # Run benchmarks for all samples
      # Use batched evaluation if restart_fn is provided and we have restart-required params
      results =
        if restart_fn do
          evaluate_samples_batched(samples, knob_space, benchmark_fn, restart_fn, on_batch_start)
        else
          evaluate_samples(samples, knob_space, benchmark_fn)
        end

      # Compute sensitivity indices via Julia
      with {:ok, indices} <- Julia.compute_sensitivity(results, matrices, julia_knobs) do
        # Convert back to Elixir format
        {:ok, decode_indices(indices, knob_space)}
      end
    end
  end

  defp encode_knob_space_for_julia(knob_space) do
    Map.new(knob_space, fn {name, def} ->
      julia_def =
        case def do
          {:continuous, min, max} ->
            %{"type" => "continuous", "min" => min, "max" => max}

          {:integer, min, max} ->
            %{"type" => "integer", "min" => min, "max" => max}

          {:categorical, choices} ->
            # Encode as integer range for Sobol
            %{"type" => "integer", "min" => 0, "max" => length(choices) - 1}
        end

      {Atom.to_string(name), julia_def}
    end)
  end

  defp evaluate_samples(samples, knob_space, benchmark_fn) do
    Enum.map(samples, fn sample ->
      config = decode_sample_to_config(sample, knob_space)

      # Run benchmark
      case benchmark_fn.(config) do
        {:ok, score} -> score
        {:error, _} -> 1.0e10
      end
    end)
  end

  @doc false
  # Batched evaluation for Sobol samples
  # Groups samples by restart-required param values to minimize PostgreSQL restarts
  defp evaluate_samples_batched(samples, knob_space, benchmark_fn, restart_fn, on_batch_start) do
    restart_params = Pgbench.restart_required_params_atoms()
    knob_names = Map.keys(knob_space)

    # Find which restart-required params are in our knob space
    restart_params_in_space = Enum.filter(restart_params, &(&1 in knob_names))

    if Enum.empty?(restart_params_in_space) do
      # No restart-required params, use normal evaluation
      Logger.info("No restart-required params in knob space, using sequential evaluation")
      evaluate_samples(samples, knob_space, benchmark_fn)
    else
      Logger.info("Batching samples by restart-required params: #{inspect(restart_params_in_space)}")

      # Decode all samples first
      decoded_samples =
        samples
        |> Enum.with_index()
        |> Enum.map(fn {sample, idx} ->
          config = decode_sample_to_config(sample, knob_space)
          {idx, config}
        end)

      # Group by restart-required param values
      # Create a key from the restart-required param values for each sample
      grouped =
        decoded_samples
        |> Enum.group_by(fn {_idx, config} ->
          # Build a tuple of restart-required param values as the group key
          restart_params_in_space
          |> Enum.map(fn param ->
            value = Map.get(config, param)
            # Round to reduce unique values (discretize continuous params)
            if is_float(value), do: round(value), else: value
          end)
          |> List.to_tuple()
        end)

      total_batches = map_size(grouped)
      Logger.info("Created #{total_batches} batches from #{length(samples)} samples")

      # Sort batches by their key for deterministic ordering
      sorted_batches = Enum.sort_by(grouped, fn {key, _} -> key end)

      # Process batches, restarting only between batches
      {results_map, _} =
        sorted_batches
        |> Enum.with_index(1)
        |> Enum.reduce({%{}, nil}, fn {{_batch_key, batch_samples}, batch_idx}, {results, last_restart_values} ->
          # Extract restart-required param values for this batch
          {_idx, first_config} = hd(batch_samples)
          restart_values = Map.take(first_config, restart_params_in_space)

          # Check if we need to restart (values changed from last batch)
          needs_restart = last_restart_values != restart_values

          if needs_restart do
            Logger.info("Batch #{batch_idx}/#{total_batches}: Restarting PostgreSQL for #{inspect(restart_values)}")

            # Call the on_batch_start callback if provided
            if on_batch_start do
              on_batch_start.(batch_idx, total_batches, restart_values)
            end

            # Apply restart-required params and restart PostgreSQL
            restart_fn.(restart_values)

            # Give PostgreSQL time to stabilize after restart
            Process.sleep(2_000)
          else
            Logger.debug("Batch #{batch_idx}/#{total_batches}: Same restart params, no restart needed")
          end

          # Run all samples in this batch
          batch_results =
            batch_samples
            |> Enum.map(fn {idx, config} ->
              # The benchmark_fn handles applying all config (including non-restart params)
              result =
                case benchmark_fn.(config) do
                  {:ok, score} -> score
                  {:error, _} -> 1.0e10
                end

              {idx, result}
            end)

          # Merge batch results into accumulator
          new_results = Enum.into(batch_results, results)

          {new_results, restart_values}
        end)

      # Convert results map back to ordered list matching original sample order
      0..(length(samples) - 1)
      |> Enum.map(&Map.fetch!(results_map, &1))
    end
  end

  # Helper to decode a sample to a config map
  defp decode_sample_to_config(sample, knob_space) do
    sample
    |> Enum.map(fn {name_str, value} ->
      name_atom =
        if is_atom(name_str), do: name_str, else: String.to_existing_atom(name_str)

      decoded_value =
        case Map.get(knob_space, name_atom) do
          {:categorical, choices} ->
            Enum.at(choices, round(value))

          {:integer, _, _} ->
            round(value)

          {:continuous, _, _} ->
            value

          # Handle map format from Sobol.encode_knob_space_for_julia
          %{"type" => "integer"} ->
            round(value)

          %{"type" => "continuous"} ->
            value

          _ ->
            value
        end

      {name_atom, decoded_value}
    end)
    |> Map.new()
  end

  defp decode_indices(julia_indices, knob_space) do
    knob_names = Map.keys(knob_space)

    Map.new(julia_indices, fn {name_str, values} ->
      name_atom =
        if is_binary(name_str) do
          # Try to convert to existing atom, fall back to finding in knob_names
          Enum.find(knob_names, fn k -> Atom.to_string(k) == name_str end) ||
            String.to_atom(name_str)
        else
          name_str
        end

      {name_atom, %{s1: values["S1"] || values[:s1], st: values["ST"] || values[:st]}}
    end)
  end

  defp serialize_indices(indices) do
    indices
    |> Enum.map(fn {name, %{s1: s1, st: st}} ->
      {Atom.to_string(name), %{"s1" => s1, "st" => st}}
    end)
    |> Map.new()
    |> Jason.encode!()
  end

  defp deserialize_indices(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        indices =
          Map.new(map, fn {name, %{"s1" => s1, "st" => st}} ->
            {String.to_atom(name), %{s1: s1, st: st}}
          end)

        {:ok, indices}

      error ->
        error
    end
  end
end
