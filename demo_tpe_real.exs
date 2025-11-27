#!/usr/bin/env elixir

# TPE Real Database Demo - Two-Database Architecture
# Run with: nix develop -c mix run demo_tpe_real.exs
#
# =====================================================
# TWO-DATABASE ARCHITECTURE
# =====================================================
# App DB (port 5432): For application state (Repo) - NEVER restarted
# Target DB (port 5433): For tuning benchmarks - MAY be restarted
# =====================================================
#
# This demo:
# 1. Starts both PostgreSQL instances (App DB + Target DB)
# 2. Creates demo database on TARGET DB (port 5433)
# 3. Runs Julia Sobol sensitivity analysis (restarts Target DB as needed)
# 4. Optimizes using TPE against real benchmarks
# 5. Shows improvement over baseline
# 6. Cleans up Target DB (App DB untouched)
#
# Environment variables:
#   PGBENCH_DURATION - Benchmark duration in seconds (default: 10)
#   PGBENCH_CLIENTS - Number of clients (default: 4)
#   PGBENCH_SCALE - Scale factor (default: 10)
#   TPE_ITERATIONS - Number of optimization iterations (default: 10)
#   USE_SOBOL - Run Sobol sensitivity analysis (default: true)
#   SOBOL_SAMPLES - Number of Sobol samples (default: 32)
#   CLEANUP - Drop demo database after demo (default: true)
#   STOP_TARGET - Stop Target DB after demo (default: false)

IO.puts """
==========================================
PgGaConf Demo - TPE with Real PostgreSQL
==========================================

Two-Database Architecture:
  App DB (port 5432):    Application state - never restarted
  Target DB (port 5433): Tuning benchmarks - may restart for shared_buffers etc.

This demo will:
1. Start both databases
2. Create demo database on Target DB
3. Apply conservative baseline config
4. Run Sobol sensitivity analysis (restarts Target DB as needed)
5. Optimize using TPE
6. Show improvement over baseline
7. Clean up Target DB

"""

# Configuration from environment
duration = String.to_integer(System.get_env("PGBENCH_DURATION", "10"))
clients = String.to_integer(System.get_env("PGBENCH_CLIENTS", "4"))
scale = String.to_integer(System.get_env("PGBENCH_SCALE", "10"))
iterations = String.to_integer(System.get_env("TPE_ITERATIONS", "10"))
use_sobol = System.get_env("USE_SOBOL", "true") == "true"
sobol_samples = String.to_integer(System.get_env("SOBOL_SAMPLES", "32"))
cleanup = System.get_env("CLEANUP", "true") == "true"
stop_target = System.get_env("STOP_TARGET", "false") == "true"

# Target database config
target_host = "localhost"
target_port = "5433"
target_user = "postgres"
target_password = ""
demo_db_name = "tpe_demo"

IO.puts "Configuration:"
IO.puts "  App DB: localhost:5432 (for application state)"
IO.puts "  Target DB: #{target_host}:#{target_port} (for benchmarks)"
IO.puts "  Demo database: #{demo_db_name}"
IO.puts "  pgbench: #{duration}s, #{clients} clients, scale #{scale}"
IO.puts "  TPE iterations: #{iterations}"
IO.puts "  Use Sobol: #{use_sobol}"
if use_sobol, do: IO.puts "  Sobol samples: #{sobol_samples}"
IO.puts "  Cleanup after demo: #{cleanup}"
IO.puts ""

# =====================================================
# Step 0: Start both PostgreSQL instances
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
  else
    IO.puts "   WARNING: PGDATA_APP not set, cannot start App DB"
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
    IO.puts "   WARNING: PGDATA_TARGET not set, cannot start Target DB"
    IO.puts "   Make sure you're in 'nix develop' and have run the shell once to initialize."
    System.halt(1)
  end
else
  IO.puts "   Target DB (port 5433) already running"
end

# =====================================================
# Now start the application (Repo connects to App DB)
# =====================================================
{:ok, _} = Application.ensure_all_started(:pg_ga_conf)

# Initialize Python with Optuna
IO.puts "\n1. Initializing Python/Optuna via uv..."
Pythonx.uv_init("""
[project]
name = "pg_ga_conf"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = ["optuna>=3.5.0"]
""")
IO.puts "   Python initialized with Optuna"

alias PgGaConf.{Benchmark, KnobSpace, Sobol, Julia, PostgresLifecycle}
alias PgGaConf.Optimizer.TPE

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
    # Terminate connections first
    run_target_psql.("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '#{demo_db_name}'", "postgres")
    System.cmd("dropdb", ["-h", target_host, "-p", target_port, "-U", target_user, "--if-exists", demo_db_name],
      env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true)

    if stop_target do
      IO.puts "   Stopping Target DB..."
      PostgresLifecycle.stop_target()
    end

    IO.puts "   Cleanup complete!"
  else
    IO.puts "   Skipping cleanup (CLEANUP=false)"
    IO.puts "   Demo database '#{demo_db_name}' preserved."
    IO.puts "   Connect with: psql -h #{target_host} -p #{target_port} -U #{target_user} -d #{demo_db_name}"
  end
end

try do
  # =====================================================
  # Step 2: Create demo database on Target DB
  # =====================================================
  IO.puts "\n2. Setting up demo database on Target DB..."

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

  # Initialize pgbench
  IO.puts "   Initializing pgbench tables (scale=#{scale})..."
  case System.cmd("pgbench",
         ["-i", "-s", to_string(scale), "-h", target_host, "-p", target_port, "-U", target_user, demo_db_name],
         env: [{"PGPASSWORD", target_password}], stderr_to_stdout: true) do
    {_, 0} -> IO.puts "   pgbench initialized with #{scale * 100_000} accounts"
    {output, code} ->
      IO.puts "   ERROR initializing pgbench (#{code}): #{output}"
      System.halt(1)
  end

  # Apply baseline config
  IO.puts "   Applying conservative baseline config..."
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
  # Step 3: Initialize benchmark
  # =====================================================
  IO.puts "\n3. Initializing benchmark (pgbench)..."

  db_url = "postgres://#{target_user}:#{target_password}@#{target_host}:#{target_port}/#{demo_db_name}"

  benchmark_opts = [
    db_url: db_url,
    duration: duration,
    clients: clients,
    scale: scale
  ]

  {:ok, bench_state} = Benchmark.Pgbench.init(benchmark_opts)
  IO.puts "   pgbench initialized"

  # =====================================================
  # Step 4: Run baseline benchmark
  # =====================================================
  IO.puts "\n4. Running baseline benchmark (with conservative config)..."

  {:ok, baseline_score, baseline_metrics} = Benchmark.Pgbench.run(bench_state)
  IO.puts "   Baseline TPS: #{Float.round(baseline_metrics.tps, 2)}"
  IO.puts "   Baseline latency: #{Float.round(baseline_metrics.latency_avg, 2)}ms"
  IO.puts "   Baseline score: #{Float.round(baseline_score, 6)} (lower is better)"
  IO.puts ""
  IO.puts "   Current config (intentionally suboptimal):"
  IO.puts "   - shared_buffers: 128MB"
  IO.puts "   - effective_cache_size: 512MB"
  IO.puts "   - work_mem: 4MB"
  IO.puts "   - random_page_cost: 4.0"

  # =====================================================
  # Step 5: Determine knob space
  # =====================================================
  IO.puts "\n5. Determining knob space..."

  knob_space = if use_sobol do
    IO.puts "   Starting Julia for Sobol sensitivity analysis..."

    # Start Julia client (may already be running)
    case Julia.start_link(mode: :local) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Wait for Julia to be ready
    IO.puts "   Waiting for Julia to initialize (may take up to 30s)..."

    case Julia.wait_until_ready(max_attempts: 30, delay_ms: 1_000) do
      :ok ->
        IO.puts "   Julia is ready"

        # Define demo knob space for Sobol analysis
        demo_space = %{
          shared_buffers: {:continuous, 128.0, 1024.0},
          effective_cache_size: {:continuous, 512.0, 8192.0},
          work_mem: {:continuous, 4.0, 128.0},
          random_page_cost: {:continuous, 1.0, 4.0},
          checkpoint_completion_target: {:continuous, 0.5, 0.9}
        }

        IO.puts "   Running Sobol analysis on #{map_size(demo_space)} knobs..."
        IO.puts "   (This will run #{sobol_samples * (map_size(demo_space) + 2)} benchmark evaluations)"
        IO.puts "   (Restarts TARGET DB only - App DB stays connected)"

        # Create benchmark function for Sobol
        benchmark_fn = fn config ->
          :ok = Benchmark.Pgbench.apply_config(bench_state, config)
          Process.sleep(500)
          case Benchmark.Pgbench.run(bench_state) do
            {:ok, score, _metrics} -> {:ok, score}
            {:error, reason} -> {:error, reason}
          end
        end

        # Create restart function - uses PostgresLifecycle to restart TARGET DB only
        restart_fn = fn restart_config ->
          case PostgresLifecycle.restart_target(config: restart_config) do
            :ok -> :ok
            {:error, reason} ->
              IO.puts "   WARNING: Target DB restart issue: #{inspect(reason)}"
          end
        end

        # Progress callback
        on_batch_start = fn batch_idx, total_batches, restart_values ->
          IO.puts "   Batch #{batch_idx}/#{total_batches}: shared_buffers=#{restart_values[:shared_buffers]}MB"
        end

        case Sobol.analyze(demo_space, benchmark_fn,
               n_samples: sobol_samples,
               use_cache: false,
               restart_fn: restart_fn,
               on_batch_start: on_batch_start) do
          {:ok, indices} ->
            IO.puts "   Sobol analysis complete!"
            IO.puts "\n   Sensitivity indices (higher = more important):"

            indices
            |> Enum.sort_by(fn {_, %{st: st}} -> st end, :desc)
            |> Enum.each(fn {name, %{s1: s1, st: st}} ->
              clamped_st = max(0.0, min(1.0, st))
              bar_len = round(clamped_st * 40)
              bar = String.duplicate("█", bar_len) <> String.duplicate("░", 40 - bar_len)
              IO.puts "   #{String.pad_trailing(to_string(name), 30)} S1=#{Float.round(s1, 3)} ST=#{Float.round(st, 3)} #{bar}"
            end)

            important = Sobol.filter_important(indices, threshold: 0.05)
            IO.puts "\n   Important knobs (ST > 0.05): #{inspect(important)}"

            Sobol.reduce_knob_space(demo_space, indices, threshold: 0.05)

          {:error, reason} ->
            IO.puts "   Sobol analysis failed: #{inspect(reason)}"
            IO.puts "   Falling back to default knob space..."
            KnobSpace.oltp_knobs()
        end

      {:error, :timeout} ->
        IO.puts "   Julia failed to start after 30 seconds, using default knob space..."
        KnobSpace.oltp_knobs()
    end
  else
    IO.puts "   Using default OLTP knob space (Sobol disabled)"
    KnobSpace.oltp_knobs()
  end

  # =====================================================
  # Step 6: Initialize TPE optimizer
  # =====================================================
  IO.puts "\n6. Initializing TPE optimizer..."
  IO.puts "   Knobs to optimize: #{inspect(Map.keys(knob_space))}"

  {:ok, tpe_state} = TPE.init(knob_space, n_startup_trials: 3, seed: 42)
  IO.puts "   TPE initialized with n_startup_trials=3"

  # =====================================================
  # Step 7: Run optimization loop
  # =====================================================
  IO.puts "\n7. Running optimization loop (#{iterations} iterations)..."
  IO.puts "   (Each iteration runs pgbench for #{duration}s)"
  IO.puts ""
  IO.puts "   Iter | TPS      | Score    | Config highlights"
  IO.puts "   -----|----------|----------|------------------"

  {final_state, history} =
    Enum.reduce(1..iterations, {tpe_state, []}, fn i, {current_state, hist} ->
      {:ok, config, new_state} = TPE.suggest(current_state)

      :ok = Benchmark.Pgbench.apply_config(bench_state, config)
      Process.sleep(1_000)

      case Benchmark.Pgbench.run(bench_state) do
        {:ok, score, metrics} ->
          {:ok, updated_state} = TPE.observe(new_state, config, score)

          highlights = config
            |> Enum.take(3)
            |> Enum.map(fn {k, v} ->
              val = if is_float(v), do: Float.round(v, 1), else: v
              "#{k}=#{val}"
            end)
            |> Enum.join(", ")

          IO.puts "   #{String.pad_leading(to_string(i), 4)} | #{String.pad_leading(Float.round(metrics.tps, 1) |> to_string(), 8)} | #{String.pad_leading(Float.round(score, 6) |> to_string(), 8)} | #{highlights}"

          {updated_state, [{config, score, metrics} | hist]}

        {:error, reason} ->
          IO.puts "   #{String.pad_leading(to_string(i), 4)} | ERROR: #{inspect(reason)}"
          {:ok, updated_state} = TPE.observe(new_state, config, 1.0e10)
          {updated_state, hist}
      end
    end)

  # =====================================================
  # Step 8: Analyze results
  # =====================================================
  IO.puts "\n8. Analyzing results..."

  if Enum.empty?(history) do
    IO.puts "   No successful iterations"
  else
    {best_config, _best_score, best_metrics} = Enum.min_by(history, fn {_, score, _} -> score end)

    tps_improvement = (best_metrics.tps - baseline_metrics.tps) / baseline_metrics.tps * 100

    IO.puts "\n   ┌─────────────────────────────────────────────────┐"
    IO.puts "   │           OPTIMIZATION RESULTS                  │"
    IO.puts "   ├─────────────────────────────────────────────────┤"
    IO.puts "   │ Metric        │ Baseline    │ Optimized   │ Δ   │"
    IO.puts "   ├───────────────┼─────────────┼─────────────┼─────┤"
    IO.puts "   │ TPS           │ #{String.pad_leading(Float.round(baseline_metrics.tps, 1) |> to_string(), 11)} │ #{String.pad_leading(Float.round(best_metrics.tps, 1) |> to_string(), 11)} │ #{String.pad_leading(Float.round(tps_improvement, 0) |> to_string(), 3)}% │"
    IO.puts "   │ Latency (ms)  │ #{String.pad_leading(Float.round(baseline_metrics.latency_avg, 1) |> to_string(), 11)} │ #{String.pad_leading(Float.round(best_metrics.latency_avg, 1) |> to_string(), 11)} │     │"
    IO.puts "   └─────────────────────────────────────────────────┘"

    IO.puts "\n   Recommended PostgreSQL settings:"
    IO.puts "   ----------------------------------------"
    Enum.each(best_config, fn {param, value} ->
      formatted = KnobSpace.format_value(param, value)
      IO.puts "   ALTER SYSTEM SET #{param} = '#{formatted}';"
    end)
    IO.puts "   SELECT pg_reload_conf();"
    IO.puts "   ----------------------------------------"
  end

  # =====================================================
  # Step 9: Demonstrate serialization
  # =====================================================
  IO.puts "\n9. Demonstrating serialization (crash recovery)..."
  serialized = TPE.serialize(final_state)
  IO.puts "   Serialized optimizer state: #{byte_size(serialized)} bytes"
  {:ok, _recovered} = TPE.deserialize(serialized)
  IO.puts "   Successfully deserialized - can resume optimization!"

  # Cleanup
  Benchmark.Pgbench.cleanup(bench_state)

after
  # Run cleanup
  cleanup_fn.()
end

IO.puts """

==========================================
TPE Real Database Demo Complete!
==========================================

What this demo demonstrated:
1. Two-database architecture (App DB + Target DB)
2. App DB (port 5432) stayed connected throughout
3. Target DB (port 5433) was restarted for Sobol batches
4. TPE optimization with real PostgreSQL config changes
5. Measurable TPS improvement over baseline

To run with different settings:
  TPE_ITERATIONS=20 PGBENCH_DURATION=30 mix run demo_tpe_real.exs

To skip Sobol (faster):
  USE_SOBOL=false mix run demo_tpe_real.exs

To preserve database after demo:
  CLEANUP=false mix run demo_tpe_real.exs
"""
