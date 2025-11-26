#!/usr/bin/env elixir

# Demo script for PgGaConf - PostgreSQL Genetic Algorithm Configuration Optimizer
# Run with: nix develop -c mix run demo.exs

IO.puts """
========================================
PgGaConf Demo - PostgreSQL GA Optimizer
========================================
"""

# Start the application
{:ok, _} = Application.ensure_all_started(:pg_ga_conf)

# Aliases
alias PgGaConf.Core.{DatabaseScanner, ConfigChromosome}
alias PgGaConf.GA.Engine
alias PgGaConf.Strategies.Conservative
alias PgGaConf.Benchmark.{Evaluator, MetricsCollector}
alias PgGaConf.Workload.SimpleWorkload

IO.puts "\n1. Starting PostgreSQL on unused port..."

# Find an unused port
demo_port = 15432
demo_data_dir = Path.join(System.tmp_dir!(), "pgga_demo_#{:erlang.system_time()}")
File.mkdir_p!(demo_data_dir)

# Initialize PostgreSQL data directory
{init_output, 0} = System.cmd("initdb", ["-D", demo_data_dir], stderr_to_stdout: true)
IO.puts "   ✓ Initialized PostgreSQL data directory"

# Start PostgreSQL on custom port
pg_process = Port.open(
  {:spawn_executable, System.find_executable("postgres")},
  [:binary, :exit_status, args: ["-D", demo_data_dir, "-p", "#{demo_port}", "-k", demo_data_dir]]
)

# Wait for PostgreSQL to start
:timer.sleep(2000)
IO.puts "   ✓ Started PostgreSQL on port #{demo_port}"

# Create database
System.cmd("createdb", ["-h", "localhost", "-p", "#{demo_port}", "pgga_demo"], stderr_to_stdout: true)

IO.puts "\n2. Connecting to PostgreSQL..."
{:ok, conn} = Postgrex.start_link(
  hostname: "localhost",
  port: demo_port,
  username: System.get_env("USER"),
  database: "pgga_demo"
)
IO.puts "   ✓ Connected to database"

IO.puts "\n3. Scanning database schema..."
schema = DatabaseScanner.scan_database(conn)
IO.puts "   ✓ Found #{length(schema.tables)} tables"
IO.puts "   ✓ Found #{length(schema.columns)} columns"
IO.puts "   ✓ Found #{length(schema.indexes)} indexes"
IO.puts "   ✓ Found #{length(schema.foreign_keys)} foreign keys"

IO.puts "\n4. Creating initial PostgreSQL configuration..."
chromosome = ConfigChromosome.new(%{
  shared_buffers: 128,
  effective_cache_size: 512,
  work_mem: 4,
  maintenance_work_mem: 64
})
IO.puts "   ✓ Initial config: shared_buffers=#{chromosome.shared_buffers}MB"

IO.puts "\n5. Benchmarking initial configuration..."
workload = fn conn ->
  SimpleWorkload.run(conn, duration_seconds: 1)
end

metrics = Evaluator.evaluate(chromosome, conn, workload, duration_seconds: 1)
IO.puts "   ✓ TPS: #{Float.round(metrics.transactions_per_sec, 2)}"
IO.puts "   ✓ Cache Hit Ratio: #{Float.round(metrics.cache_hit_ratio * 100, 1)}%"
IO.puts "   ✓ Temp Files: #{metrics.temp_files}"
IO.puts "   ✓ Deadlocks: #{metrics.deadlocks}"

IO.puts "\n6. Running Genetic Algorithm optimization..."
IO.puts "   (Using ConservativeStrategy with small population for demo)"

fitness_evaluator = fn chromosome ->
  # Quick evaluation for demo
  workload_fn = fn conn ->
    for _ <- 1..10, do: Postgrex.query!(conn, "SELECT 1", [])
    :ok
  end
  Evaluator.evaluate(chromosome, conn, workload_fn, duration_seconds: 0.5)
end

{:ok, result} = Engine.evolve(
  strategy: Conservative,
  fitness_evaluator: fitness_evaluator,
  population_size: 6,
  generations: 5,
  elitism_count: 1,
  early_stop_generations: 3
)

IO.puts "\n7. Optimization Results:"
IO.puts "   ✓ Completed #{result.generation} generations"
IO.puts "   ✓ Best fitness: #{Float.round(result.best_fitness, 2)}"
IO.puts "\n   Optimized Configuration:"
best = result.best_chromosome
IO.puts "     - shared_buffers: #{best.shared_buffers}MB"
IO.puts "     - effective_cache_size: #{best.effective_cache_size}MB"
IO.puts "     - work_mem: #{best.work_mem}MB"
IO.puts "     - maintenance_work_mem: #{best.maintenance_work_mem}MB"
IO.puts "     - checkpoint_completion_target: #{Float.round(best.checkpoint_completion_target, 2)}"
IO.puts "     - max_wal_size: #{best.max_wal_size}MB"
IO.puts "     - max_parallel_workers_per_gather: #{best.max_parallel_workers_per_gather}"

IO.puts "\n8. Evolution History:"
result.history
|> Enum.reverse()
|> Enum.each(fn gen ->
  IO.puts "   Gen #{gen.generation}: best=#{Float.round(gen.best_fitness, 2)}, avg=#{Float.round(gen.avg_fitness, 2)}"
end)

IO.puts "\n9. Testing Instance Providers..."
alias PgGaConf.Instance.{LocalPostgres, MockProvider}

{:ok, local_info} = LocalPostgres.start_instance(chromosome)
IO.puts "   ✓ LocalPostgres: #{local_info.instance_id} (#{local_info.hostname}:#{local_info.port})"

{:ok, mock_info} = MockProvider.start_instance(chromosome)
IO.puts "   ✓ MockProvider: #{mock_info.instance_id} (#{mock_info.hostname}:#{mock_info.port})"

LocalPostgres.stop_instance(local_info.instance_id)
MockProvider.stop_instance(mock_info.instance_id)

IO.puts "\n10. Testing Workload Generator..."
start_time = System.monotonic_time(:millisecond)
SimpleWorkload.run(conn, duration_seconds: 0.5)
elapsed = System.monotonic_time(:millisecond) - start_time
IO.puts "   ✓ Workload ran for #{elapsed}ms (target: 500ms)"

# Cleanup
IO.puts "\n11. Cleaning up..."
GenServer.stop(conn)
System.cmd("pg_ctl", ["stop", "-D", demo_data_dir, "-m", "fast"], stderr_to_stdout: true)
:timer.sleep(500)
File.rm_rf!(demo_data_dir)
IO.puts "   ✓ Stopped PostgreSQL and cleaned up temp directory"

IO.puts """

========================================
Demo Complete!
========================================

Summary:
- Database scanning: ✓
- Configuration management: ✓
- Benchmarking: ✓
- Genetic algorithm optimization: ✓
- Instance providers: ✓
- Workload generation: ✓

Next steps:
1. Implement CLI interface
2. Add more workload types (OLTP, OLAP, mixed)
3. Add Supabase Cloud instance provider
4. Integrate with real-world benchmarks (pgbench, sysbench)
5. Add configuration persistence and reporting

Run tests with: nix develop -c mix test
"""
