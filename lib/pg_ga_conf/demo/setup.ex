defmodule PgGaConf.Demo.Setup do
  @moduledoc """
  Demo database setup utilities.

  Creates a test database, populates it with sample data, and applies
  a baseline PostgreSQL configuration for optimization demos.

  Also provides PostgreSQL lifecycle management for self-contained demos.
  """

  require Logger

  @default_db_name "pg_ga_conf_demo"
  @default_scale 10
  @postgres_start_timeout_ms 30_000

  # ========================================
  # PostgreSQL Lifecycle Management
  # ========================================

  @doc """
  Ensures PostgreSQL is running. Starts it if not already running.

  Returns `:ok` if PostgreSQL is running (or was successfully started),
  `{:error, reason}` otherwise.
  """
  def ensure_postgres_running do
    if postgres_running?() do
      IO.puts "  PostgreSQL is already running"
      :ok
    else
      start_postgres()
    end
  end

  @doc """
  Checks if PostgreSQL is currently running and accepting connections.
  """
  def postgres_running? do
    pgdata = System.get_env("PGDATA")

    cond do
      # Check via pg_ctl status if PGDATA is set
      pgdata && File.dir?(pgdata) ->
        case System.cmd("pg_ctl", ["status", "-D", pgdata], stderr_to_stdout: true) do
          {_output, 0} -> true
          _ -> false
        end

      # Fallback: try to connect
      true ->
        case System.cmd("pg_isready", ["-h", "localhost", "-p", "5432"], stderr_to_stdout: true) do
          {_output, 0} -> true
          _ -> false
        end
    end
  end

  @doc """
  Starts PostgreSQL server.

  Uses PGDATA environment variable to locate the data directory.
  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  def start_postgres do
    pgdata = System.get_env("PGDATA")

    cond do
      is_nil(pgdata) || !File.dir?(pgdata) ->
        {:error, "PGDATA not set or directory doesn't exist. Run 'nix develop' first."}

      true ->
        IO.puts "  Starting PostgreSQL..."

        # Ensure data directory is initialized
        init_result =
          if File.exists?(Path.join(pgdata, "PG_VERSION")) do
            :ok
          else
            IO.puts "  Initializing PostgreSQL data directory..."
            case System.cmd("initdb", ["-D", pgdata], stderr_to_stdout: true) do
              {_output, 0} -> :ok
              {output, code} -> {:error, "initdb failed (#{code}): #{output}"}
            end
          end

        case init_result do
          :ok ->
            # Start PostgreSQL
            logfile = Path.join(pgdata, "logfile")
            case System.cmd("pg_ctl", ["start", "-D", pgdata, "-l", logfile, "-w", "-t", "30"],
                   stderr_to_stdout: true) do
              {_output, 0} ->
                IO.puts "  PostgreSQL started successfully"
                # Wait for it to be ready
                wait_for_postgres(@postgres_start_timeout_ms)

              {output, code} ->
                {:error, "pg_ctl start failed (#{code}): #{output}"}
            end

          error ->
            error
        end
    end
  end

  @doc """
  Stops PostgreSQL server gracefully.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  def stop_postgres do
    pgdata = System.get_env("PGDATA")

    cond do
      is_nil(pgdata) || !File.dir?(pgdata) ->
        IO.puts "  PGDATA not set, assuming PostgreSQL not managed by demo"
        :ok

      !postgres_running?() ->
        IO.puts "  PostgreSQL is not running"
        :ok

      true ->
        IO.puts "  Stopping PostgreSQL..."

        case System.cmd("pg_ctl", ["stop", "-D", pgdata, "-m", "fast", "-w", "-t", "30"],
               stderr_to_stdout: true) do
          {_output, 0} ->
            IO.puts "  PostgreSQL stopped"
            :ok

          {output, code} ->
            {:error, "pg_ctl stop failed (#{code}): #{output}"}
        end
    end
  end

  @doc """
  Restarts PostgreSQL server.
  """
  def restart_postgres do
    pgdata = System.get_env("PGDATA")

    if is_nil(pgdata) || !File.dir?(pgdata) do
      {:error, "PGDATA not set or directory doesn't exist"}
    else
      IO.puts "  Restarting PostgreSQL..."

      case System.cmd("pg_ctl", ["restart", "-D", pgdata, "-w", "-t", "30"],
             stderr_to_stdout: true) do
        {_output, 0} ->
          IO.puts "  PostgreSQL restarted"
          wait_for_postgres(@postgres_start_timeout_ms)

        {_output, _code} ->
          # Try stop/start if restart fails
          IO.puts "  Restart failed, trying stop/start..."
          with :ok <- stop_postgres(),
               :ok <- start_postgres() do
            :ok
          end
      end
    end
  end

  defp wait_for_postgres(timeout_ms, elapsed \\ 0) do
    if elapsed >= timeout_ms do
      {:error, :timeout}
    else
      case System.cmd("pg_isready", ["-h", "localhost", "-p", "5432"], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok
        _ ->
          Process.sleep(500)
          wait_for_postgres(timeout_ms, elapsed + 500)
      end
    end
  end

  # ========================================
  # Full Lifecycle Setup/Teardown
  # ========================================

  @doc """
  Full self-contained setup: starts PostgreSQL, creates database, sets up demo data.

  This is the recommended entry point for running the demo from scratch.

  ## Options
    * `:db_url` - Base PostgreSQL URL (default: postgres://postgres:postgres@localhost/postgres)
    * `:db_name` - Name for demo database (default: pg_ga_conf_demo)
    * `:scale` - pgbench scale factor (default: 10)
    * `:drop_existing` - Drop existing database if exists (default: true)
    * `:start_postgres` - Start PostgreSQL if not running (default: true)

  Returns `{:ok, demo_db_url}` with the URL to the created demo database.
  """
  def full_setup(opts \\ []) do
    start_pg = Keyword.get(opts, :start_postgres, true)

    IO.puts "\n=== Full Demo Setup ==="

    # Step 1: Ensure PostgreSQL is running
    if start_pg do
      case ensure_postgres_running() do
        :ok -> :ok
        {:error, reason} ->
          IO.puts "  ERROR: Failed to start PostgreSQL: #{inspect(reason)}"
          throw({:setup_failed, :postgres_start, reason})
      end
    end

    # Step 2: Run normal setup
    setup(opts)
  catch
    {:setup_failed, stage, reason} ->
      {:error, {stage, reason}}
  end

  @doc """
  Full self-contained teardown: drops database, optionally stops PostgreSQL.

  ## Options
    * `:db_url` - Base PostgreSQL URL
    * `:db_name` - Name of demo database to drop
    * `:stop_postgres` - Stop PostgreSQL after cleanup (default: false)
    * `:reset_config` - Reset PostgreSQL config to defaults (default: true)
  """
  def full_teardown(opts \\ []) do
    base_url = Keyword.get(opts, :db_url, "postgres://postgres:postgres@localhost/postgres")
    db_name = Keyword.get(opts, :db_name, @default_db_name)
    stop_pg = Keyword.get(opts, :stop_postgres, false)
    do_reset_config = Keyword.get(opts, :reset_config, true)

    IO.puts "\n=== Full Demo Teardown ==="
    IO.puts "  Database: #{db_name}"

    # Step 1: Reset config
    if do_reset_config && postgres_running?() do
      IO.puts "  Resetting PostgreSQL config..."
      reset_config(base_url)
    end

    # Step 2: Drop database
    if postgres_running?() do
      IO.puts "  Dropping demo database '#{db_name}'..."
      teardown(opts)
    end

    # Step 3: Stop PostgreSQL if requested
    if stop_pg do
      stop_postgres()
    end

    IO.puts "  Teardown complete!"
    :ok
  end

  @doc """
  Sets up a demo database with pgbench data and baseline config.

  ## Options
    * `:db_url` - Base PostgreSQL URL (default: postgres://postgres:postgres@localhost/postgres)
    * `:db_name` - Name for demo database (default: pg_ga_conf_demo)
    * `:scale` - pgbench scale factor (default: 10)
    * `:drop_existing` - Drop existing database if exists (default: true)

  Returns `{:ok, demo_db_url}` with the URL to the created demo database.
  """
  def setup(opts \\ []) do
    base_url = Keyword.get(opts, :db_url, "postgres://postgres:postgres@localhost/postgres")
    db_name = Keyword.get(opts, :db_name, @default_db_name)
    scale = Keyword.get(opts, :scale, @default_scale)
    drop_existing = Keyword.get(opts, :drop_existing, true)

    parsed = parse_db_url(base_url)

    IO.puts "Setting up demo database..."
    IO.puts "  Host: #{parsed.host}:#{parsed.port}"
    IO.puts "  Database: #{db_name}"
    IO.puts "  Scale factor: #{scale}"

    with :ok <- maybe_drop_database(parsed, db_name, drop_existing),
         :ok <- create_database(parsed, db_name),
         demo_url = build_demo_url(parsed, db_name),
         :ok <- initialize_pgbench(demo_url, scale),
         :ok <- apply_baseline_config(demo_url),
         :ok <- create_sample_tables(demo_url) do
      IO.puts "  Demo database ready!"
      {:ok, demo_url}
    end
  end

  @doc """
  Tears down the demo database.
  """
  def teardown(opts \\ []) do
    base_url = Keyword.get(opts, :db_url, "postgres://postgres:postgres@localhost/postgres")
    db_name = Keyword.get(opts, :db_name, @default_db_name)

    parsed = parse_db_url(base_url)
    drop_database(parsed, db_name)
  end

  @doc """
  Resets PostgreSQL config to defaults.
  """
  def reset_config(db_url) do
    parsed = parse_db_url(db_url)

    # Run each command separately to avoid transaction block issues
    commands = [
      "ALTER SYSTEM RESET ALL",
      "SELECT pg_reload_conf()"
    ]

    Enum.each(commands, &run_psql(&1, parsed))
    IO.puts "  PostgreSQL config reset to defaults"
    :ok
  end

  # Private functions

  defp maybe_drop_database(_parsed, _db_name, false), do: :ok

  defp maybe_drop_database(parsed, db_name, true) do
    # Check if database exists
    check_sql = "SELECT 1 FROM pg_database WHERE datname = '#{db_name}'"

    case run_psql(check_sql, parsed) do
      {:ok, output} ->
        if String.contains?(output, "1") do
          IO.puts "  Dropping existing database #{db_name}..."
          drop_database(parsed, db_name)
        else
          :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp drop_database(parsed, db_name) do
    # Terminate connections first
    terminate_sql = """
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '#{db_name}' AND pid <> pg_backend_pid();
    """

    run_psql(terminate_sql, parsed)

    # Drop database
    drop_sql = "DROP DATABASE IF EXISTS #{db_name}"

    case run_psql(drop_sql, parsed) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:drop_failed, reason}}
    end
  end

  defp create_database(parsed, db_name) do
    IO.puts "  Creating database #{db_name}..."

    sql = "CREATE DATABASE #{db_name}"

    case run_psql(sql, parsed) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  end

  defp initialize_pgbench(db_url, scale) do
    IO.puts "  Initializing pgbench tables (scale=#{scale})..."

    parsed = parse_db_url(db_url)
    env = [{"PGPASSWORD", parsed.password || ""}]

    args = [
      "-i",
      "-s", to_string(scale),
      "-h", parsed.host,
      "-p", to_string(parsed.port),
      "-U", parsed.username,
      parsed.database
    ]

    case System.cmd("pgbench", args, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        IO.puts "  pgbench tables created"
        :ok

      {output, code} ->
        IO.puts "  pgbench init failed (#{code}): #{output}"
        {:error, {:pgbench_init_failed, code}}
    end
  end

  defp apply_baseline_config(db_url) do
    IO.puts "  Applying baseline PostgreSQL config..."

    parsed = parse_db_url(db_url)

    # Conservative baseline config - intentionally suboptimal for demo
    # Each command must be run separately to avoid transaction block issues
    baseline_commands = [
      # Memory settings (conservative)
      "ALTER SYSTEM SET shared_buffers = '128MB'",
      "ALTER SYSTEM SET effective_cache_size = '512MB'",
      "ALTER SYSTEM SET work_mem = '4MB'",
      "ALTER SYSTEM SET maintenance_work_mem = '64MB'",

      # Checkpoint settings
      "ALTER SYSTEM SET checkpoint_completion_target = '0.5'",
      "ALTER SYSTEM SET max_wal_size = '256MB'",

      # Planner settings
      "ALTER SYSTEM SET random_page_cost = '4.0'",
      # Note: effective_io_concurrency must be 0 on macOS (no posix_fadvise)
      # We skip it here and let the optimizer try different values

      # Parallelism (disabled for baseline)
      "ALTER SYSTEM SET max_parallel_workers_per_gather = '0'",

      # Reload config
      "SELECT pg_reload_conf()"
    ]

    results = Enum.map(baseline_commands, &run_psql(&1, parsed))

    case Enum.find(results, fn res -> match?({:error, _}, res) end) do
      nil ->
        IO.puts "  Baseline config applied (conservative settings)"
        :ok

      {:error, reason} ->
        {:error, {:config_failed, reason}}
    end
  end

  defp create_sample_tables(db_url) do
    IO.puts "  Creating additional sample tables..."

    parsed = parse_db_url(db_url)

    # Create some additional tables to make workload more realistic
    sql = """
    -- Users table
    CREATE TABLE IF NOT EXISTS demo_users (
      id SERIAL PRIMARY KEY,
      username VARCHAR(100) NOT NULL,
      email VARCHAR(255) NOT NULL,
      created_at TIMESTAMP DEFAULT NOW(),
      status VARCHAR(20) DEFAULT 'active'
    );

    -- Orders table
    CREATE TABLE IF NOT EXISTS demo_orders (
      id SERIAL PRIMARY KEY,
      user_id INTEGER REFERENCES demo_users(id),
      total_amount DECIMAL(10,2),
      status VARCHAR(20) DEFAULT 'pending',
      created_at TIMESTAMP DEFAULT NOW()
    );

    -- Order items table
    CREATE TABLE IF NOT EXISTS demo_order_items (
      id SERIAL PRIMARY KEY,
      order_id INTEGER REFERENCES demo_orders(id),
      product_name VARCHAR(200),
      quantity INTEGER,
      unit_price DECIMAL(10,2)
    );

    -- Populate users
    INSERT INTO demo_users (username, email, status)
    SELECT
      'user_' || i,
      'user_' || i || '@example.com',
      CASE WHEN random() > 0.1 THEN 'active' ELSE 'inactive' END
    FROM generate_series(1, 10000) AS i
    ON CONFLICT DO NOTHING;

    -- Populate orders
    INSERT INTO demo_orders (user_id, total_amount, status, created_at)
    SELECT
      (random() * 9999 + 1)::integer,
      (random() * 500 + 10)::decimal(10,2),
      CASE
        WHEN random() < 0.7 THEN 'completed'
        WHEN random() < 0.9 THEN 'pending'
        ELSE 'cancelled'
      END,
      NOW() - (random() * 365 || ' days')::interval
    FROM generate_series(1, 50000) AS i
    ON CONFLICT DO NOTHING;

    -- Populate order items
    INSERT INTO demo_order_items (order_id, product_name, quantity, unit_price)
    SELECT
      (random() * 49999 + 1)::integer,
      'Product ' || (random() * 1000)::integer,
      (random() * 10 + 1)::integer,
      (random() * 100 + 1)::decimal(10,2)
    FROM generate_series(1, 150000) AS i
    ON CONFLICT DO NOTHING;

    -- Create indexes
    CREATE INDEX IF NOT EXISTS idx_demo_users_status ON demo_users(status);
    CREATE INDEX IF NOT EXISTS idx_demo_orders_user_id ON demo_orders(user_id);
    CREATE INDEX IF NOT EXISTS idx_demo_orders_status ON demo_orders(status);
    CREATE INDEX IF NOT EXISTS idx_demo_orders_created ON demo_orders(created_at);
    CREATE INDEX IF NOT EXISTS idx_demo_order_items_order_id ON demo_order_items(order_id);

    -- Analyze tables
    ANALYZE demo_users;
    ANALYZE demo_orders;
    ANALYZE demo_order_items;
    ANALYZE;
    """

    case run_psql(sql, parsed) do
      {:ok, _} ->
        IO.puts "  Sample tables created (users, orders, order_items)"
        :ok

      {:error, reason} ->
        # Non-fatal - pgbench tables are enough
        IO.puts "  Warning: Sample tables creation failed: #{inspect(reason)}"
        :ok
    end
  end

  defp run_psql(sql, parsed) do
    env = [{"PGPASSWORD", parsed.password || ""}]

    args = [
      "-h", parsed.host,
      "-p", to_string(parsed.port),
      "-U", parsed.username,
      "-d", parsed.database,
      "-c", sql
    ]

    case System.cmd("psql", args, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:psql_failed, code, output}}
    end
  rescue
    e -> {:error, {:psql_error, Exception.message(e)}}
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

  defp build_demo_url(parsed, db_name) do
    auth = if parsed.password do
      "#{parsed.username}:#{parsed.password}"
    else
      parsed.username
    end

    "postgres://#{auth}@#{parsed.host}:#{parsed.port}/#{db_name}"
  end
end
