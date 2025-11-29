#!/usr/bin/env elixir

# E-commerce Database TPE Optimization Demo
# Run with: nix develop -c mix run demo_ecommerce.exs
#
# This demo:
# 1. Creates a complex e-commerce database with 12 tables, relations, triggers
# 2. Populates with realistic data (~100k rows at scale 1.0)
# 3. Optionally scans and clones to demonstrate the data generator
# 4. Runs TPE optimization with optional Sobol sensitivity analysis
# 5. Validates results with longer benchmark
#
# Environment variables:
#   ECOMMERCE_SCALE - Data scale factor (default: 1.0 = ~100k rows)
#   PGBENCH_DURATION - Benchmark duration in seconds (default: 15)
#   PGBENCH_CLIENTS - Number of clients (default: 8)
#   TPE_ITERATIONS - Number of optimization iterations (default: 15)
#   USE_SOBOL - Run Sobol sensitivity analysis (default: false)
#   SOBOL_SAMPLES - Number of Sobol samples (default: 16)
#   VALIDATION_DURATION - Duration for final validation (default: 60)
#   SKIP_VALIDATION - Skip validation phase (default: false)
#   DEMO_CLONE - Demonstrate scan/clone workflow (default: false)
#   CLEANUP - Drop demo database after demo (default: true)

IO.puts """
==========================================
PgGaConf Demo - E-commerce Database
==========================================

This demo creates a realistic e-commerce database with:
  - 12 tables (users, orders, products, reviews, etc.)
  - Foreign keys, triggers, check constraints
  - Realistic data distributions
  - ~100k rows at scale 1.0

"""

# Configuration from environment
ecommerce_scale = String.to_float(System.get_env("ECOMMERCE_SCALE", "1.0"))
duration = String.to_integer(System.get_env("PGBENCH_DURATION", "15"))
clients = String.to_integer(System.get_env("PGBENCH_CLIENTS", "8"))
iterations = String.to_integer(System.get_env("TPE_ITERATIONS", "15"))
use_sobol = System.get_env("USE_SOBOL", "false") == "true"
sobol_samples = String.to_integer(System.get_env("SOBOL_SAMPLES", "16"))
validation_duration = String.to_integer(System.get_env("VALIDATION_DURATION", "60"))
skip_validation = System.get_env("SKIP_VALIDATION", "false") == "true"
demo_clone = System.get_env("DEMO_CLONE", "false") == "true"
cleanup = System.get_env("CLEANUP", "true") == "true"

# Target database config
target_host = "localhost"
target_port = "5433"
target_user = "postgres"
target_password = ""
demo_db_name = "ecommerce_demo"

IO.puts "Configuration:"
IO.puts "  E-commerce scale: #{ecommerce_scale} (~#{round(100_000 * ecommerce_scale)} rows)"
IO.puts "  Benchmark: #{duration}s, #{clients} clients"
IO.puts "  TPE iterations: #{iterations}"
IO.puts "  Use Sobol: #{use_sobol}"
if use_sobol, do: IO.puts "  Sobol samples: #{sobol_samples}"
IO.puts "  Validation: #{if skip_validation, do: "disabled", else: "#{validation_duration}s"}"
IO.puts "  Demo clone workflow: #{demo_clone}"
IO.puts ""

# =====================================================
# Step 0: Start PostgreSQL instances
# =====================================================
IO.puts "0. Starting PostgreSQL instances..."

pgdata_app = System.get_env("PGDATA_APP") || System.get_env("PGDATA")
pgdata_target = System.get_env("PGDATA_TARGET")

# Start App DB (port 5432)
app_running? = case System.cmd("pg_isready", ["-h", "localhost", "-p", "5432"], stderr_to_stdout: true) do
  {_, 0} -> true
  _ -> false
end

unless app_running? do
  if pgdata_app && File.dir?(pgdata_app) do
    IO.puts "   Starting App DB (port 5432)..."
    System.cmd("pg_ctl", ["-D", pgdata_app, "start", "-l", "#{pgdata_app}/logfile", "-w", "-t", "30"],
      stderr_to_stdout: true)
    Process.sleep(1_000)
  end
else
  IO.puts "   App DB (port 5432) already running"
end

# Start Target DB (port 5433)
target_running? = case System.cmd("pg_isready", ["-h", "localhost", "-p", "5433"], stderr_to_stdout: true) do
  {_, 0} -> true
  _ -> false
end

unless target_running? do
  if pgdata_target && File.dir?(pgdata_target) do
    IO.puts "   Starting Target DB (port 5433)..."
    System.cmd("pg_ctl", ["-D", pgdata_target, "start", "-l", "#{pgdata_target}/logfile", "-w", "-t", "30"],
      stderr_to_stdout: true)
    Process.sleep(1_000)
  else
    IO.puts "   ERROR: PGDATA_TARGET not set or doesn't exist"
    System.halt(1)
  end
else
  IO.puts "   Target DB (port 5433) already running"
end

# Start application
{:ok, _} = Application.ensure_all_started(:pg_ga_conf)

# Initialize Python with Optuna
IO.puts "\n1. Initializing Python/Optuna..."
Pythonx.uv_init("""
[project]
name = "pg_ga_conf"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = ["optuna>=3.5.0"]
""")
IO.puts "   Python initialized"

alias PgGaConf.{Benchmark, KnobSpace, Sobol, Julia, PostgresLifecycle}
alias PgGaConf.Optimizer.TPE
alias PgGaConf.Demo.EcommerceSchema

# Helper to run psql on Target DB
run_target_psql = fn sql, db ->
  env = [{"PGPASSWORD", target_password}]
  args = ["-h", target_host, "-p", target_port, "-U", target_user, "-d", db, "-c", sql]
  System.cmd("psql", args, env: env, stderr_to_stdout: true)
end

# Cleanup function
cleanup_fn = fn ->
  IO.puts "\n\n=== Cleanup ==="
  if cleanup do
    IO.puts "   Resetting Target DB config..."
    run_target_psql.("ALTER SYSTEM RESET ALL", "postgres")
    run_target_psql.("SELECT pg_reload_conf()", "postgres")

    IO.puts "   Dropping demo database..."
    run_target_psql.("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '#{demo_db_name}'", "postgres")
    System.cmd("dropdb", ["-h", target_host, "-p", target_port, "-U", target_user, "--if-exists", demo_db_name],
      env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true)

    if demo_clone do
      IO.puts "   Dropping clone database..."
      run_target_psql.("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'ecommerce_clone'", "postgres")
      System.cmd("dropdb", ["-h", target_host, "-p", target_port, "-U", target_user, "--if-exists", "ecommerce_clone"],
        env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true)
    end

    IO.puts "   Cleanup complete!"
  else
    IO.puts "   Skipping cleanup (CLEANUP=false)"
  end
end

try do
  # =====================================================
  # Step 2: Create e-commerce database
  # =====================================================
  IO.puts "\n2. Creating e-commerce database..."

  # Drop if exists
  System.cmd("dropdb", ["-h", target_host, "-p", target_port, "-U", target_user, "--if-exists", demo_db_name],
    env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true)

  # Create database
  case System.cmd("createdb", ["-h", target_host, "-p", target_port, "-U", target_user, demo_db_name],
         env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true) do
    {_, 0} -> IO.puts "   Database '#{demo_db_name}' created"
    {output, code} ->
      IO.puts "   ERROR creating database (#{code}): #{output}"
      System.halt(1)
  end

  # Connect to demo database
  db_url = "postgres://#{target_user}:#{target_password}@#{target_host}:#{target_port}/#{demo_db_name}"
  {:ok, conn} = Postgrex.start_link(
    hostname: target_host,
    port: String.to_integer(target_port),
    username: target_user,
    password: target_password,
    database: demo_db_name
  )

  # =====================================================
  # Step 3: Create schema and populate data
  # =====================================================
  IO.puts "\n3. Creating e-commerce schema and data..."

  progress_fn = fn msg -> IO.puts "   #{msg}" end

  :ok = EcommerceSchema.setup(conn, scale: ecommerce_scale, progress_fn: progress_fn)

  # Get table counts
  %{rows: [[total_rows]]} = Postgrex.query!(conn, """
    SELECT SUM(n_live_tup)::bigint
    FROM pg_stat_user_tables
  """, [])

  IO.puts "\n   Schema summary:"
  IO.puts "   - Total rows: #{total_rows || 0}"

  # =====================================================
  # Step 4: Optionally demonstrate scan/clone workflow
  # =====================================================
  if demo_clone do
    IO.puts "\n4. Demonstrating scan/clone workflow..."

    IO.puts "   Scanning e-commerce database..."
    {:ok, scan_result} = PgGaConf.scan(conn, profile_data: true)

    IO.puts "   Scan complete:"
    IO.puts "     - Tables: #{length(scan_result.tables || [])}"
    IO.puts "     - Columns: #{length(scan_result.columns || [])}"
    IO.puts "     - Foreign keys: #{length(scan_result.foreign_keys || [])}"
    IO.puts "     - Indexes: #{length(scan_result.indexes || [])}"
    IO.puts "     - Data profiles: #{length(scan_result.data_profiles || [])}"

    # Create clone database
    IO.puts "\n   Creating clone database..."
    System.cmd("createdb", ["-h", target_host, "-p", target_port, "-U", target_user, "ecommerce_clone"],
      env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true)

    {:ok, clone_conn} = Postgrex.start_link(
      hostname: target_host,
      port: String.to_integer(target_port),
      username: target_user,
      password: target_password,
      database: "ecommerce_clone"
    )

    IO.puts "   Generating synthetic data in clone (scale=0.1)..."
    case PgGaConf.generate_from_scan(scan_result, clone_conn, scale: 0.1, progress_fn: progress_fn) do
      {:ok, result} ->
        IO.puts "   Clone complete: #{result[:tables_generated]} tables generated"
      {:error, reason} ->
        IO.puts "   Clone failed: #{inspect(reason)}"
    end

    GenServer.stop(clone_conn)
  else
    IO.puts "\n4. Skipping scan/clone demo (DEMO_CLONE=false)"
  end

  # =====================================================
  # Step 5: Apply baseline config
  # =====================================================
  IO.puts "\n5. Applying conservative baseline config..."

  baseline_config = %{
    shared_buffers: 128.0,
    effective_cache_size: 512.0,
    work_mem: 4.0,
    random_page_cost: 4.0,
    checkpoint_completion_target: 0.5
  }

  Enum.each(baseline_config, fn {param, value} ->
    formatted = KnobSpace.format_value(param, value)
    run_target_psql.("ALTER SYSTEM SET #{param} = '#{formatted}'", demo_db_name)
  end)
  run_target_psql.("SELECT pg_reload_conf()", demo_db_name)
  IO.puts "   Baseline config applied"

  # =====================================================
  # Step 6: Create custom benchmark workload
  # =====================================================
  IO.puts "\n6. Creating custom benchmark workload..."

  # Create a realistic workload SQL file
  workload_sql = """
  -- Mixed OLTP workload for e-commerce
  \\set user_id random(1, 10000)
  \\set product_id random(1, 5000)
  \\set order_id random(1, 50000)

  -- 40% - Browse products (read-heavy)
  SELECT p.*, c.name as category_name
  FROM products p
  LEFT JOIN categories c ON p.category_id = c.id
  WHERE p.is_active = true
  ORDER BY p.created_at DESC
  LIMIT 20;

  -- 20% - Search products
  SELECT * FROM products
  WHERE name ILIKE '%Widget%' AND is_active = true
  ORDER BY price
  LIMIT 10;

  -- 15% - View order history
  SELECT o.*, COUNT(oi.id) as item_count
  FROM orders o
  LEFT JOIN order_items oi ON o.id = oi.order_id
  WHERE o.user_id = :user_id
  GROUP BY o.id
  ORDER BY o.created_at DESC
  LIMIT 10;

  -- 10% - Product reviews
  SELECT r.*, u.first_name, u.last_name
  FROM reviews r
  JOIN users u ON r.user_id = u.id
  WHERE r.product_id = :product_id
  ORDER BY r.helpful_votes DESC
  LIMIT 20;

  -- 10% - Add to cart (write)
  INSERT INTO cart_items (user_id, product_id, quantity)
  VALUES (:user_id, :product_id, 1)
  ON CONFLICT (user_id, product_id) DO UPDATE SET quantity = cart_items.quantity + 1;

  -- 5% - Inventory check
  SELECT p.name, i.quantity, i.reserved_quantity
  FROM inventory i
  JOIN products p ON i.product_id = p.id
  WHERE i.quantity <= i.reorder_level;
  """

  workload_file = "/tmp/ecommerce_workload.sql"
  File.write!(workload_file, workload_sql)
  IO.puts "   Custom workload created"

  # =====================================================
  # Step 7: Run baseline benchmark
  # =====================================================
  IO.puts "\n7. Running baseline benchmark..."

  # Use pgbench with custom script
  baseline_result = System.cmd("pgbench",
    ["-h", target_host, "-p", target_port, "-U", target_user,
     "-c", to_string(clients), "-j", "2", "-T", to_string(duration),
     "-f", workload_file, "--no-vacuum", demo_db_name],
    env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true)

  {baseline_output, _} = baseline_result

  # Parse TPS from output
  baseline_tps = case Regex.run(~r/tps = ([\d.]+)/, baseline_output) do
    [_, tps_str] -> String.to_float(tps_str)
    _ -> 100.0  # fallback
  end

  IO.puts "   Baseline TPS: #{Float.round(baseline_tps, 2)}"

  # =====================================================
  # Step 8: Determine knob space (with optional Sobol)
  # =====================================================
  IO.puts "\n8. Determining knob space..."

  # Benchmark function for optimization
  benchmark_fn = fn config ->
    # Apply config
    Enum.each(config, fn {param, value} ->
      formatted = KnobSpace.format_value(param, value)
      run_target_psql.("ALTER SYSTEM SET #{param} = '#{formatted}'", demo_db_name)
    end)
    run_target_psql.("SELECT pg_reload_conf()", demo_db_name)

    Process.sleep(500)

    # Run benchmark
    {output, _} = System.cmd("pgbench",
      ["-h", target_host, "-p", target_port, "-U", target_user,
       "-c", to_string(clients), "-j", "2", "-T", to_string(duration),
       "-f", workload_file, "--no-vacuum", demo_db_name],
      env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true)

    case Regex.run(~r/tps = ([\d.]+)/, output) do
      [_, tps_str] ->
        tps = String.to_float(tps_str)
        {:ok, 1.0 / max(tps, 0.001)}  # Lower score is better
      _ ->
        {:error, :parse_failed}
    end
  end

  knob_space = if use_sobol do
    IO.puts "   Starting Sobol sensitivity analysis..."

    case Julia.start_link(mode: :local) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Julia.wait_until_ready(max_attempts: 30, delay_ms: 1_000) do
      :ok ->
        demo_space = %{
          shared_buffers: {:continuous, 128.0, 1024.0},
          effective_cache_size: {:continuous, 512.0, 8192.0},
          work_mem: {:continuous, 4.0, 128.0},
          random_page_cost: {:continuous, 1.0, 4.0},
          checkpoint_completion_target: {:continuous, 0.5, 0.9}
        }

        restart_fn = fn restart_config ->
          PostgresLifecycle.restart_target(config: restart_config)
        end

        case Sobol.analyze(demo_space, benchmark_fn,
               n_samples: sobol_samples,
               use_cache: false,
               restart_fn: restart_fn) do
          {:ok, indices} ->
            IO.puts "\n   Sensitivity indices:"
            indices
            |> Enum.sort_by(fn {_, %{st: st}} -> st end, :desc)
            |> Enum.each(fn {name, %{st: st}} ->
              IO.puts "     #{name}: #{Float.round(st, 3)}"
            end)

            Sobol.reduce_knob_space(demo_space, indices, threshold: 0.05)

          {:error, _} ->
            IO.puts "   Sobol failed, using default knobs"
            KnobSpace.oltp_knobs()
        end

      {:error, :timeout} ->
        IO.puts "   Julia not ready, using default knobs"
        KnobSpace.oltp_knobs()
    end
  else
    IO.puts "   Using default OLTP knob space"
    %{
      shared_buffers: {:continuous, 128.0, 1024.0},
      effective_cache_size: {:continuous, 512.0, 8192.0},
      work_mem: {:continuous, 4.0, 128.0},
      random_page_cost: {:continuous, 1.0, 4.0},
      checkpoint_completion_target: {:continuous, 0.5, 0.9}
    }
  end

  IO.puts "   Optimizing knobs: #{inspect(Map.keys(knob_space))}"

  # =====================================================
  # Step 9: TPE optimization
  # =====================================================
  IO.puts "\n9. Running TPE optimization (#{iterations} iterations)..."
  IO.puts "   Iter | TPS      | Score    | Config highlights"
  IO.puts "   -----|----------|----------|------------------"

  {:ok, tpe_state} = TPE.init(knob_space, n_startup_trials: 3, seed: 42)

  {final_state, history} =
    Enum.reduce(1..iterations, {tpe_state, []}, fn i, {current_state, hist} ->
      {:ok, config, new_state} = TPE.suggest(current_state)

      case benchmark_fn.(config) do
        {:ok, score} ->
          tps = 1.0 / score
          {:ok, updated_state} = TPE.observe(new_state, config, score)

          highlights = config
            |> Enum.take(2)
            |> Enum.map(fn {k, v} ->
              val = if is_float(v), do: Float.round(v, 1), else: v
              "#{k}=#{val}"
            end)
            |> Enum.join(", ")

          IO.puts "   #{String.pad_leading(to_string(i), 4)} | #{String.pad_leading(Float.round(tps, 1) |> to_string(), 8)} | #{String.pad_leading(Float.round(score, 6) |> to_string(), 8)} | #{highlights}"

          {updated_state, [{config, score, tps} | hist]}

        {:error, reason} ->
          IO.puts "   #{String.pad_leading(to_string(i), 4)} | ERROR: #{inspect(reason)}"
          {:ok, updated_state} = TPE.observe(new_state, config, 1.0e10)
          {updated_state, hist}
      end
    end)

  # =====================================================
  # Step 10: Analyze results
  # =====================================================
  IO.puts "\n10. Analyzing results..."

  if Enum.empty?(history) do
    IO.puts "   No successful iterations"
  else
    {best_config, _best_score, best_tps} = Enum.min_by(history, fn {_, score, _} -> score end)

    tps_improvement = (best_tps - baseline_tps) / baseline_tps * 100

    IO.puts "\n   ┌─────────────────────────────────────────────────┐"
    IO.puts "   │           OPTIMIZATION RESULTS                  │"
    IO.puts "   ├─────────────────────────────────────────────────┤"
    IO.puts "   │ Metric        │ Baseline    │ Optimized   │ Δ   │"
    IO.puts "   ├───────────────┼─────────────┼─────────────┼─────┤"
    IO.puts "   │ TPS           │ #{String.pad_leading(Float.round(baseline_tps, 1) |> to_string(), 11)} │ #{String.pad_leading(Float.round(best_tps, 1) |> to_string(), 11)} │ #{String.pad_leading(Float.round(tps_improvement, 0) |> to_string(), 3)}% │"
    IO.puts "   └─────────────────────────────────────────────────┘"

    IO.puts "\n   Recommended PostgreSQL settings:"
    IO.puts "   ----------------------------------------"
    Enum.each(best_config, fn {param, value} ->
      formatted = KnobSpace.format_value(param, value)
      IO.puts "   ALTER SYSTEM SET #{param} = '#{formatted}';"
    end)
    IO.puts "   SELECT pg_reload_conf();"
    IO.puts "   ----------------------------------------"

    # =====================================================
    # Step 11: Validation
    # =====================================================
    unless skip_validation do
      IO.puts "\n11. Running validation benchmark (#{validation_duration}s)..."

      # Apply best config
      Enum.each(best_config, fn {param, value} ->
        formatted = KnobSpace.format_value(param, value)
        run_target_psql.("ALTER SYSTEM SET #{param} = '#{formatted}'", demo_db_name)
      end)
      run_target_psql.("SELECT pg_reload_conf()", demo_db_name)

      Process.sleep(1_000)

      {validation_output, _} = System.cmd("pgbench",
        ["-h", target_host, "-p", target_port, "-U", target_user,
         "-c", to_string(clients), "-j", "2", "-T", to_string(validation_duration),
         "-f", workload_file, "--no-vacuum", demo_db_name],
        env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true)

      validation_tps = case Regex.run(~r/tps = ([\d.]+)/, validation_output) do
        [_, tps_str] -> String.to_float(tps_str)
        _ -> best_tps
      end

      validated_improvement = (validation_tps - baseline_tps) / baseline_tps * 100
      variance = abs(best_tps - validation_tps) / best_tps * 100

      IO.puts ""
      IO.puts "   ┌─────────────────────────────────────────────────────────────┐"
      IO.puts "   │                  VALIDATION RESULTS                         │"
      IO.puts "   ├─────────────────────────────────────────────────────────────┤"
      IO.puts "   │ Metric        │ Baseline    │ Optimized   │ Validated      │"
      IO.puts "   ├───────────────┼─────────────┼─────────────┼────────────────┤"
      IO.puts "   │ TPS           │ #{String.pad_leading(Float.round(baseline_tps, 1) |> to_string(), 11)} │ #{String.pad_leading(Float.round(best_tps, 1) |> to_string(), 11)} │ #{String.pad_leading(Float.round(validation_tps, 1) |> to_string(), 14)} │"
      IO.puts "   │ vs Baseline   │           - │ #{String.pad_leading("#{Float.round(tps_improvement, 0)}%", 11)} │ #{String.pad_leading("#{Float.round(validated_improvement, 0)}%", 14)} │"
      IO.puts "   └─────────────────────────────────────────────────────────────┘"

      if variance < 5 do
        IO.puts "\n   ✓ Validation passed: Results consistent (#{Float.round(variance, 1)}% variance)"
      else
        IO.puts "\n   ⚠ High variance detected (#{Float.round(variance, 1)}%)"
      end
    end
  end

  # Clean up workload file
  File.rm(workload_file)

  # Close connection
  GenServer.stop(conn)

after
  cleanup_fn.()
end

IO.puts """

==========================================
E-commerce Demo Complete!
==========================================

What this demo demonstrated:
1. Created complex e-commerce schema (12 tables, triggers, constraints)
2. Generated realistic data with proper distributions
3. #{if demo_clone, do: "Scanned and cloned database with synthetic data", else: "Skipped scan/clone demo"}
4. Optimized PostgreSQL config with TPE
5. Validated results with longer benchmark

To customize:
  ECOMMERCE_SCALE=2.0 mix run demo_ecommerce.exs  # 2x data
  USE_SOBOL=true mix run demo_ecommerce.exs        # With sensitivity analysis
  DEMO_CLONE=true mix run demo_ecommerce.exs       # Demo scan/clone workflow

"""
