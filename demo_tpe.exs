#!/usr/bin/env elixir

# TPE (Tree-structured Parzen Estimator) Demo
# Run with: nix develop -c mix run demo_tpe.exs
#
# TPE is sample-efficient and works well with small budgets (<30 iterations).
# It models good and bad configurations separately and samples from promising regions.

IO.puts """
==========================================
PgGaConf Demo - TPE Optimizer
==========================================

TPE (Tree-structured Parzen Estimator) is best when:
- You have a limited iteration budget (<30)
- Parameters are mostly independent
- You want quick convergence

"""

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

alias PgGaConf.Optimizer.TPE

IO.puts "1. Defining PostgreSQL knob space..."

# Define a realistic knob space for PostgreSQL tuning
# Format: {:continuous, min, max} for floats, {:integer, min, max} for ints
knob_space = %{
  shared_buffers: {:continuous, 128.0, 4096.0},
  effective_cache_size: {:continuous, 512.0, 16384.0},
  work_mem: {:continuous, 4.0, 256.0},
  maintenance_work_mem: {:continuous, 64.0, 2048.0},
  random_page_cost: {:continuous, 1.0, 4.0},
  effective_io_concurrency: {:integer, 1, 200},
  max_parallel_workers_per_gather: {:integer, 0, 4},
  checkpoint_completion_target: {:continuous, 0.5, 0.9}
}

IO.puts "   Knobs to tune:"
Enum.each(knob_space, fn {name, spec} ->
  case spec do
    {:continuous, low, high} -> IO.puts "   - #{name}: #{low} to #{high} (continuous)"
    {:integer, low, high} -> IO.puts "   - #{name}: #{low} to #{high} (integer)"
    {:categorical, choices} -> IO.puts "   - #{name}: #{inspect(choices)} (categorical)"
  end
end)

IO.puts "\n2. Initializing TPE optimizer..."

{:ok, state} = TPE.init(knob_space, n_startup_trials: 3, seed: 42)
IO.puts "   TPE initialized with:"
IO.puts "   - n_startup_trials: 3 (random sampling before modeling)"
IO.puts "   - multivariate: true (models parameter correlations)"

IO.puts "\n3. Simulating optimization loop..."
IO.puts "   (Using synthetic objective: simulating PostgreSQL benchmark)"

# Synthetic objective function that simulates a PostgreSQL benchmark
# In reality, this would run pgbench against your database
objective_fn = fn config ->
  # Simulate a complex objective where:
  # - Higher shared_buffers is generally better (up to a point)
  # - work_mem interacts with parallel workers
  # - random_page_cost affects query plans

  shared_buffers_score = :math.log(config.shared_buffers + 1) / :math.log(4096)
  cache_score = :math.log(config.effective_cache_size + 1) / :math.log(16384)
  work_mem_score = :math.log(config.work_mem + 1) / :math.log(256)

  # Interaction term: parallel workers need more work_mem
  parallel_penalty = if config.max_parallel_workers_per_gather > 0 and config.work_mem < 32 do
    0.2
  else
    0.0
  end

  # random_page_cost sweet spot around 1.5 for SSD
  rpc_score = 1.0 - abs(config.random_page_cost - 1.5) / 2.5

  # Checkpoint target sweet spot around 0.7
  ckpt_score = 1.0 - abs(config.checkpoint_completion_target - 0.7) / 0.2

  # Combine scores (lower is better for TPE minimize)
  base_score = 10.0 - (shared_buffers_score * 3 + cache_score * 2 + work_mem_score * 2 +
                       rpc_score + ckpt_score)

  # Add noise to simulate benchmark variance
  noise = :rand.uniform() * 0.5
  base_score + parallel_penalty + noise
end

# Run optimization loop
iterations = 15

IO.puts ""
IO.puts "   Iter | Score  | shared_buffers | work_mem | random_page_cost"
IO.puts "   -----|--------|----------------|----------|------------------"

{final_state, history} =
  Enum.reduce(1..iterations, {state, []}, fn i, {current_state, hist} ->
    # Get next suggestion from TPE
    {:ok, config, new_state} = TPE.suggest(current_state)

    # Evaluate the configuration
    score = objective_fn.(config)

    # Report result to TPE
    {:ok, updated_state} = TPE.observe(new_state, config, score)

    # Print progress
    IO.puts "   #{String.pad_leading(to_string(i), 4)} | #{Float.round(score, 3) |> to_string() |> String.pad_leading(6)} | " <>
            "#{String.pad_leading(to_string(config.shared_buffers), 14)} | " <>
            "#{String.pad_leading(to_string(config.work_mem), 8)} | " <>
            "#{Float.round(config.random_page_cost, 2)}"

    {updated_state, [{config, score} | hist]}
  end)

IO.puts "\n4. Analyzing results..."

# Find best configuration
{best_config, best_score} = Enum.min_by(history, fn {_, score} -> score end)

IO.puts "\n   Best configuration found:"
IO.puts "   Score: #{Float.round(best_score, 4)}"
IO.puts ""
Enum.each(best_config, fn {name, value} ->
  formatted = if is_float(value), do: Float.round(value, 2), else: value
  IO.puts "   #{name}: #{formatted}"
end)

IO.puts "\n5. Demonstrating warm-start capability..."

# TPE supports warm-starting from prior observations
prior_observations = Enum.take(history, 5)

{:ok, warm_state} = TPE.init(knob_space, n_startup_trials: 3, seed: 123)
{:ok, _warmed_state} = TPE.warm_start(warm_state, prior_observations)

IO.puts "   Warm-started TPE with #{length(prior_observations)} prior observations"
IO.puts "   This enables transfer learning between similar databases!"

IO.puts "\n6. Demonstrating serialization (for crash recovery)..."

serialized = TPE.serialize(final_state)
IO.puts "   Serialized state size: #{byte_size(serialized)} bytes"

{:ok, recovered_state} = TPE.deserialize(serialized)
IO.puts "   Successfully deserialized - can resume optimization!"

# Show that recovered state works
{:ok, next_config, _} = TPE.suggest(recovered_state)
IO.puts "   Next suggested config from recovered state:"
IO.puts "     shared_buffers: #{next_config.shared_buffers}"
IO.puts "     work_mem: #{next_config.work_mem}"

IO.puts """

==========================================
TPE Demo Complete!
==========================================

Key TPE features demonstrated:
1. Sample-efficient optimization (found good config in #{iterations} iterations)
2. Multivariate modeling (captures parameter interactions)
3. Warm-start capability (transfer learning between databases)
4. Serialization (crash recovery and checkpointing)

When to use TPE:
- Small iteration budgets (<30 trials)
- When parameters are relatively independent
- Quick initial tuning runs

For production use with real PostgreSQL:
  {:ok, job} = PgGaConf.tune("postgres://user:pass@host/db",
    optimizer: :tpe,
    max_iterations: 20
  )

"""
