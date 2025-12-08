#!/usr/bin/env elixir

# CMA-ES Real Database Demo
# Run with: nix develop -c mix run demo_cma_es_real.exs
#
# This demo automatically:
# 1. Creates a demo PostgreSQL database
# 2. Populates it with pgbench tables and sample data
# 3. Applies a conservative baseline config
# 4. Runs Julia Sobol sensitivity analysis
# 5. Optimizes using CMA-ES (learns parameter correlations)
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
#   CMAES_ITERATIONS - Number of optimization iterations (default: 15)
#   USE_SOBOL - Run Sobol sensitivity analysis (default: true)
#   SOBOL_SAMPLES - Number of Sobol samples (default: 32)
#   SKIP_SETUP - Skip database setup if already exists (default: false)
#   CLEANUP - Drop demo database after demo (default: false)

IO.puts """
==========================================
PgGaConf Demo - CMA-ES with Real PostgreSQL
==========================================

This demo:
1. Sets up a demo database with pgbench + sample data
2. Applies conservative baseline PostgreSQL config
3. Runs Julia Sobol sensitivity analysis to find important knobs
4. Optimizes using CMA-ES (learns parameter correlations)
5. Shows improvement over baseline

CMA-ES is particularly effective for PostgreSQL because many
configuration parameters are correlated:
- shared_buffers <-> effective_cache_size
- work_mem <-> max_parallel_workers_per_gather
- checkpoint_completion_target <-> max_wal_size

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
iterations = String.to_integer(System.get_env("CMAES_ITERATIONS", "15"))
use_sobol = System.get_env("USE_SOBOL", "true") == "true"
sobol_samples = String.to_integer(System.get_env("SOBOL_SAMPLES", "32"))
skip_setup = System.get_env("SKIP_SETUP", "false") == "true"
cleanup = System.get_env("CLEANUP", "false") == "true"

IO.puts "Configuration:"
IO.puts "  PostgreSQL: #{pg_host}:#{pg_port}"
IO.puts "  Demo database: #{demo_db_name}"
IO.puts "  pgbench duration: #{duration}s"
IO.puts "  pgbench clients: #{clients}"
IO.puts "  pgbench scale: #{scale}"
IO.puts "  CMA-ES iterations: #{iterations}"
IO.puts "  Use Sobol: #{use_sobol}"
if use_sobol, do: IO.puts "  Sobol samples: #{sobol_samples}"
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
alias PgGaConf.Optimizer.CmaEs

# Step 1: Set up demo database
IO.puts "\n1. Setting up demo database..."

db_url = if skip_setup do
  IO.puts "   Skipping setup (SKIP_SETUP=true)"
  "postgres://#{pg_user}:#{pg_password}@#{pg_host}:#{pg_port}/#{demo_db_name}"
else
  case Setup.setup(
    db_url: base_url,
    db_name: demo_db_name,
    scale: scale,
    drop_existing: true
  ) do
    {:ok, url} ->
      IO.puts "   Database setup complete!"
      url

    {:error, reason} ->
      IO.puts "   ERROR: Setup failed: #{inspect(reason)}"
      IO.puts "\n   Make sure PostgreSQL is running:"
      IO.puts "   - nix develop -c pg_start"
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

                # CMA-ES excels with correlated parameters
                # Note: Excludes restart-required params (shared_buffers, max_parallel_workers_per_gather)
                # since each Sobol sample would require a PostgreSQL restart.
                # Also excludes effective_io_concurrency (must be 0 on macOS)
                demo_space = %{
                  # Memory parameters (correlated)
                  effective_cache_size: {:continuous, 512.0, 8192.0},
                  work_mem: {:continuous, 4.0, 128.0},

                  # Checkpoint parameters
                  checkpoint_completion_target: {:continuous, 0.5, 0.9},

                  # I/O cost model
                  random_page_cost: {:continuous, 1.0, 4.0}
                }

                IO.puts "   Running Sobol analysis on #{map_size(demo_space)} knobs..."
                IO.puts "   (This will run #{sobol_samples * (map_size(demo_space) + 2)} benchmark evaluations)"

                # Create benchmark function for Sobol
                benchmark_fn = fn config ->
                  :ok = Benchmark.Pgbench.apply_config(bench_state, config)
                  Process.sleep(500)
                  case Benchmark.Pgbench.run(bench_state) do
                    {:ok, score, _metrics} -> {:ok, score}
                    {:error, reason} -> {:error, reason}
                  end
                end

                case Sobol.analyze(demo_space, benchmark_fn, n_samples: sobol_samples, use_cache: false) do
                  {:ok, indices} ->
                    IO.puts "   Sobol analysis complete!"
                    IO.puts "\n   Sensitivity indices (higher = more important):"

                    indices
                    |> Enum.sort_by(fn {_, %{st: st}} -> st end, :desc)
                    |> Enum.each(fn {name, %{s1: s1, st: st}} ->
                      # Large gap between ST and S1 indicates interactions
                      interaction = st - s1
                      # Clamp values to [0, 1] for display (negative values can occur with high variance)
                      clamped_st = max(0.0, min(1.0, st))
                      bar_len = round(clamped_st * 40)
                      bar = String.duplicate("█", bar_len) <> String.duplicate("░", 40 - bar_len)
                      interaction_note = if interaction > 0.1, do: " (interactions!)", else: ""
                      IO.puts "   #{String.pad_trailing(to_string(name), 30)} ST=#{Float.round(st, 3)}#{interaction_note}"
                      IO.puts "   #{String.pad_trailing("", 30)} #{bar}"
                    end)

                    important = Sobol.filter_important(indices, threshold: 0.03)
                    IO.puts "\n   Important knobs for CMA-ES: #{inspect(important)}"

                    Sobol.reduce_knob_space(demo_space, indices, threshold: 0.03)

                  {:error, reason} ->
                    IO.puts "   Sobol analysis failed: #{inspect(reason)}"
                    IO.puts "   Using correlated knob space for CMA-ES..."
                    demo_space
                end

              {:error, :timeout} ->
                IO.puts "   Julia failed to start after 30 seconds, using default correlated knob space..."
                %{
                  shared_buffers: {:continuous, 128.0, 2048.0},
                  effective_cache_size: {:continuous, 512.0, 8192.0},
                  work_mem: {:continuous, 4.0, 128.0},
                  max_parallel_workers_per_gather: {:integer, 0, 4},
                  checkpoint_completion_target: {:continuous, 0.5, 0.9},
                  random_page_cost: {:continuous, 1.0, 4.0}
                }
            end
          else
            IO.puts "   Using correlated knob space (Sobol disabled)"
            %{
              shared_buffers: {:continuous, 128.0, 2048.0},
              effective_cache_size: {:continuous, 512.0, 8192.0},
              work_mem: {:continuous, 4.0, 128.0},
              max_parallel_workers_per_gather: {:integer, 0, 4},
              checkpoint_completion_target: {:continuous, 0.5, 0.9},
              random_page_cost: {:continuous, 1.0, 4.0}
            }
          end

          IO.puts "\n5. Initializing CMA-ES optimizer..."
          IO.puts "   Knobs to optimize: #{inspect(Map.keys(knob_space))}"

          # CMA-ES needs more startup trials due to Pythonx compatibility
          startup_trials = min(iterations, 10)

          {:ok, cmaes_state} = CmaEs.init(knob_space,
            sigma0: 0.5,
            n_startup_trials: startup_trials,
            seed: 42
          )
          IO.puts "   CMA-ES initialized with sigma0=0.5, n_startup_trials=#{startup_trials}"
          IO.puts "   (CMA-ES will learn parameter correlations during optimization)"

          IO.puts "\n6. Running optimization loop (#{iterations} iterations)..."
          IO.puts "   (Each iteration runs pgbench for #{duration}s)"
          IO.puts ""
          IO.puts "   Iter | TPS      | Score    | shared_buf | eff_cache | work_mem"
          IO.puts "   -----|----------|----------|------------|-----------|----------"

          {final_state, history} =
            Enum.reduce(1..iterations, {cmaes_state, []}, fn i, {current_state, hist} ->
              {:ok, config, new_state} = CmaEs.suggest(current_state)

              :ok = Benchmark.Pgbench.apply_config(bench_state, config)
              Process.sleep(1_000)

              case Benchmark.Pgbench.run(bench_state) do
                {:ok, score, metrics} ->
                  {:ok, updated_state} = CmaEs.observe(new_state, config, score)

                  sb = Map.get(config, :shared_buffers, "-")
                  ec = Map.get(config, :effective_cache_size, "-")
                  wm = Map.get(config, :work_mem, "-")

                  sb_str = if is_number(sb), do: Float.round(sb * 1.0, 0) |> to_string(), else: "-"
                  ec_str = if is_number(ec), do: Float.round(ec * 1.0, 0) |> to_string(), else: "-"
                  wm_str = if is_number(wm), do: Float.round(wm * 1.0, 1) |> to_string(), else: "-"

                  IO.puts "   #{String.pad_leading(to_string(i), 4)} | #{String.pad_leading(Float.round(metrics.tps, 1) |> to_string(), 8)} | #{String.pad_leading(Float.round(score, 6) |> to_string(), 8)} | #{String.pad_leading(sb_str, 10)} | #{String.pad_leading(ec_str, 9)} | #{String.pad_leading(wm_str, 8)}"

                  {updated_state, [{config, score, metrics} | hist]}

                {:error, reason} ->
                  IO.puts "   #{String.pad_leading(to_string(i), 4)} | ERROR: #{inspect(reason)}"
                  {:ok, updated_state} = CmaEs.observe(new_state, config, 1.0e10)
                  {updated_state, hist}
              end
            end)

          IO.puts "\n7. Analyzing learned correlations..."

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

            # Show learned correlations
            sb = Map.get(best_config, :shared_buffers)
            ec = Map.get(best_config, :effective_cache_size)
            wm = Map.get(best_config, :work_mem)
            pw = Map.get(best_config, :max_parallel_workers_per_gather)
            ct = Map.get(best_config, :checkpoint_completion_target)

            IO.puts "\n   Learned Parameter Correlations:"
            IO.puts "   --------------------------------"

            if sb && ec do
              ratio = ec / max(sb, 1)
              IO.puts "   Memory: effective_cache_size / shared_buffers = #{Float.round(ratio, 1)}:1"
              IO.puts "           (typical production: 3-4:1)"
            end

            if wm && pw do
              IO.puts "   Parallelism: work_mem=#{Float.round(wm, 1)}MB with #{pw} workers"
              IO.puts "                (#{Float.round(wm / max(pw + 1, 1), 1)}MB per worker)"
            end

            if ct do
              IO.puts "   Checkpoint: completion_target=#{Float.round(ct, 2)}"
            end

            IO.puts "\n   Recommended PostgreSQL settings:"
            IO.puts "   ----------------------------------------"
            Enum.each(best_config, fn {param, value} ->
              formatted = KnobSpace.format_value(param, value)
              IO.puts "   ALTER SYSTEM SET #{param} = '#{formatted}';"
            end)
            IO.puts "   SELECT pg_reload_conf();"
            IO.puts "   ----------------------------------------"

            # Compare early vs late iterations to show learning
            if length(history) >= 6 do
              IO.puts "\n8. CMA-ES Learning Progress:"
              early_scores = history |> Enum.reverse() |> Enum.take(3) |> Enum.map(fn {_, s, _} -> s end)
              late_scores = history |> Enum.take(3) |> Enum.map(fn {_, s, _} -> s end)

              early_avg = Enum.sum(early_scores) / length(early_scores)
              late_avg = Enum.sum(late_scores) / length(late_scores)
              learning_improvement = (early_avg - late_avg) / early_avg * 100

              IO.puts "   Early iterations (1-3) avg score: #{Float.round(early_avg, 6)}"
              IO.puts "   Late iterations (#{iterations-2}-#{iterations}) avg score: #{Float.round(late_avg, 6)}"
              IO.puts "   Learning improvement: #{Float.round(learning_improvement, 1)}%"
            end
          end

          IO.puts "\n9. Demonstrating serialization (crash recovery)..."
          serialized = CmaEs.serialize(final_state)
          IO.puts "   Serialized optimizer state: #{byte_size(serialized)} bytes"
          IO.puts "   (Includes learned covariance matrix!)"
          {:ok, _recovered} = CmaEs.deserialize(serialized)
          IO.puts "   Successfully deserialized - can resume with learned correlations!"

          # Cleanup
          Benchmark.Pgbench.cleanup(bench_state)

        {:error, reason} ->
          IO.puts "   Baseline benchmark failed: #{inspect(reason)}"
      end

    {:error, reason} ->
      IO.puts "   Failed to initialize pgbench: #{inspect(reason)}"
  end
after
  # Cleanup demo database if requested
  if cleanup do
    IO.puts "\n10. Cleaning up demo database..."
    Setup.teardown(db_url: base_url, db_name: demo_db_name)
    IO.puts "   Demo database dropped"
  else
    IO.puts "\n   Demo database '#{demo_db_name}' preserved for inspection."
    IO.puts "   Run with CLEANUP=true to drop it, or:"
    IO.puts "   psql -h #{pg_host} -U #{pg_user} -d #{demo_db_name}"
  end
end

IO.puts """

==========================================
CMA-ES Real Database Demo Complete!
==========================================

What this demo demonstrated:
1. Automatic demo database setup with pgbench + sample tables
2. Conservative baseline config for clear optimization potential
3. Julia-based Sobol sensitivity analysis (if enabled)
4. CMA-ES optimization learning parameter correlations
5. Measurable TPS improvement over baseline

CMA-ES vs TPE:
- CMA-ES: Better for correlated parameters (most PostgreSQL knobs)
- TPE: Better for small budgets (<20 iterations)

To run with different settings:
  CMAES_ITERATIONS=30 PGBENCH_DURATION=30 mix run demo_cma_es_real.exs

To skip setup (reuse existing db):
  SKIP_SETUP=true mix run demo_cma_es_real.exs

To cleanup after:
  CLEANUP=true mix run demo_cma_es_real.exs
"""
