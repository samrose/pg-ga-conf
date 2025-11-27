defmodule PgGaConf.Benchmark.Pgbench do
  @moduledoc """
  pgbench-based benchmark implementation.

  Uses PostgreSQL's built-in pgbench tool for TPC-B style benchmarks.
  Supports both OLTP (default) and read-only modes.

  ## Score Calculation

  Score = 1 / TPS (lower is better, so higher TPS = lower score)
  This allows optimizers to minimize the score.
  """

  @behaviour PgGaConf.Benchmark

  require Logger

  defstruct [
    :db_url,
    :db_name,
    :db_host,
    :db_port,
    :db_user,
    :db_password,
    :duration,
    :clients,
    :scale,
    :jobs,
    :read_only,
    :initialized
  ]

  @default_duration 60
  @default_clients 10
  @default_scale 10
  @default_jobs 2

  @impl true
  def init(opts) do
    db_url = Keyword.fetch!(opts, :db_url)
    parsed = parse_db_url(db_url)

    state = %__MODULE__{
      db_url: db_url,
      db_name: parsed.database,
      db_host: parsed.host,
      db_port: parsed.port,
      db_user: parsed.username,
      db_password: parsed.password,
      duration: Keyword.get(opts, :duration, @default_duration),
      clients: Keyword.get(opts, :clients, @default_clients),
      scale: Keyword.get(opts, :scale, @default_scale),
      jobs: Keyword.get(opts, :jobs, @default_jobs),
      read_only: Keyword.get(opts, :read_only, false),
      initialized: false
    }

    # Initialize pgbench tables if needed
    case ensure_initialized(state) do
      {:ok, state} -> {:ok, state}
      error -> error
    end
  end

  @impl true
  def run(%__MODULE__{} = state) do
    Logger.info("Running pgbench: #{state.duration}s, #{state.clients} clients, scale #{state.scale}")

    args = build_pgbench_args(state, :run)

    case run_pgbench(args, state) do
      {:ok, output} ->
        case parse_pgbench_output(output) do
          {:ok, metrics} ->
            # Score = inverse of TPS (lower is better)
            score = 1.0 / max(metrics.tps, 0.001)
            {:ok, score, metrics}

          {:error, reason} ->
            {:error, {:parse_error, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def apply_config(%__MODULE__{} = state, config) do
    Logger.info("Applying PostgreSQL config: #{map_size(config)} parameters")

    # Execute each ALTER SYSTEM command separately to avoid transaction block issues
    # (ALTER SYSTEM cannot run inside a transaction block)
    results =
      Enum.map(config, fn {param, value} ->
        formatted_value = format_pg_value(param, value)
        sql = "ALTER SYSTEM SET #{param} = '#{formatted_value}'"
        run_psql(sql, state)
      end)

    # Check for errors
    case Enum.find(results, fn res -> match?({:error, _}, res) end) do
      {:error, reason} ->
        {:error, {:apply_config_failed, reason}}

      nil ->
        # Reload config
        run_psql("SELECT pg_reload_conf()", state)

        # Check if restart is needed
        if needs_restart?(config) do
          Logger.warning("Some parameters require restart: #{inspect(restart_params(config))}")
          restart_postgres(state)
        else
          :ok
        end
    end
  end

  @impl true
  def reset(%__MODULE__{} = state) do
    Logger.info("Resetting pgbench tables")
    args = build_pgbench_args(state, :init)

    case run_pgbench(args, state) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:reset_failed, reason}}
    end
  end

  @impl true
  def cleanup(%__MODULE__{}) do
    :ok
  end

  # Private functions

  defp ensure_initialized(%__MODULE__{} = state) do
    if state.initialized do
      {:ok, state}
    else
      do_initialize(state)
    end
  end

  defp do_initialize(%__MODULE__{} = state) do
    Logger.info("Initializing pgbench tables (scale=#{state.scale})")
    args = build_pgbench_args(state, :init)

    case run_pgbench(args, state) do
      {:ok, _} ->
        {:ok, %{state | initialized: true}}

      {:error, reason} ->
        {:error, {:init_failed, reason}}
    end
  end

  defp build_pgbench_args(state, :init) do
    [
      "-i",
      "-s",
      to_string(state.scale),
      "-h",
      state.db_host,
      "-p",
      to_string(state.db_port),
      "-U",
      state.db_user,
      state.db_name
    ]
  end

  defp build_pgbench_args(state, :run) do
    base = [
      "-c",
      to_string(state.clients),
      "-j",
      to_string(state.jobs),
      "-T",
      to_string(state.duration),
      "-h",
      state.db_host,
      "-p",
      to_string(state.db_port),
      "-U",
      state.db_user,
      "--progress=10",
      state.db_name
    ]

    if state.read_only do
      ["-S" | base]
    else
      base
    end
  end

  defp run_pgbench(args, state) do
    env = build_env(state)

    case System.cmd("pgbench", args, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        Logger.error("pgbench failed (#{code}): #{output}")
        {:error, {:pgbench_failed, code, output}}
    end
  rescue
    e ->
      {:error, {:pgbench_error, Exception.message(e)}}
  end

  defp run_psql(sql, state) do
    env = build_env(state)

    args = [
      "-h",
      state.db_host,
      "-p",
      to_string(state.db_port),
      "-U",
      state.db_user,
      "-d",
      state.db_name,
      "-c",
      sql
    ]

    case System.cmd("psql", args, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:psql_failed, code, output}}
    end
  rescue
    e ->
      {:error, {:psql_error, Exception.message(e)}}
  end

  defp build_env(state) do
    env = [{"PGPASSWORD", state.db_password || ""}]

    # Add any additional environment variables
    env
  end

  defp parse_pgbench_output(output) do
    # Parse pgbench output for metrics
    # Example output (pgbench 15+):
    # transaction type: <builtin: TPC-B (sort of)>
    # scaling factor: 10
    # query mode: simple
    # number of clients: 10
    # number of threads: 2
    # duration: 60 s
    # number of transactions actually processed: 123456
    # latency average = 4.867 ms
    # tps = 2057.789012 (without initial connection time)
    #
    # Older versions say "(excluding connections establishing)"

    # Match both old and new pgbench output formats
    tps_regex = ~r/tps = ([\d.]+) \((?:without initial connection time|excluding connections)/
    latency_regex = ~r/latency average = ([\d.]+) ms/
    transactions_regex = ~r/number of transactions actually processed: (\d+)/

    with [_, tps_str] <- Regex.run(tps_regex, output),
         {tps, _} <- Float.parse(tps_str) do
      latency_avg =
        case Regex.run(latency_regex, output) do
          [_, lat_str] ->
            {lat, _} = Float.parse(lat_str)
            lat

          _ ->
            0.0
        end

      transactions =
        case Regex.run(transactions_regex, output) do
          [_, txn_str] -> String.to_integer(txn_str)
          _ -> 0
        end

      {:ok,
       %{
         tps: tps,
         latency_avg: latency_avg,
         transactions: transactions
       }}
    else
      _ ->
        {:error, {:parse_failed, output}}
    end
  end

  defp parse_db_url(url) do
    uri = URI.parse(url)

    %{
      host: uri.host || "localhost",
      port: uri.port || 5432,
      username: get_username(uri),
      password: get_password(uri),
      database: get_database(uri)
    }
  end

  defp get_username(uri) do
    case uri.userinfo do
      nil -> "postgres"
      info -> info |> String.split(":") |> hd()
    end
  end

  defp get_password(uri) do
    case uri.userinfo do
      nil -> nil
      info -> info |> String.split(":") |> Enum.at(1)
    end
  end

  defp get_database(uri) do
    case uri.path do
      nil -> "postgres"
      "/" <> db -> db
      path -> path
    end
  end

  defp format_pg_value(param, value) when is_atom(param) do
    format_pg_value(Atom.to_string(param), value)
  end

  defp format_pg_value(param, value) do
    cond do
      # Memory parameters (MB)
      param in ~w(shared_buffers effective_cache_size work_mem maintenance_work_mem
                  wal_buffers temp_buffers) ->
        "#{round(value)}MB"

      # WAL size parameters
      param in ~w(max_wal_size min_wal_size) ->
        "#{round(value)}MB"

      # Time parameters (ms)
      param in ~w(checkpoint_timeout bgwriter_delay) ->
        "#{round(value)}ms"

      # Float parameters
      param in ~w(checkpoint_completion_target seq_page_cost random_page_cost
                  cpu_tuple_cost cpu_index_tuple_cost cpu_operator_cost
                  parallel_tuple_cost parallel_setup_cost) ->
        Float.to_string(value * 1.0)

      # Integer parameters
      param in ~w(max_parallel_workers max_parallel_workers_per_gather
                  max_worker_processes effective_io_concurrency
                  bgwriter_lru_maxpages) ->
        to_string(round(value))

      # String/enum parameters
      true ->
        to_string(value)
    end
  end

  @restart_required_params ~w(shared_buffers max_connections max_worker_processes
                              max_parallel_workers wal_buffers huge_pages)

  @doc """
  Returns the list of PostgreSQL parameters that require a restart.
  """
  @spec restart_required_params() :: [String.t()]
  def restart_required_params, do: @restart_required_params

  @doc """
  Returns the list of restart-required parameters as atoms.
  """
  @spec restart_required_params_atoms() :: [atom()]
  def restart_required_params_atoms do
    Enum.map(@restart_required_params, &String.to_atom/1)
  end

  defp needs_restart?(config) do
    config
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.any?(&(&1 in @restart_required_params))
  end

  defp restart_params(config) do
    config
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in @restart_required_params))
  end

  defp restart_postgres(state) do
    Logger.info("Restarting PostgreSQL to apply configuration changes...")

    # Try pg_ctl restart first (works with local PostgreSQL)
    pgdata = System.get_env("PGDATA")

    if pgdata && File.dir?(pgdata) do
      # Use pg_ctl for local PostgreSQL managed by nix develop
      case System.cmd("pg_ctl", ["restart", "-D", pgdata, "-w", "-t", "30"],
             stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("PostgreSQL restarted successfully")
          # Wait for PostgreSQL to be ready
          wait_for_postgres(state, 10)

        {output, code} ->
          Logger.warning("pg_ctl restart failed (#{code}): #{output}")
          # Try alternative: stop and start
          try_stop_start(pgdata, state)
      end
    else
      # Try using pg_ctl with connection info
      Logger.warning("PGDATA not set, attempting restart via pg_ctl")
      case System.cmd("pg_ctl", ["restart", "-w", "-t", "30"], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("PostgreSQL restarted successfully")
          wait_for_postgres(state, 10)

        {output, _code} ->
          Logger.error("PostgreSQL restart failed: #{output}")
          {:error, :restart_failed}
      end
    end
  end

  defp try_stop_start(pgdata, state) do
    Logger.info("Trying stop/start sequence...")

    # Stop
    System.cmd("pg_ctl", ["stop", "-D", pgdata, "-m", "fast", "-w"], stderr_to_stdout: true)
    Process.sleep(1_000)

    # Start
    case System.cmd("pg_ctl", ["start", "-D", pgdata, "-w", "-l", "#{pgdata}/logfile"],
           stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("PostgreSQL started successfully")
        wait_for_postgres(state, 10)

      {output, code} ->
        Logger.error("PostgreSQL start failed (#{code}): #{output}")
        {:error, :restart_failed}
    end
  end

  defp wait_for_postgres(state, retries) when retries > 0 do
    case run_psql("SELECT 1", state) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Process.sleep(1_000)
        wait_for_postgres(state, retries - 1)
    end
  end

  defp wait_for_postgres(_state, 0) do
    Logger.error("PostgreSQL did not become ready after restart")
    {:error, :postgres_not_ready}
  end
end
