defmodule PgGaConf.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Don't start children during unit tests
    if Application.get_env(:pg_ga_conf, :start_app, true) == false do
      opts = [strategy: :one_for_one, name: PgGaConf.Supervisor]
      Supervisor.start_link([], opts)
    else
      # Ensure database exists before starting Repo
      ensure_database_exists()

      children = [
        # Ecto Repo for persistence
        PgGaConf.Repo,

        # Task supervisor for parallel operations
        {Task.Supervisor, name: PgGaConf.TaskSupervisor},

        # Registry for tuning jobs
        {Registry, keys: :unique, name: PgGaConf.JobRegistry},

        # Dynamic supervisor for tuning jobs (legacy GA)
        {DynamicSupervisor, name: PgGaConf.TuningSupervisor, strategy: :one_for_one},

        # Dynamic supervisor for new tuning jobs (unified optimizer)
        {DynamicSupervisor, name: PgGaConf.TuningJobSupervisor, strategy: :one_for_one},

        # ETS table for fitness caching (GA)
        {PgGaConf.FitnessCache, []},

        # Job storage for web API (legacy)
        {PgGaConf.JobStorage, []},

        # Julia client (started conditionally based on config)
        julia_child_spec(),

        # Session recovery (auto-resume paused sessions)
        PgGaConf.SessionRecovery
      ]
      |> Enum.reject(&is_nil/1)

      opts = [strategy: :one_for_one, name: PgGaConf.Supervisor]
      result = Supervisor.start_link(children, opts)

      # Run migrations after Repo is started
      run_migrations()

      result
    end
  end

  defp run_migrations do
    # Only run migrations if auto_migrate is enabled (default: true)
    if Application.get_env(:pg_ga_conf, :auto_migrate, true) do
      Logger.debug("Running auto-migrations for PgGaConf...")

      # Create tables using raw SQL (idempotent - uses IF NOT EXISTS)
      create_tables_sql()
      |> Enum.each(fn sql ->
        Ecto.Adapters.SQL.query!(PgGaConf.Repo, sql)
      end)

      Logger.debug("Auto-migrations complete")
    end
  rescue
    e ->
      Logger.warning("Auto-migration failed: #{Exception.message(e)}")
  end

  defp create_tables_sql do
    [
      # Observations table for transfer learning
      """
      CREATE TABLE IF NOT EXISTS pg_ga_conf_observations (
        id BIGSERIAL PRIMARY KEY,
        db_id VARCHAR(255) NOT NULL,
        config JSONB NOT NULL,
        score DOUBLE PRECISION NOT NULL,
        metrics JSONB,
        workload_cluster VARCHAR(255) NOT NULL,
        fingerprint_vector DOUBLE PRECISION[],
        inserted_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW()
      )
      """,
      "CREATE INDEX IF NOT EXISTS pg_ga_conf_observations_workload_cluster_index ON pg_ga_conf_observations (workload_cluster)",
      "CREATE INDEX IF NOT EXISTS pg_ga_conf_observations_db_id_index ON pg_ga_conf_observations (db_id)",

      # Sessions table for tuning state and history
      """
      CREATE TABLE IF NOT EXISTS pg_ga_conf_sessions (
        id BIGSERIAL PRIMARY KEY,
        db_id VARCHAR(255) NOT NULL,
        optimizer VARCHAR(255) NOT NULL,
        status VARCHAR(255) DEFAULT 'initializing',
        optimizer_state BYTEA,
        current_iteration INTEGER DEFAULT 0,
        max_iterations INTEGER,
        knobs_used VARCHAR(255)[],
        best_config JSONB,
        best_score DOUBLE PRECISION,
        initial_score DOUBLE PRECISION,
        improvement_pct DOUBLE PRECISION,
        history JSONB[],
        last_error TEXT,
        error_count INTEGER DEFAULT 0,
        consecutive_errors INTEGER DEFAULT 0,
        workload_cluster VARCHAR(255),
        fingerprint_vector DOUBLE PRECISION[],
        inserted_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW()
      )
      """,
      "CREATE INDEX IF NOT EXISTS pg_ga_conf_sessions_db_id_index ON pg_ga_conf_sessions (db_id)",
      "CREATE INDEX IF NOT EXISTS pg_ga_conf_sessions_status_index ON pg_ga_conf_sessions (status)",

      # Sobol cache table
      """
      CREATE TABLE IF NOT EXISTS pg_ga_conf_sobol_cache (
        id BIGSERIAL PRIMARY KEY,
        fingerprint BYTEA NOT NULL,
        workload_type VARCHAR(255),
        knob_names VARCHAR(255)[] NOT NULL,
        sensitivity_indices TEXT NOT NULL,
        samples_used INTEGER,
        analysis_duration_ms INTEGER,
        inserted_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW()
      )
      """,
      "CREATE INDEX IF NOT EXISTS pg_ga_conf_sobol_cache_workload_type_index ON pg_ga_conf_sobol_cache (workload_type)",
      "CREATE INDEX IF NOT EXISTS pg_ga_conf_sobol_cache_knob_names_index ON pg_ga_conf_sobol_cache (knob_names)"
    ]
  end

  defp julia_child_spec do
    mode = Application.get_env(:pg_ga_conf, :julia_mode, :auto)

    case mode do
      :mock -> nil
      _ -> {PgGaConf.Julia, []}
    end
  end

  defp ensure_database_exists do
    # Get repo config
    repo_config = Application.get_env(:pg_ga_conf, PgGaConf.Repo, [])
    database = Keyword.get(repo_config, :database, "pgga_dev")
    hostname = Keyword.get(repo_config, :hostname, "localhost")
    port = Keyword.get(repo_config, :port, 5432)
    username = Keyword.get(repo_config, :username, "postgres")
    password = Keyword.get(repo_config, :password, "")

    # Connect to 'postgres' database to create the target database
    {:ok, conn} =
      Postgrex.start_link(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: "postgres"
      )

    # Check if database exists
    result = Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [database])

    if result.num_rows == 0 do
      Logger.info("Creating database '#{database}'...")
      # CREATE DATABASE cannot run in a transaction
      Postgrex.query!(conn, "CREATE DATABASE #{database}", [])
      Logger.info("Database '#{database}' created successfully")
    end

    GenServer.stop(conn)
  rescue
    e ->
      Logger.warning("Could not ensure database exists: #{Exception.message(e)}")
  end
end
