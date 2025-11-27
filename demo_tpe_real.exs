#!/usr/bin/env elixir

# TPE Real Database Demo - Self-Contained
# Run with: nix develop -c mix run demo_tpe_real.exs
#
# This demo is FULLY SELF-CONTAINED and will:
# 1. Start PostgreSQL if not running (uses PGDATA from nix develop)
# 2. Create a demo PostgreSQL database
# 3. Populate it with pgbench tables and sample data
# 4. Apply a conservative baseline config
# 5. Run Julia Sobol sensitivity analysis (with batched restarts)
# 6. Optimize using TPE against real benchmarks
# 7. Clean up on exit (database drop, config reset)
#
# Environment variables:
#   PGHOST - PostgreSQL host (default: localhost)
#   PGPORT - PostgreSQL port (default: 5432)
#   PGUSER - PostgreSQL user (default: postgres)
#   PGPASSWORD - PostgreSQL password (default: postgres)
#   DEMO_DB_NAME - Demo database name (default: pg_ga_conf_demo)
#   PGBENCH_DURATION - Benchmark duration in seconds (default: 10)
#   PGBENCH_CLIENTS - Number of clients (default: 4)
#   PGBENCH_SCALE - Scale factor (default: 10)
#   TPE_ITERATIONS - Number of optimization iterations (default: 10)
#   USE_SOBOL - Run Sobol sensitivity analysis (default: true)
#   SOBOL_SAMPLES - Number of Sobol samples (default: 32)
#   SKIP_SETUP - Skip database setup if already exists (default: false)
#   CLEANUP - Drop demo database after demo (default: true - self-contained!)
#   STOP_POSTGRES - Stop PostgreSQL after demo (default: false)

IO.puts """
==========================================
PgGaConf Demo - TPE with Real PostgreSQL
==========================================

This demo is SELF-CONTAINED - it will:
1. Start PostgreSQL (if not running)
2. Create demo database with pgbench + sample data
3. Apply conservative baseline PostgreSQL config
4. Run Julia Sobol sensitivity analysis to find important knobs
5. Optimize using TPE (Tree-structured Parzen Estimator)
6. Show improvement over baseline
7. Clean up (drop database, reset config)

"""

# Parse environment
pg_host = System.get_env("PGHOST", "localhost")
pg_port = System.get_env("PGPORT", "5432")
pg_user = System.get_env("PGUSER", "postgres")
pg_password = System.get_env("PGPASSWORD", "postgres")
demo_db_name = System.get_env("DEMO_DB_NAME", "pg_ga_conf_demo")

base_url = "postgres://#{pg_user}:#{pg_password}@#{pg_host}:#{pg_port}/postgres"

duration = String.to_integer(System.get_env("PGBENCH_DURATION", "10"))
clients = String.to_integer(System.get_env("PGBENCH_CLIENTS", "4"))
scale = String.to_integer(System.get_env("PGBENCH_SCALE", "10"))
iterations = String.to_integer(System.get_env("TPE_ITERATIONS", "10"))
use_sobol = System.get_env("USE_SOBOL", "true") == "true"
sobol_samples = String.to_integer(System.get_env("SOBOL_SAMPLES", "32"))
skip_setup = System.get_env("SKIP_SETUP", "false") == "true"
# Default to cleanup=true for self-contained behavior
cleanup = System.get_env("CLEANUP", "true") == "true"
stop_postgres = System.get_env("STOP_POSTGRES", "false") == "true"

IO.puts "Configuration:"
IO.puts "  PostgreSQL: #{pg_host}:#{pg_port}"
IO.puts "  Demo database: #{demo_db_name}"
IO.puts "  pgbench duration: #{duration}s"
IO.puts "  pgbench clients: #{clients}"
IO.puts "  pgbench scale: #{scale}"
IO.puts "  TPE iterations: #{iterations}"
IO.puts "  Use Sobol: #{use_sobol}"
if use_sobol, do: IO.puts "  Sobol samples: #{sobol_samples}"
IO.puts "  Cleanup after demo: #{cleanup}"
IO.puts ""

# Start the application
{:ok, _} = Application.ensure_all_started(:pg_ga_conf)

# Initialize Python with Optuna
IO.puts "0. Initializing Python/Optuna via uv..."
Pythonx.uv_init("""
[project]
name = "pg_ga_conf"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = ["optuna>=3.5.0"]
""")
IO.puts "   Python initialized with Optuna"

alias PgGaConf.{Benchmark, KnobSpace, Sobol, Julia}
alias PgGaConf.Demo.Setup
alias PgGaConf.Optimizer.TPE

# Register cleanup handler for graceful shutdown
cleanup_fn = fn ->
  IO.puts "\n\n=== Cleanup ==="
  if cleanup do
    Setup.full_teardown(
      db_url: base_url,
      db_name: demo_db_name,
      stop_postgres: stop_postgres,
      reset_config: true
    )
  else
    IO.puts "  Skipping cleanup (CLEANUP=false)"
    IO.puts "  Demo database '#{demo_db_name}' preserved for inspection."
    IO.puts "  To connect: psql -h #{pg_host} -U #{pg_user} -d #{demo_db_name}"
  end
end

# Register the cleanup function to run on exit
# This ensures cleanup happens even if the script is interrupted
Process.flag(:trap_exit, true)

# Step 1: Set up demo database (self-contained - starts PostgreSQL if needed)
IO.puts "\n1. Setting up demo database..."

db_url = if skip_setup do
  IO.puts "   Skipping setup (SKIP_SETUP=true)"
  # Still ensure PostgreSQL is running
  case Setup.ensure_postgres_running() do
    :ok -> :ok
    {:error, reason} ->
      IO.puts "   ERROR: PostgreSQL not running: #{inspect(reason)}"
      System.halt(1)
  end
  "postgres://#{pg_user}:#{pg_password}@#{pg_host}:#{pg_port}/#{demo_db_name}"
else
  case Setup.full_setup(
    db_url: base_url,
    db_name: demo_db_name,
    scale: scale,
    drop_existing: true,
    start_postgres: true
  ) do
    {:ok, url} ->
      IO.puts "   Database setup complete!"
      url

    {:error, reason} ->
      IO.puts "   ERROR: Setup failed: #{inspect(reason)}"
      IO.puts "\n   Make sure you are in nix develop environment"
      IO.puts "   (PGDATA should be set)"
      System.halt(1)
  end
end

IO.puts "\n2. Initializing benchmark (pgbench)..."

# Initialize pgbench
benchmark_opts = [
  db_url: db_url,
  duration: duration,
  clients: clients,
  scale: scale
]

try do
  case Benchmark.Pgbench.init(benchmark_opts) do
    {:ok, bench_state} ->
      IO.puts "   pgbench initialized"

      # Run baseline benchmark
      IO.puts "\n3. Running baseline benchmark (with conservative config)..."
      case Benchmark.Pgbench.run(bench_state) do
        {:ok, baseline_score, baseline_metrics} ->
          IO.puts "   Baseline TPS: #{Float.round(baseline_metrics.tps, 2)}"
          IO.puts "   Baseline latency: #{Float.round(baseline_metrics.latency_avg, 2)}ms"
          IO.puts "   Baseline score: #{Float.round(baseline_score, 6)} (lower is better)"
          IO.puts ""
          IO.puts "   Current config (intentionally suboptimal):"
          IO.puts "   - shared_buffers: 128MB"
          IO.puts "   - effective_cache_size: 512MB"
          IO.puts "   - work_mem: 4MB"
          IO.puts "   - random_page_cost: 4.0"
          IO.puts "   - max_parallel_workers_per_gather: 0"

          # Get knob space
          IO.puts "\n4. Determining knob space..."

          knob_space = if use_sobol do
            IO.puts "   Starting Julia for Sobol sensitivity analysis..."

            # Start Julia client (may already be running)
            case Julia.start_link(mode: :local) do
              {:ok, _} -> :ok
              {:error, {:already_started, _}} -> :ok
            end

            # Wait for Julia to be ready with proper health check
            IO.puts "   Waiting for Julia to initialize (may take up to 30s)..."

            case Julia.wait_until_ready(max_attempts: 30, delay_ms: 1_000) do
              :ok ->
                IO.puts "   Julia is ready"

                # Define demo knob space for Sobol analysis
                # Now includes shared_buffers (restart-required) thanks to batched evaluation!
                # Excludes effective_io_concurrency (must be 0 on macOS)
                demo_space = %{
                  shared_buffers: {:continuous, 128.0, 1024.0},
                  effective_cache_size: {:continuous, 512.0, 8192.0},
                  work_mem: {:continuous, 4.0, 128.0},
                  random_page_cost: {:continuous, 1.0, 4.0},
                  checkpoint_completion_target: {:continuous, 0.5, 0.9}
                }

                IO.puts "   Running Sobol analysis on #{map_size(demo_space)} knobs..."
                IO.puts "   (This will run #{sobol_samples * (map_size(demo_space) + 2)} benchmark evaluations)"
                IO.puts "   (Using batched evaluation to minimize PostgreSQL restarts)"

                # Create benchmark function for Sobol
                benchmark_fn = fn config ->
                  :ok = Benchmark.Pgbench.apply_config(bench_state, config)
                  Process.sleep(500)
                  case Benchmark.Pgbench.run(bench_state) do
                    {:ok, score, _metrics} -> {:ok, score}
                    {:error, reason} -> {:error, reason}
                  end
                end

                # Create restart function for batched evaluation
                restart_fn = fn restart_config ->
                  # Apply restart-required params via ALTER SYSTEM
                  Enum.each(restart_config, fn {param, value} ->
                    formatted_value = KnobSpace.format_value(param, value)
                    sql = "ALTER SYSTEM SET #{param} = '#{formatted_value}'"
                    System.cmd("psql", ["-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", demo_db_name, "-c", sql],
                      env: [{"PGPASSWORD", pg_password}], stderr_to_stdout: true)
                  end)

                  # Restart PostgreSQL
                  pgdata = System.get_env("PGDATA")
                  if pgdata && File.dir?(pgdata) do
                    System.cmd("pg_ctl", ["restart", "-D", pgdata, "-w", "-t", "30"], stderr_to_stdout: true)
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
                      # Clamp values to [0, 1] for display (negative values can occur with high variance)
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

          IO.puts "\n5. Initializing TPE optimizer..."
          IO.puts "   Knobs to optimize: #{inspect(Map.keys(knob_space))}"

          {:ok, tpe_state} = TPE.init(knob_space, n_startup_trials: 3, seed: 42)
          IO.puts "   TPE initialized with n_startup_trials=3"

          IO.puts "\n6. Running optimization loop (#{iterations} iterations)..."
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

          IO.puts "\n7. Analyzing results..."

          if Enum.empty?(history) do
            IO.puts "   No successful iterations"
          else
            {best_config, best_score, best_metrics} = Enum.min_by(history, fn {_, score, _} -> score end)

            improvement = (baseline_score - best_score) / baseline_score * 100
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

          IO.puts "\n8. Demonstrating serialization (crash recovery)..."
          serialized = TPE.serialize(final_state)
          IO.puts "   Serialized optimizer state: #{byte_size(serialized)} bytes"
          {:ok, _recovered} = TPE.deserialize(serialized)
          IO.puts "   Successfully deserialized - can resume optimization!"

          # Cleanup
          Benchmark.Pgbench.cleanup(bench_state)

        {:error, reason} ->
          IO.puts "   Baseline benchmark failed: #{inspect(reason)}"
      end

    {:error, reason} ->
      IO.puts "   Failed to initialize pgbench: #{inspect(reason)}"
  end
after
  # Run cleanup using the registered cleanup function
  cleanup_fn.()
end

IO.puts """

==========================================
TPE Real Database Demo Complete!
==========================================

What this demo demonstrated:
1. Self-contained setup (PostgreSQL started automatically)
2. Demo database with pgbench + sample tables
3. Conservative baseline config for clear optimization potential
4. Julia-based Sobol sensitivity analysis with batched restarts
5. TPE optimization with real PostgreSQL config changes
6. Measurable TPS improvement over baseline
7. Automatic cleanup (database drop, config reset)

To run with different settings:
  TPE_ITERATIONS=20 PGBENCH_DURATION=30 mix run demo_tpe_real.exs

To preserve database after demo (no cleanup):
  CLEANUP=false mix run demo_tpe_real.exs

To also stop PostgreSQL after demo:
  STOP_POSTGRES=true mix run demo_tpe_real.exs

To skip setup (reuse existing db):
  SKIP_SETUP=true CLEANUP=false mix run demo_tpe_real.exs
"""
