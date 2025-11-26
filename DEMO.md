# PgGaConf Demo

## Quick Start

To test out the system right now, run:

```bash
nix develop -c mix run demo.exs
```

This will demonstrate all the major features of the system.

## What the Demo Shows

The demo script (`demo.exs`) showcases:

1. **Database Connection** - Connects to local PostgreSQL
2. **Schema Scanning** - Scans database tables, columns, indexes, foreign keys
3. **Configuration Management** - Creates and manages PostgreSQL configurations
4. **Benchmarking** - Runs workloads and collects performance metrics (TPS, cache hit ratio)
5. **Genetic Algorithm** - Optimizes configuration over 5 generations
6. **Instance Providers** - Tests LocalPostgres and MockProvider adapters
7. **Workload Generation** - Runs simple SELECT query workload

## Sample Output

```
========================================
PgGaConf Demo - PostgreSQL GA Optimizer
========================================

1. Connecting to PostgreSQL...
   ✓ Connected to database

2. Scanning database schema...
   ✓ Found 0 tables
   ✓ Found 45 columns
   ✓ Found 0 indexes
   ✓ Found 0 foreign keys

3. Creating initial PostgreSQL configuration...
   ✓ Initial config: shared_buffers=128MB

4. Benchmarking initial configuration...
   ✓ TPS: 105371.0
   ✓ Cache Hit Ratio: 99.9%
   ✓ Temp Files: 0
   ✓ Deadlocks: 0

5. Running Genetic Algorithm optimization...
   [GA runs for 5 generations]

6. Optimization Results:
   ✓ Completed 5 generations
   ✓ Best fitness: 59.53

   Optimized Configuration:
     - shared_buffers: 3655MB
     - effective_cache_size: 7421MB
     - work_mem: 55MB
     - maintenance_work_mem: 132MB
     - checkpoint_completion_target: 0.9
     - max_wal_size: 1024MB
     - max_parallel_workers_per_gather: 2
```

## Other Ways to Test

### Run Tests

```bash
nix develop -c mix test
```

All 89 tests should pass.

### Interactive Shell

Start an interactive Elixir shell:

```bash
nix develop -c iex -S mix
```

Then you can manually test components:

```elixir
# Connect to database
{:ok, conn} = Postgrex.start_link(hostname: "localhost", port: 5432, username: "postgres", database: "pgga_test")

# Scan database
alias PgGaConf.Core.DatabaseScanner
schema = DatabaseScanner.scan_database(conn)

# Create a configuration
alias PgGaConf.Core.ConfigChromosome
config = ConfigChromosome.new(%{shared_buffers: 256})

# Run a simple workload
alias PgGaConf.Workload.SimpleWorkload
SimpleWorkload.run(conn, duration_seconds: 1)

# Benchmark a configuration
alias PgGaConf.Benchmark.Evaluator
workload = fn conn -> SimpleWorkload.run(conn, duration_seconds: 1) end
metrics = Evaluator.evaluate(config, conn, workload)

IO.inspect(metrics)
```

### Explore Components

Check out individual modules:

- **lib/pg_ga_conf/core/** - Core data structures
- **lib/pg_ga_conf/ga/** - Genetic algorithm engine
- **lib/pg_ga_conf/benchmark/** - Benchmarking system
- **lib/pg_ga_conf/strategies/** - Optimization strategies
- **lib/pg_ga_conf/instance/** - Instance providers
- **lib/pg_ga_conf/workload/** - Workload generators

## Next Steps

The system is ready for:

1. CLI interface implementation
2. Additional workload types (OLTP, OLAP, mixed)
3. Supabase Cloud instance provider
4. Integration with pgbench/sysbench
5. Configuration persistence and reporting
6. Web dashboard for optimization tracking
