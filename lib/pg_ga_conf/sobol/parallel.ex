defmodule PgGaConf.Sobol.Parallel do
  @moduledoc """
  Coordinates parallel Sobol sensitivity evaluation across multiple PostgreSQL instances.

  Architecture:
  1. Generate all Sobol samples
  2. Group into batches by shared_buffers value (minimizes restarts)
  3. Assign batches to workers (static round-robin)
  4. Start workers, run evaluations in parallel
  5. Collect results, maintain original ordering
  """

  require Logger

  alias PgGaConf.Sobol.Worker

  @default_workers 4
  @worker_startup_timeout 120_000

  @doc """
  Run parallel Sobol evaluation.

  ## Options

    * `:parallel_workers` - Number of parallel PostgreSQL instances (default: 4)
    * `:source_db` - Source database name to clone
    * `:source_config` - Source database connection config
    * `:benchmark_spec` - Benchmark specification (duration, clients, workload_file)
    * `:base_dir` - Base directory for worker PGDATA (default: cwd)

  ## Returns

  `{:ok, results}` where results is a list of {index, score} tuples in original order.
  """
  def evaluate(samples, knob_space, opts \\ []) do
    num_workers = Keyword.get(opts, :parallel_workers, @default_workers)
    source_db = Keyword.get(opts, :source_db, "pgga_target")
    source_config = Keyword.get(opts, :source_config, default_source_config())
    benchmark_spec = Keyword.get(opts, :benchmark_spec, %{})
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    Logger.info("Starting parallel Sobol evaluation with #{num_workers} workers")
    Logger.info("Total samples: #{length(samples)}")

    # Index samples for result ordering
    indexed_samples = Enum.with_index(samples)

    # Group samples into batches by shared_buffers
    batches = group_into_batches(indexed_samples, knob_space)
    Logger.info("Grouped into #{length(batches)} batches by shared_buffers")

    # Assign batches to workers (round-robin)
    worker_assignments = assign_batches_to_workers(batches, num_workers)

    # Start workers and run evaluations
    results = run_with_workers(worker_assignments, source_db, source_config, benchmark_spec, knob_space, base_dir)

    # Sort results back to original order
    sorted_results =
      results
      |> List.flatten()
      |> Enum.sort_by(fn {idx, _score} -> idx end)

    {:ok, sorted_results}
  end

  @doc """
  Group samples into batches by shared_buffers value.

  All samples with the same shared_buffers are in the same batch,
  minimizing PostgreSQL restarts.
  """
  def group_into_batches(indexed_samples, knob_space) do
    # Find which parameter requires restart (typically shared_buffers)
    restart_param = find_restart_param(knob_space)

    indexed_samples
    |> Enum.group_by(fn {config, _idx} ->
      Map.get(config, restart_param)
    end)
    |> Enum.map(fn {shared_buffers_value, samples} ->
      %{
        shared_buffers: shared_buffers_value,
        samples: samples
      }
    end)
    |> Enum.sort_by(& &1.shared_buffers)
  end

  defp find_restart_param(knob_space) do
    # Known restart-required params - check if any are in our knob space
    restart_params = [:shared_buffers, :max_connections, :wal_buffers, :huge_pages]

    restart_params
    |> Enum.find(fn param -> Map.has_key?(knob_space, param) end)
    |> case do
      nil ->
        # Fall back to checking for map format with :requires_restart
        knob_space
        |> Enum.find(fn {_name, spec} -> is_map(spec) && Map.get(spec, :requires_restart) end)
        |> case do
          {name, _spec} -> name
          nil -> :shared_buffers
        end
      param ->
        param
    end
  end

  @doc """
  Assign batches to workers using round-robin.
  """
  def assign_batches_to_workers(batches, num_workers) do
    batches
    |> Enum.with_index()
    |> Enum.group_by(fn {_batch, idx} -> rem(idx, num_workers) end)
    |> Enum.map(fn {worker_id, batch_list} ->
      {worker_id, Enum.map(batch_list, fn {batch, _idx} -> batch end)}
    end)
    |> Enum.into(%{})
  end

  defp run_with_workers(worker_assignments, source_db, source_config, benchmark_spec, knob_space, base_dir) do
    # Create worker configs
    worker_ids = Map.keys(worker_assignments)

    Logger.info("Starting #{length(worker_ids)} worker PostgreSQL instances...")

    # Start all workers in parallel
    worker_tasks =
      worker_ids
      |> Enum.map(fn worker_id ->
        Task.async(fn ->
          run_worker(
            worker_id,
            Map.get(worker_assignments, worker_id, []),
            source_db,
            source_config,
            benchmark_spec,
            knob_space,
            base_dir
          )
        end)
      end)

    # Wait for all workers to complete (with generous timeout)
    total_samples = worker_assignments |> Map.values() |> List.flatten() |> Enum.map(& &1.samples) |> List.flatten() |> length()
    # ~20 seconds per sample + startup/clone overhead
    timeout = total_samples * 30_000 + length(worker_ids) * @worker_startup_timeout

    results =
      worker_tasks
      |> Task.await_many(timeout)
      |> Enum.map(fn
        {:ok, results} -> results
        {:error, reason} ->
          Logger.error("Worker failed: #{inspect(reason)}")
          []
      end)

    results
  end

  defp run_worker(worker_id, batches, source_db, source_config, benchmark_spec, knob_space, base_dir) do
    worker = Worker.new(worker_id, base_dir: base_dir)

    try do
      case Worker.start(worker) do
        {:ok, started_worker} ->
          results = run_batches(started_worker, batches, source_db, source_config, benchmark_spec, knob_space)
          Worker.stop(started_worker)
          {:ok, results}

        {:error, reason} ->
          Logger.error("Worker #{worker_id} failed to start: #{inspect(reason)}")
          # Return penalty scores for all samples
          penalty_results =
            batches
            |> Enum.flat_map(& &1.samples)
            |> Enum.map(fn {_config, idx} -> {idx, 1.0e10} end)

          {:ok, penalty_results}
      end
    rescue
      e ->
        Logger.error("Worker #{worker_id} crashed: #{Exception.message(e)}")
        Worker.stop(worker)
        {:error, {:worker_crash, e}}
    end
  end

  defp run_batches(worker, batches, source_db, source_config, benchmark_spec, knob_space) do
    batches
    |> Enum.with_index()
    |> Enum.flat_map(fn {batch, batch_idx} ->
      Logger.info("Worker #{worker.id}: Starting batch #{batch_idx + 1}/#{length(batches)} (shared_buffers=#{batch.shared_buffers})")

      # Clone database for this batch
      case Worker.clone_database(worker, source_config, source_db) do
        :ok ->
          # Apply shared_buffers config and restart
          shared_buffers_config = %{shared_buffers: batch.shared_buffers}
          Worker.apply_config(worker, shared_buffers_config, source_db, true)

          # Run each sample in the batch
          run_batch_samples(worker, batch.samples, source_db, benchmark_spec, knob_space)

        {:error, reason} ->
          Logger.error("Worker #{worker.id}: Clone failed for batch #{batch_idx + 1}: #{inspect(reason)}")
          # Return penalty scores for all samples in batch
          Enum.map(batch.samples, fn {_config, idx} -> {idx, 1.0e10} end)
      end
    end)
  end

  # Known restart-required params
  @restart_params [:shared_buffers, :max_connections, :wal_buffers, :huge_pages]

  defp run_batch_samples(worker, samples, source_db, benchmark_spec, _knob_space) do
    samples
    |> Enum.with_index()
    |> Enum.map(fn {{config, idx}, sample_idx} ->
      Logger.debug("Worker #{worker.id}: Sample #{sample_idx + 1}/#{length(samples)}")

      # Apply non-restart config (work_mem, etc.) - exclude known restart params
      non_restart_config =
        config
        |> Enum.reject(fn {param, _value} -> param in @restart_params end)
        |> Enum.into(%{})

      Worker.apply_config(worker, non_restart_config, source_db, false)

      # Run benchmark
      case Worker.run_benchmark(worker, source_db, benchmark_spec) do
        {:ok, score} ->
          Logger.debug("Worker #{worker.id}: Sample #{sample_idx + 1} score=#{Float.round(score, 6)}")
          {idx, score}

        {:error, _reason} ->
          Logger.warning("Worker #{worker.id}: Sample #{sample_idx + 1} benchmark failed")
          {idx, 1.0e10}
      end
    end)
  end

  defp default_source_config do
    %{
      host: Application.get_env(:pg_ga_conf, :target_db_host, "localhost"),
      port: Application.get_env(:pg_ga_conf, :target_db_port, 5433),
      user: Application.get_env(:pg_ga_conf, :target_db_user, "postgres"),
      password: Application.get_env(:pg_ga_conf, :target_db_password, "")
    }
  end
end
