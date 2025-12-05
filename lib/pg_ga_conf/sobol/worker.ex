defmodule PgGaConf.Sobol.Worker do
  @moduledoc """
  Manages a single PostgreSQL instance for parallel Sobol evaluation.

  Each worker:
  - Has its own PostgreSQL instance (separate PGDATA, port)
  - Clones the source database at batch start
  - Runs assigned samples sequentially
  - Reports results back to coordinator
  """

  require Logger

  alias PgGaConf.KnobSpace

  @base_port 5434
  @pgdata_prefix ".postgres-worker-"
  @init_timeout 60_000

  defstruct [
    :id,
    :port,
    :pgdata,
    :host,
    :user,
    :password,
    :started
  ]

  @doc """
  Create a new worker configuration.
  """
  def new(worker_id, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    %__MODULE__{
      id: worker_id,
      port: @base_port + worker_id,
      pgdata: Path.join(base_dir, "#{@pgdata_prefix}#{worker_id}"),
      host: "localhost",
      user: "postgres",
      password: "",
      started: false
    }
  end

  @doc """
  Initialize and start the worker's PostgreSQL instance.
  """
  def start(%__MODULE__{} = worker) do
    Logger.info("Worker #{worker.id}: Initializing PostgreSQL on port #{worker.port}")

    with :ok <- init_pgdata(worker),
         :ok <- configure_postgresql(worker),
         :ok <- start_postgresql(worker),
         :ok <- wait_for_ready(worker) do
      Logger.info("Worker #{worker.id}: PostgreSQL ready")
      {:ok, %{worker | started: true}}
    else
      {:error, reason} = error ->
        Logger.error("Worker #{worker.id}: Failed to start - #{inspect(reason)}")
        cleanup(worker)
        error
    end
  end

  @doc """
  Stop the worker's PostgreSQL instance and cleanup.
  """
  def stop(%__MODULE__{} = worker) do
    Logger.info("Worker #{worker.id}: Stopping")
    cleanup(worker)
    :ok
  end

  @doc """
  Clone a database from source to this worker.
  """
  def clone_database(%__MODULE__{} = worker, source_config, db_name) do
    Logger.debug("Worker #{worker.id}: Cloning database #{db_name}")

    source_host = source_config[:host] || "localhost"
    source_port = source_config[:port] || 5433
    source_user = source_config[:user] || "postgres"
    source_password = source_config[:password] || ""

    # Drop existing database if any
    run_psql(worker, "postgres", "DROP DATABASE IF EXISTS #{db_name}")

    # Create fresh database
    run_psql(worker, "postgres", "CREATE DATABASE #{db_name}")

    # Stream pg_dump to pg_restore
    env = [
      {"PGPASSWORD", source_password}
    ]

    dump_cmd = "pg_dump -h #{source_host} -p #{source_port} -U #{source_user} -Fc #{db_name}"
    restore_cmd = "pg_restore -h #{worker.host} -p #{worker.port} -U #{worker.user} -d #{db_name} --no-owner --no-acl"

    case System.cmd("bash", ["-c", "#{dump_cmd} | #{restore_cmd}"],
           env: env,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.debug("Worker #{worker.id}: Database cloned successfully")
        :ok

      {output, code} ->
        Logger.warning("Worker #{worker.id}: Clone returned code #{code}: #{String.slice(output, 0, 200)}")
        # Try once more
        retry_clone(worker, source_config, db_name, env)
    end
  end

  defp retry_clone(worker, source_config, db_name, env) do
    source_host = source_config[:host] || "localhost"
    source_port = source_config[:port] || 5433
    source_user = source_config[:user] || "postgres"

    Process.sleep(1_000)
    run_psql(worker, "postgres", "DROP DATABASE IF EXISTS #{db_name}")
    run_psql(worker, "postgres", "CREATE DATABASE #{db_name}")

    dump_cmd = "pg_dump -h #{source_host} -p #{source_port} -U #{source_user} -Fc #{db_name}"
    restore_cmd = "pg_restore -h #{worker.host} -p #{worker.port} -U #{worker.user} -d #{db_name} --no-owner --no-acl"

    case System.cmd("bash", ["-c", "#{dump_cmd} | #{restore_cmd}"],
           env: env,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, {:clone_failed, code, output}}
    end
  end

  @doc """
  Apply PostgreSQL configuration and restart if needed.
  """
  def apply_config(%__MODULE__{} = worker, config, db_name, restart_required? \\ false) do
    Enum.each(config, fn {param, value} ->
      formatted = KnobSpace.format_value(param, value)
      run_psql(worker, db_name, "ALTER SYSTEM SET #{param} = '#{formatted}'")
    end)

    if restart_required? do
      restart_postgresql(worker)
    else
      run_psql(worker, db_name, "SELECT pg_reload_conf()")
    end

    :ok
  end

  @doc """
  Run pgbench benchmark on this worker.
  """
  def run_benchmark(%__MODULE__{} = worker, db_name, benchmark_spec) do
    duration = benchmark_spec[:duration] || 15
    clients = benchmark_spec[:clients] || 8
    workload_file = benchmark_spec[:workload_file]

    args =
      [
        "-h", worker.host,
        "-p", to_string(worker.port),
        "-U", worker.user,
        "-c", to_string(clients),
        "-j", "2",
        "-T", to_string(duration),
        "--no-vacuum",
        db_name
      ]
      |> maybe_add_workload_file(workload_file)

    env = [{"PGPASSWORD", worker.password}]

    case System.cmd("pgbench", args, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        parse_pgbench_result(output)

      {output, _code} ->
        Logger.warning("Worker #{worker.id}: pgbench failed: #{String.slice(output, 0, 200)}")
        {:error, :benchmark_failed}
    end
  end

  defp maybe_add_workload_file(args, nil), do: args
  defp maybe_add_workload_file(args, file), do: args ++ ["-f", file]

  defp parse_pgbench_result(output) do
    case Regex.run(~r/tps = ([\d.]+)/, output) do
      [_, tps_str] ->
        tps = String.to_float(tps_str)
        {:ok, 1.0 / max(tps, 0.001)}

      _ ->
        {:error, :parse_failed}
    end
  end

  # Private functions

  defp init_pgdata(%__MODULE__{pgdata: pgdata}) do
    # Clean up any existing data
    if File.dir?(pgdata) do
      File.rm_rf!(pgdata)
    end

    case System.cmd("initdb", ["-D", pgdata, "-U", "postgres", "--no-locale", "--encoding=UTF8"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:initdb_failed, code, output}}
    end
  end

  defp configure_postgresql(%__MODULE__{pgdata: pgdata, port: port}) do
    config_additions = """
    unix_socket_directories = '#{pgdata}'
    listen_addresses = 'localhost'
    port = #{port}
    shared_buffers = 256MB
    max_connections = 50
    """

    config_file = Path.join(pgdata, "postgresql.conf")
    File.write!(config_file, File.read!(config_file) <> "\n" <> config_additions)
    :ok
  end

  defp start_postgresql(%__MODULE__{pgdata: pgdata}) do
    logfile = Path.join(pgdata, "logfile")

    case System.cmd("pg_ctl", ["start", "-D", pgdata, "-l", logfile, "-w", "-t", "30"],
           stderr_to_stdout: true,
           env: [{"PGDATA", nil}]
         ) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:pg_start_failed, code, output}}
    end
  end

  defp restart_postgresql(%__MODULE__{pgdata: pgdata}) do
    logfile = Path.join(pgdata, "logfile")

    System.cmd("pg_ctl", ["restart", "-D", pgdata, "-l", logfile, "-w", "-t", "30"],
      stderr_to_stdout: true,
      env: [{"PGDATA", nil}]
    )

    wait_for_ready_simple(pgdata)
    :ok
  end

  defp wait_for_ready(%__MODULE__{host: host, port: port}) do
    deadline = System.monotonic_time(:millisecond) + @init_timeout
    do_wait_for_ready(host, port, deadline)
  end

  defp do_wait_for_ready(host, port, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case System.cmd("pg_isready", ["-h", host, "-p", to_string(port)], stderr_to_stdout: true) do
        {_, 0} -> :ok
        _ ->
          Process.sleep(500)
          do_wait_for_ready(host, port, deadline)
      end
    end
  end

  defp wait_for_ready_simple(pgdata) do
    # Simple wait after restart
    Process.sleep(1_000)

    port =
      Path.join(pgdata, "postgresql.conf")
      |> File.read!()
      |> then(fn content ->
        case Regex.run(~r/port = (\d+)/, content) do
          [_, p] -> String.to_integer(p)
          _ -> 5432
        end
      end)

    deadline = System.monotonic_time(:millisecond) + 30_000
    do_wait_for_ready("localhost", port, deadline)
  end

  defp run_psql(%__MODULE__{host: host, port: port, user: user, password: password}, db, sql) do
    System.cmd("psql",
      ["-h", host, "-p", to_string(port), "-U", user, "-d", db, "-c", sql],
      env: [{"PGPASSWORD", password}],
      stderr_to_stdout: true
    )
  end

  defp cleanup(%__MODULE__{pgdata: pgdata}) do
    # Stop PostgreSQL if running
    if File.exists?(Path.join(pgdata, "postmaster.pid")) do
      System.cmd("pg_ctl", ["stop", "-D", pgdata, "-m", "immediate", "-w", "-t", "10"],
        stderr_to_stdout: true,
        env: [{"PGDATA", nil}]
      )
      Process.sleep(500)
    end

    # Remove data directory
    if File.dir?(pgdata) do
      File.rm_rf(pgdata)
    end
  end
end
