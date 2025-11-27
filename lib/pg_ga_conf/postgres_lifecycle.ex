defmodule PgGaConf.PostgresLifecycle do
  @moduledoc """
  Manages the TARGET PostgreSQL database lifecycle for tuning.

  ## Two-Database Architecture

  This application uses two separate PostgreSQL instances:

  1. **App DB (port 5432)**: Stores tuning sessions, results, cache.
     NEVER restarted during tuning. Used by the Repo.

  2. **Target DB (port 5433)**: The database being tuned/benchmarked.
     May be restarted when testing restart-required params like shared_buffers.

  This module ONLY manages the Target DB. The App DB is left untouched,
  so the Repo connection pool remains stable during tuning operations.
  """

  require Logger

  @target_port 5433
  @postgres_ready_timeout_ms 30_000
  @postgres_ready_check_interval_ms 500

  @doc """
  Get the target database configuration from app config or environment.
  """
  def target_config do
    %{
      host: Application.get_env(:pg_ga_conf, :target_db_host, "localhost"),
      port: Application.get_env(:pg_ga_conf, :target_db_port, @target_port),
      user: Application.get_env(:pg_ga_conf, :target_db_user, "postgres"),
      password: Application.get_env(:pg_ga_conf, :target_db_password, ""),
      database: Application.get_env(:pg_ga_conf, :target_db_name, "pgga_target"),
      pgdata: Application.get_env(:pg_ga_conf, :target_pgdata) || System.get_env("PGDATA_TARGET")
    }
  end

  @doc """
  Build a connection URL for the target database.
  """
  def target_url(database \\ nil) do
    config = target_config()
    db = database || config.database
    "postgres://#{config.user}:#{config.password}@#{config.host}:#{config.port}/#{db}"
  end

  @doc """
  Restart the TARGET PostgreSQL database.

  This does NOT affect the App DB (port 5432) or the Repo connection pool.

  ## Options

    * `:config` - Map of config params to apply before restart
    * `:pgdata` - PostgreSQL data directory (defaults to PGDATA_TARGET env var)
    * `:timeout` - Max time to wait for PostgreSQL to be ready (default: 30s)

  ## Example

      PostgresLifecycle.restart_target(config: %{shared_buffers: 256})
  """
  @spec restart_target(keyword()) :: :ok | {:error, term()}
  def restart_target(opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    target = target_config()
    pgdata = Keyword.get(opts, :pgdata) || target.pgdata
    timeout = Keyword.get(opts, :timeout, @postgres_ready_timeout_ms)

    Logger.info("Restarting TARGET database (port #{target.port})...")

    with :ok <- apply_config_to_target(config, target),
         :ok <- do_restart_target(pgdata),
         :ok <- wait_for_target_ready(target, timeout) do
      Logger.info("TARGET database restarted successfully")
      :ok
    end
  end

  @doc """
  Check if the target database is ready.
  """
  @spec target_ready?() :: boolean()
  def target_ready? do
    target = target_config()
    case System.cmd("pg_isready", ["-h", target.host, "-p", to_string(target.port)],
           stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Wait for the target database to be ready.
  """
  @spec wait_for_target_ready(map(), non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_for_target_ready(target \\ target_config(), timeout \\ @postgres_ready_timeout_ms) do
    Logger.debug("Waiting for TARGET database (port #{target.port}) to be ready...")
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_target(target, deadline)
  end

  @doc """
  Start the target database if not running.
  """
  @spec ensure_target_running() :: :ok | {:error, term()}
  def ensure_target_running do
    if target_ready?() do
      Logger.debug("TARGET database already running")
      :ok
    else
      start_target()
    end
  end

  @doc """
  Start the target database.
  """
  @spec start_target(keyword()) :: :ok | {:error, term()}
  def start_target(opts \\ []) do
    target = target_config()
    pgdata = Keyword.get(opts, :pgdata) || target.pgdata

    if is_nil(pgdata) do
      Logger.error("PGDATA_TARGET not set, cannot start target database")
      {:error, :pgdata_not_set}
    else
      Logger.info("Starting TARGET database (port #{target.port})...")

      case System.cmd("pg_ctl", ["start", "-D", pgdata, "-l", "#{pgdata}/logfile"],
             stderr_to_stdout: true) do
        {_output, 0} ->
          wait_for_target_ready(target)

        {output, code} ->
          Logger.error("Failed to start TARGET database (code #{code}): #{output}")
          {:error, {:start_failed, code}}
      end
    end
  end

  @doc """
  Stop the target database.
  """
  @spec stop_target(keyword()) :: :ok | {:error, term()}
  def stop_target(opts \\ []) do
    target = target_config()
    pgdata = Keyword.get(opts, :pgdata) || target.pgdata

    if is_nil(pgdata) do
      Logger.error("PGDATA_TARGET not set, cannot stop target database")
      {:error, :pgdata_not_set}
    else
      Logger.info("Stopping TARGET database...")

      case System.cmd("pg_ctl", ["stop", "-D", pgdata, "-m", "fast", "-w", "-t", "10"],
             stderr_to_stdout: true) do
        {_, 0} ->
          Logger.debug("TARGET database stopped")
          :ok

        {output, code} ->
          Logger.warning("pg_ctl stop returned #{code}: #{output}")
          # Might already be stopped
          :ok
      end
    end
  end

  # Private functions

  defp do_wait_for_target(target, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      Logger.error("TARGET database did not become ready within timeout")
      {:error, :timeout}
    else
      case System.cmd("pg_isready", ["-h", target.host, "-p", to_string(target.port)],
             stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.debug("TARGET database is ready")
          :ok

        _ ->
          Process.sleep(@postgres_ready_check_interval_ms)
          do_wait_for_target(target, deadline)
      end
    end
  end

  defp apply_config_to_target(config, _target) when map_size(config) == 0, do: :ok

  defp apply_config_to_target(config, target) do
    Logger.debug("Applying config to TARGET database: #{inspect(config)}")

    Enum.each(config, fn {param, value} ->
      formatted = PgGaConf.KnobSpace.format_value(param, value)
      sql = "ALTER SYSTEM SET #{param} = '#{formatted}'"

      System.cmd("psql",
        ["-h", target.host, "-p", to_string(target.port), "-U", target.user, "-c", sql],
        env: [{"PGPASSWORD", target.password}],
        stderr_to_stdout: true
      )
    end)

    :ok
  end

  defp do_restart_target(nil) do
    Logger.error("PGDATA_TARGET not set, cannot restart target database")
    {:error, :pgdata_not_set}
  end

  defp do_restart_target(pgdata) do
    Logger.info("Restarting TARGET PostgreSQL (stop then start)...")

    # Stop
    stop_result = System.cmd("pg_ctl", ["stop", "-D", pgdata, "-m", "fast", "-w", "-t", "10"],
      stderr_to_stdout: true
    )

    case stop_result do
      {_, 0} ->
        Logger.debug("TARGET database stopped")
      {output, code} ->
        Logger.debug("pg_ctl stop returned #{code}: #{output}")
    end

    # Brief pause
    Process.sleep(500)

    # Start
    case System.cmd("pg_ctl", ["start", "-D", pgdata, "-l", "#{pgdata}/logfile"],
           stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("TARGET database start command issued")
        :ok

      {output, code} ->
        Logger.error("TARGET database start failed (code #{code}): #{output}")
        {:error, {:postgres_start_failed, code}}
    end
  end

  # =====================================================
  # Legacy API for backwards compatibility
  # =====================================================

  @doc """
  Legacy function - now just calls restart_target/1.
  """
  def restart_postgres(opts \\ []) do
    restart_target(opts)
  end
end
