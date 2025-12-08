#!/usr/bin/env elixir

# TPE Demo - Shows Real Improvement
# Run with: nix develop -c mix run demo_tpe_improvement.exs
#
# This demo is designed to show CLEAR improvement from TPE optimization by:
# 1. Starting with intentionally BAD PostgreSQL config
# 2. Using a workload sensitive to configuration changes
# 3. Tuning knobs with wide ranges that have real impact
#
# Environment variables:
#   PGHOST, PGPORT, PGUSER, PGPASSWORD - PostgreSQL connection
#   PGBENCH_DURATION - Benchmark duration (default: 15s)
#   PGBENCH_CLIENTS - Number of clients (default: 8)
#   PGBENCH_SCALE - Scale factor (default: 50 - larger = more data)
#   TPE_ITERATIONS - Optimization iterations (default: 15)
#   CLEANUP - Drop database after demo (default: true)

IO.puts """
╔══════════════════════════════════════════════════════════════╗
║     TPE Optimization Demo - Showing Real Improvement         ║
╠══════════════════════════════════════════════════════════════╣
║  This demo starts with INTENTIONALLY BAD configuration       ║
║  and shows how TPE finds better settings.                    ║
╚══════════════════════════════════════════════════════════════╝

"""

# Configuration
pg_host = System.get_env("PGHOST", "localhost")
pg_port = System.get_env("PGPORT", "5432")
pg_user = System.get_env("PGUSER", "postgres")
pg_password = System.get_env("PGPASSWORD", "postgres")
demo_db = "tpe_improvement_demo"

duration = String.to_integer(System.get_env("PGBENCH_DURATION", "15"))
clients = String.to_integer(System.get_env("PGBENCH_CLIENTS", "8"))
scale = String.to_integer(System.get_env("PGBENCH_SCALE", "50"))
iterations = String.to_integer(System.get_env("TPE_ITERATIONS", "15"))
cleanup = System.get_env("CLEANUP", "true") == "true"

IO.puts "Configuration:"
IO.puts "  PostgreSQL: #{pg_host}:#{pg_port}"
IO.puts "  Database: #{demo_db}"
IO.puts "  pgbench: #{duration}s, #{clients} clients, scale #{scale}"
IO.puts "  TPE iterations: #{iterations}"
IO.puts ""

# Start application
{:ok, _} = Application.ensure_all_started(:pg_ga_conf)

# Initialize Python/Optuna
IO.puts "Initializing Python/Optuna..."
Pythonx.uv_init("""
[project]
name = "pg_ga_conf"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = ["optuna>=3.5.0"]
""")

alias PgGaConf.Demo.Setup
alias PgGaConf.Optimizer.TPE
alias PgGaConf.KnobSpace

# Helper to run psql
run_psql = fn sql, db ->
  env = [{"PGPASSWORD", pg_password}]
  args = ["-h", pg_host, "-p", pg_port, "-U", pg_user, "-d", db, "-t", "-A", "-c", sql]
  case System.cmd("psql", args, env: env, stderr_to_stdout: true) do
    {output, 0} -> {:ok, String.trim(output)}
    {output, _} -> {:error, output}
  end
end

# Helper to run pgbench
run_pgbench = fn db ->
  env = [{"PGPASSWORD", pg_password}]
  args = [
    "-c", to_string(clients),
    "-j", to_string(min(clients, 4)),
    "-T", to_string(duration),
    "-h", pg_host,
    "-p", pg_port,
    "-U", pg_user,
    db
  ]

  case System.cmd("pgbench", args, env: env, stderr_to_stdout: true) do
    {output, 0} ->
      # Parse TPS from output
      case Regex.run(~r/tps = ([\d.]+)/, output) do
        [_, tps_str] -> {:ok, String.to_float(tps_str)}
        _ -> {:error, "Could not parse TPS"}
      end
    {output, _} -> {:error, output}
  end
end

# Apply PostgreSQL config
apply_config = fn config, db ->
  Enum.each(config, fn {param, value} ->
    formatted = KnobSpace.format_value(param, value)
    sql = "ALTER SYSTEM SET #{param} = '#{formatted}'"
    run_psql.(sql, db)
  end)
  run_psql.("SELECT pg_reload_conf()", db)
  # Brief pause for config to take effect
  Process.sleep(500)
end

# Cleanup function
cleanup_fn = fn ->
  if cleanup do
    IO.puts "\nCleaning up..."
    # Reset config
    run_psql.("ALTER SYSTEM RESET ALL", "postgres")
    run_psql.("SELECT pg_reload_conf()", "postgres")
    # Drop database
    run_psql.("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '#{demo_db}'", "postgres")
    System.cmd("dropdb", ["-h", pg_host, "-p", pg_port, "-U", pg_user, "--if-exists", demo_db],
      env: [{"PGPASSWORD", pg_password}], stderr_to_stdout: true)
    IO.puts "Cleanup complete."
  end
end

try do
  # Step 1: Ensure PostgreSQL is running
  IO.puts "Step 1: Checking PostgreSQL..."
  case Setup.ensure_postgres_running() do
    :ok -> IO.puts "  PostgreSQL is running"
    {:error, reason} ->
      IO.puts "  ERROR: #{inspect(reason)}"
      System.halt(1)
  end

  # Step 2: Create demo database with larger dataset
  IO.puts "\nStep 2: Creating demo database with scale=#{scale}..."

  # Drop if exists
  System.cmd("dropdb", ["-h", pg_host, "-p", pg_port, "-U", pg_user, "--if-exists", demo_db],
    env: [{"PGPASSWORD", pg_password}], stderr_to_stdout: true)

  # Create database
  case System.cmd("createdb", ["-h", pg_host, "-p", pg_port, "-U", pg_user, demo_db],
         env: [{"PGPASSWORD", pg_password}], stderr_to_stdout: true) do
    {_, 0} -> IO.puts "  Database created"
    {output, _} ->
      IO.puts "  ERROR creating database: #{output}"
      System.halt(1)
  end

  # Initialize pgbench with larger scale
  IO.puts "  Initializing pgbench tables (this may take a moment)..."
  case System.cmd("pgbench", ["-i", "-s", to_string(scale), "-h", pg_host, "-p", pg_port, "-U", pg_user, demo_db],
         env: [{"PGPASSWORD", pg_password}], stderr_to_stdout: true) do
    {_, 0} -> IO.puts "  pgbench initialized with #{scale * 100_000} accounts"
    {output, _} ->
      IO.puts "  ERROR: #{output}"
      System.halt(1)
  end

  # Step 3: Apply INTENTIONALLY BAD baseline config
  IO.puts "\nStep 3: Applying INTENTIONALLY BAD baseline config..."

  bad_config = %{
    # Tiny shared buffers - forces lots of disk reads
    shared_buffers: 32.0,  # 32MB - way too small
    # Tiny work_mem - causes sorts to spill to disk
    work_mem: 1.0,  # 1MB - minimal
    # Small cache size estimate - bad query plans
    effective_cache_size: 128.0,  # 128MB - tells planner we have no RAM
    # High random_page_cost - discourages index usage on SSD
    random_page_cost: 4.0,  # Default for spinning disk
    # Aggressive checkpointing - more I/O overhead
    checkpoint_completion_target: 0.5  # Rushed checkpoints
  }

  apply_config.(bad_config, demo_db)

  IO.puts "  Applied bad config:"
  IO.puts "    shared_buffers: 32MB (way too small)"
  IO.puts "    work_mem: 1MB (will spill to disk)"
  IO.puts "    effective_cache_size: 128MB (bad query plans)"
  IO.puts "    random_page_cost: 4.0 (wrong for SSD)"
  IO.puts "    checkpoint_completion_target: 0.5 (rushed)"

  # Step 4: Run baseline benchmark
  IO.puts "\nStep 4: Running BASELINE benchmark (with bad config)..."
  IO.puts "  Running pgbench for #{duration}s with #{clients} clients..."

  {:ok, baseline_tps} = run_pgbench.(demo_db)
  baseline_score = 1.0 / baseline_tps

  IO.puts ""
  IO.puts "  ┌─────────────────────────────────────┐"
  IO.puts "  │  BASELINE (Bad Config)              │"
  IO.puts "  │  TPS: #{String.pad_leading(Float.round(baseline_tps, 1) |> to_string(), 10)}              │"
  IO.puts "  └─────────────────────────────────────┘"
  IO.puts ""

  # Step 5: Define optimization space
  IO.puts "Step 5: Defining optimization space..."

  # Knob space with ranges that can actually help
  knob_space = %{
    # Memory - let optimizer find good values
    shared_buffers: {:continuous, 64.0, 512.0},  # 64MB to 512MB
    work_mem: {:continuous, 4.0, 64.0},  # 4MB to 64MB
    effective_cache_size: {:continuous, 256.0, 2048.0},  # 256MB to 2GB

    # Planner costs - important for query plans
    random_page_cost: {:continuous, 1.0, 4.0},  # 1.0 (SSD) to 4.0 (HDD)

    # Checkpoint tuning
    checkpoint_completion_target: {:continuous, 0.5, 0.9}
  }

  IO.puts "  Knobs to optimize:"
  Enum.each(knob_space, fn {name, {:continuous, low, high}} ->
    IO.puts "    #{name}: #{low} → #{high}"
  end)

  # Step 6: Initialize TPE
  IO.puts "\nStep 6: Initializing TPE optimizer..."
  {:ok, tpe_state} = TPE.init(knob_space, n_startup_trials: 3, seed: 42)
  IO.puts "  TPE ready (3 random startup trials, then Bayesian optimization)"

  # Step 7: Run optimization loop
  IO.puts "\nStep 7: Running TPE optimization (#{iterations} iterations)..."
  IO.puts ""
  IO.puts "  Iter │   TPS    │ vs Baseline │ Key Changes"
  IO.puts "  ─────┼──────────┼─────────────┼─────────────────────────────────"

  {final_state, history} = Enum.reduce(1..iterations, {tpe_state, []}, fn i, {state, hist} ->
    # Get suggestion from TPE
    {:ok, config, new_state} = TPE.suggest(state)

    # Apply config
    apply_config.(config, demo_db)

    # Run benchmark
    case run_pgbench.(demo_db) do
      {:ok, tps} ->
        score = 1.0 / tps
        {:ok, updated_state} = TPE.observe(new_state, config, score)

        improvement = ((tps - baseline_tps) / baseline_tps * 100)
        improvement_str = if improvement >= 0, do: "+#{Float.round(improvement, 1)}%", else: "#{Float.round(improvement, 1)}%"

        # Show key config differences from baseline
        changes = []
        if config.shared_buffers > 100, do: changes = ["shbuf=#{round(config.shared_buffers)}MB" | changes]
        if config.work_mem > 8, do: changes = ["wmem=#{round(config.work_mem)}MB" | changes]
        if config.random_page_cost < 2.5, do: changes = ["rpc=#{Float.round(config.random_page_cost, 1)}" | changes]
        changes_str = Enum.join(Enum.reverse(changes), ", ")

        IO.puts "  #{String.pad_leading(to_string(i), 4)} │ #{String.pad_leading(Float.round(tps, 1) |> to_string(), 8)} │ #{String.pad_leading(improvement_str, 11)} │ #{changes_str}"

        {updated_state, [{config, score, tps} | hist]}

      {:error, reason} ->
        IO.puts "  #{String.pad_leading(to_string(i), 4)} │ ERROR: #{inspect(reason)}"
        {:ok, updated_state} = TPE.observe(new_state, config, 1.0e10)
        {updated_state, hist}
    end
  end)

  # Step 8: Show results
  IO.puts ""
  IO.puts "Step 8: Results"
  IO.puts ""

  if Enum.empty?(history) do
    IO.puts "  No successful iterations!"
  else
    {best_config, _best_score, best_tps} = Enum.min_by(history, fn {_, score, _} -> score end)

    improvement = ((best_tps - baseline_tps) / baseline_tps * 100)

    IO.puts "  ╔═══════════════════════════════════════════════════════════════╗"
    IO.puts "  ║                    OPTIMIZATION RESULTS                       ║"
    IO.puts "  ╠═══════════════════════════════════════════════════════════════╣"
    IO.puts "  ║                                                               ║"
    IO.puts "  ║   BASELINE (Bad Config)     →    OPTIMIZED                    ║"
    IO.puts "  ║   #{String.pad_leading(Float.round(baseline_tps, 1) |> to_string(), 8)} TPS              →    #{String.pad_leading(Float.round(best_tps, 1) |> to_string(), 8)} TPS                 ║"
    IO.puts "  ║                                                               ║"
    IO.puts "  ║   Improvement: #{String.pad_leading(Float.round(improvement, 1) |> to_string(), 6)}%                                      ║"
    IO.puts "  ║                                                               ║"
    IO.puts "  ╠═══════════════════════════════════════════════════════════════╣"
    IO.puts "  ║   RECOMMENDED SETTINGS:                                       ║"
    IO.puts "  ╠═══════════════════════════════════════════════════════════════╣"

    Enum.each(best_config, fn {param, value} ->
      formatted = KnobSpace.format_value(param, value)
      line = "  ║   ALTER SYSTEM SET #{param} = '#{formatted}';"
      IO.puts String.pad_trailing(line, 68) <> "║"
    end)

    IO.puts "  ║   SELECT pg_reload_conf();                                    ║"
    IO.puts "  ╚═══════════════════════════════════════════════════════════════╝"
    IO.puts ""

    # Show what changed
    IO.puts "  What TPE learned:"
    IO.puts "  ─────────────────"
    if best_config.shared_buffers > bad_config.shared_buffers * 2 do
      IO.puts "  ✓ shared_buffers: #{round(bad_config.shared_buffers)}MB → #{round(best_config.shared_buffers)}MB (more buffer cache)"
    end
    if best_config.work_mem > bad_config.work_mem * 2 do
      IO.puts "  ✓ work_mem: #{round(bad_config.work_mem)}MB → #{round(best_config.work_mem)}MB (less disk spilling)"
    end
    if best_config.effective_cache_size > bad_config.effective_cache_size * 2 do
      IO.puts "  ✓ effective_cache_size: #{round(bad_config.effective_cache_size)}MB → #{round(best_config.effective_cache_size)}MB (better plans)"
    end
    if best_config.random_page_cost < bad_config.random_page_cost - 1 do
      IO.puts "  ✓ random_page_cost: #{bad_config.random_page_cost} → #{Float.round(best_config.random_page_cost, 2)} (prefers indexes)"
    end
    if best_config.checkpoint_completion_target > bad_config.checkpoint_completion_target + 0.1 do
      IO.puts "  ✓ checkpoint_completion_target: #{bad_config.checkpoint_completion_target} → #{Float.round(best_config.checkpoint_completion_target, 2)} (smoother I/O)"
    end
  end

after
  cleanup_fn.()
end

IO.puts """

════════════════════════════════════════════════════════════════
Demo complete!

This demo showed TPE optimization improving PostgreSQL performance
by finding better configuration values through Bayesian optimization.

To run with different settings:
  TPE_ITERATIONS=25 PGBENCH_SCALE=100 mix run demo_tpe_improvement.exs

To keep the database for inspection:
  CLEANUP=false mix run demo_tpe_improvement.exs
════════════════════════════════════════════════════════════════
"""
