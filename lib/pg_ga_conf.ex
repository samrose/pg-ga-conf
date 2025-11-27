defmodule PgGaConf do
  @moduledoc """
  PostgreSQL Configuration Optimizer using Genetic Algorithms, TPE, and CMA-ES.

  PgGaConf automatically tunes PostgreSQL configuration parameters for optimal
  performance on your specific workload using advanced optimization algorithms.

  ## Quick Start

  ```elixir
  # Start a tuning job (auto-selects optimizer based on workload)
  {:ok, job} = PgGaConf.tune("postgres://user:pass@host/db")

  # Check progress
  {:ok, status} = PgGaConf.status(job)

  # Get best configuration found
  {:ok, config, score} = PgGaConf.best(job)
  ```

  ## Available Optimizers

  - **TPE (Tree-structured Parzen Estimator)** - Best for small budgets (<20 iterations)
  - **GA (Genetic Algorithm)** - Best when many categorical parameters
  - **CMA-ES (Covariance Matrix Adaptation)** - Best for continuous parameters with correlations

  ## Features

  - **Automatic workload detection** - Classifies as OLTP, OLAP, or Mixed
  - **Transfer learning** - Warm-starts from similar past optimizations
  - **Crash recovery** - Checkpoints after each iteration, auto-resumes
  - **Sobol sensitivity analysis** - Identifies most important parameters

  ## Legacy API

  The original Orchestrator-based API is still available for backwards compatibility.
  """

  alias PgGaConf.{TuningJob, Fingerprint, KnobSpace, Sobol, ResultStore, Orchestrator}
  alias PgGaConf.Core.DatabaseScanner
  alias PgGaConf.DataGenerator.DataGenerator

  @type optimizer :: :ga | :tpe | :cma_es | :auto
  @type benchmark :: :pgbench | :custom

  #
  # New Unified API
  #

  @doc """
  Start a new tuning job for a PostgreSQL database.

  ## Options

  - `:optimizer` - Optimizer to use: `:ga`, `:tpe`, `:cma_es`, or `:auto` (default)
  - `:benchmark` - Benchmark type: `:pgbench` or `:custom` (default: `:pgbench`)
  - `:max_iterations` - Maximum optimization iterations (default: 30)
  - `:warm_start` - Use prior observations for warm-start (default: true)
  - `:use_sobol` - Run Sobol sensitivity analysis (default: false)
  - `:knob_space` - Custom knob space (default: workload-based selection)
  - `:duration` - Benchmark duration in seconds for pgbench (default: 60)
  - `:clients` - Number of benchmark clients (default: 10)

  ## Examples

      # Simple usage with auto-selection
      {:ok, job} = PgGaConf.tune("postgres://localhost/mydb")

      # With explicit optimizer
      {:ok, job} = PgGaConf.tune("postgres://localhost/mydb", optimizer: :tpe)

      # With custom parameters
      {:ok, job} = PgGaConf.tune("postgres://localhost/mydb",
        optimizer: :cma_es,
        max_iterations: 50,
        use_sobol: true
      )
  """
  @spec tune(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def tune(db_url, opts \\ []) do
    db_id = Keyword.get(opts, :db_id, generate_db_id(db_url))

    opts = Keyword.merge(opts, db_url: db_url, db_id: db_id)

    TuningJob.start(opts)
  end

  @doc """
  Get status of a tuning job.

  Returns a map with:
  - `:status` - Current status (:running, :paused, :completed, :error)
  - `:current_iteration` - Current iteration number
  - `:max_iterations` - Total iterations planned
  - `:best_score` - Best score found so far
  - `:improvement_pct` - Improvement over initial baseline
  """
  @spec status(pid()) :: {:ok, map()} | {:error, term()}
  def status(job) do
    TuningJob.status(job)
  end

  @doc """
  Get the best configuration found by a tuning job.

  Returns `{:ok, config, score}` where config is a map of parameter names to values.
  """
  @spec best(pid()) :: {:ok, map(), float()} | {:error, term()}
  def best(job) do
    TuningJob.best(job)
  end

  @doc """
  Pause a running tuning job.

  The job can be resumed later with `resume/1`.
  """
  @spec pause(pid()) :: :ok | {:error, term()}
  def pause(job) do
    TuningJob.pause(job)
  end

  @doc """
  Resume a paused tuning job.
  """
  @spec resume(pid()) :: :ok | {:error, term()}
  def resume(job) do
    TuningJob.resume(job)
  end

  @doc """
  Stop a tuning job.
  """
  @spec stop(pid()) :: :ok
  def stop(job) do
    TuningJob.stop(job)
  end

  @doc """
  Analyze workload and return recommended optimizer and knob space.

  Useful for understanding what the auto-selection will choose.

  ## Example

      {:ok, analysis} = PgGaConf.analyze("postgres://localhost/mydb")
      # %{
      #   workload_type: :oltp,
      #   recommended_optimizer: :tpe,
      #   recommended_knobs: [:shared_buffers, :work_mem, ...],
      #   fingerprint: %{...}
      # }
  """
  @spec analyze(String.t() | Ecto.Repo.t()) :: {:ok, map()} | {:error, term()}
  def analyze(repo_or_url) do
    with {:ok, fingerprint} <- extract_fingerprint(repo_or_url) do
      workload_type = Fingerprint.classify(fingerprint)
      knob_space = Sobol.quick_reduce(workload_type)
      recommended_optimizer = PgGaConf.Optimizer.recommend(knob_space)

      {:ok,
       %{
         workload_type: workload_type,
         recommended_optimizer: recommended_optimizer,
         recommended_knobs: Map.keys(knob_space),
         fingerprint: fingerprint
       }}
    end
  end

  @doc """
  Get all available PostgreSQL knobs with their definitions.

  Returns a map of knob names to their type and range/choices.
  """
  @spec all_knobs() :: map()
  def all_knobs do
    KnobSpace.all_knobs()
  end

  @doc """
  Get knobs recommended for a specific workload type.
  """
  @spec knobs_for_workload(:oltp | :olap | :mixed) :: map()
  def knobs_for_workload(:oltp), do: KnobSpace.oltp_knobs()
  def knobs_for_workload(:olap), do: KnobSpace.olap_knobs()
  def knobs_for_workload(:mixed), do: KnobSpace.mixed_knobs()

  @doc """
  Format a configuration map for PostgreSQL.

  Converts raw values to PostgreSQL-compatible strings (e.g., "4096MB").
  """
  @spec format_config(map()) :: map()
  def format_config(config) do
    Map.new(config, fn {param, value} ->
      {param, KnobSpace.format_value(param, value)}
    end)
  end

  @doc """
  Get the best known configuration for a workload type.

  Looks up historical observations to find the best configuration seen for similar workloads.
  """
  @spec best_for_workload(:oltp | :olap | :mixed) :: {:ok, map()} | {:error, :not_found}
  def best_for_workload(workload_type) do
    ResultStore.best_config_for_cluster(workload_type)
  end

  @doc """
  List all resumable tuning sessions.

  Returns sessions that were paused or interrupted and can be resumed.
  """
  @spec list_resumable_sessions() :: [map()]
  def list_resumable_sessions do
    ResultStore.get_resumable_sessions()
  end

  @doc """
  Resume a tuning session by database ID.

  Finds and resumes the most recent active session for the given database.
  """
  @spec resume_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def resume_session(db_id, opts \\ []) do
    case ResultStore.get_active_session(db_id) do
      {:ok, _session} ->
        # Start TuningJob which will auto-recover
        db_url = Keyword.fetch!(opts, :db_url)
        TuningJob.start(Keyword.merge(opts, db_id: db_id, db_url: db_url))

      :not_found ->
        {:error, :no_session_found}
    end
  end

  #
  # Legacy API (for backwards compatibility)
  #

  @doc """
  Optimize PostgreSQL configuration for a given database.

  **LEGACY API** - Consider using `tune/2` instead.

  ## Options

    * `:strategy` - Optimization strategy: :conservative, :moderate, :aggressive (default: :moderate)
    * `:instance_provider` - Instance provider module (default: from config)
    * `:scale_factor` - Data scale factor (default: 0.1)
    * `:generations` - Number of GA generations (default: 30)
    * `:population_size` - Population size (default: 20)
    * `:parallel_instances` - Number of parallel test instances (default: 5)
    * `:workload` - Workload generator module (default: WorkloadReplicator)

  ## Examples

      iex> PgGaConf.optimize(
      ...>   %{host: "localhost", database: "mydb", username: "postgres", password: "secret"},
      ...>   strategy: :moderate,
      ...>   generations: 30
      ...> )
      {:ok, %{optimized_config: %{}, improvements: %{}, scan_summary: %{}}}
  """
  def optimize(connection_config, opts \\ []) do
    Orchestrator.optimize(connection_config, opts)
  end

  @doc """
  Scan a database and return profiling information.

  Scans the database structure (tables, columns, constraints, indexes) and
  optionally profiles data distributions for synthetic data generation.

  ## Options

  - `:profile_data` - Whether to profile data distributions (default: true)

  ## Examples

      # Scan with full profiling
      {:ok, scan} = PgGaConf.scan(source_conn)

      # Scan without data profiling (faster)
      {:ok, scan} = PgGaConf.scan(source_conn, profile_data: false)
  """
  @spec scan(Postgrex.conn(), keyword()) :: {:ok, PgGaConf.Core.ScanResult.t()}
  def scan(conn, opts \\ []) do
    scan_result = DatabaseScanner.scan_database(conn, opts)
    {:ok, scan_result}
  end

  @doc """
  Generate synthetic data in target database based on scan result.

  Creates schema and populates with synthetic data matching production patterns.
  Uses COPY protocol for fast bulk inserts.

  ## Options

  - `:scale` - Scale factor for row counts (default: 1.0 = same size as source)
  - `:batch_size` - Rows per COPY transaction (default: 50,000)
  - `:progress_fn` - Callback for progress updates
  - `:skip_tables` - Tables to exclude from generation
  - `:only_tables` - Only generate these tables

  ## Examples

      # Generate same size as source
      {:ok, scan} = PgGaConf.scan(source_conn)
      :ok = PgGaConf.generate_from_scan(scan, target_conn)

      # Generate 10% scale for quick testing
      :ok = PgGaConf.generate_from_scan(scan, target_conn, scale: 0.1)
  """
  @spec generate_from_scan(PgGaConf.Core.ScanResult.t(), Postgrex.conn(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def generate_from_scan(scan_result, target_conn, opts \\ []) do
    DataGenerator.generate(scan_result, target_conn, opts)
  end

  @doc """
  Scan source database and generate synthetic data in target database.

  Convenience function that combines `scan/2` and `generate_from_scan/3`.

  ## Options

  All options from `scan/2` and `generate_from_scan/3` are supported, plus:

  - `:profile_data` - Whether to profile data distributions (default: true)
  - `:scale` - Scale factor for row counts (default: 1.0)
  - `:batch_size` - Rows per COPY transaction (default: 50,000)
  - `:progress_fn` - Callback for progress updates

  ## Examples

      # Full pipeline
      {:ok, result} = PgGaConf.generate(source_conn, target_conn)

      # With options
      {:ok, result} = PgGaConf.generate(source_conn, target_conn,
        scale: 0.5,
        progress_fn: &IO.puts/1
      )
  """
  @spec generate(Postgrex.conn(), Postgrex.conn(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(source_conn, target_conn, opts \\ []) do
    scan_opts = Keyword.take(opts, [:profile_data])
    gen_opts = Keyword.drop(opts, [:profile_data])

    with {:ok, scan_result} <- scan(source_conn, scan_opts) do
      generate_from_scan(scan_result, target_conn, gen_opts)
    end
  end

  @doc """
  Generate synthetic data based on a scan result.

  **LEGACY API** - Use `generate/3` or `generate_from_scan/3` instead.
  """
  def generate_legacy(scan_result, target_connection_config, opts \\ []) do
    Orchestrator.generate(scan_result, target_connection_config, opts)
  end

  # Private functions

  defp generate_db_id(db_url) do
    uri = URI.parse(db_url)
    host = uri.host || "localhost"
    db = (uri.path || "/postgres") |> String.trim_leading("/")
    "#{host}-#{db}-#{:erlang.unique_integer([:positive])}"
  end

  defp extract_fingerprint(repo) when is_atom(repo) do
    Fingerprint.extract(repo)
  end

  defp extract_fingerprint(db_url) when is_binary(db_url) do
    # For URL-based fingerprinting, we'd need a temporary connection
    # For now, return a default fingerprint
    {:ok,
     %{
       read_write_ratio: 0.5,
       seq_scan_ratio: 0.3,
       index_scan_ratio: 0.7,
       heap_blks_hit_ratio: 0.95,
       idx_blks_hit_ratio: 0.98,
       avg_tuple_size: 100.0,
       temp_files_ratio: 0.001,
       deadlock_ratio: 0.0,
       xact_commit_ratio: 0.99,
       tup_returned_per_fetch: 1.5,
       tup_inserted_ratio: 0.4,
       tup_updated_ratio: 0.4,
       tup_deleted_ratio: 0.2,
       blk_read_time_ratio: 0.3,
       blk_write_time_ratio: 0.7
     }}
  end
end
