# PgGaConf Unified Optimizer Design

> **Date:** 2025-11-26
> **Status:** Draft - Pending Approval

## Overview

This document describes the design for adding Bayesian Optimization (TPE) and CMA-ES as alternative optimizers to the existing Genetic Algorithm approach in PgGaConf. All three optimizers share a common infrastructure for knob discovery (Sobol sensitivity analysis), benchmarking, and result storage.

## Goals

1. **Three optimizer options:** GA, TPE, and CMA-ES - each with different tradeoffs
2. **Shared Sobol analysis:** Reduce 300+ PostgreSQL knobs to ~12 important ones before optimization
3. **Transfer learning:** Warm-start new databases from similar historical sessions
4. **Resilient execution:** Checkpoint after every iteration, auto-resume on failure
5. **Flexible deployment:** Nix devShell for local dev, Docker for production (K8s)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PgGaConf                                        │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                      Shared Infrastructure                              │ │
│  │                                                                         │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  │ │
│  │  │   Sobol     │  │  Benchmark  │  │  Workload   │  │   Result     │  │ │
│  │  │  Analysis   │  │   Runner    │  │ Fingerprint │  │   Store      │  │ │
│  │  │  (Julia)    │  │  (pgbench)  │  │             │  │   (Ecto)     │  │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └──────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│                    ┌───────────────┼───────────────┐                        │
│                    ▼               ▼               ▼                        │
│           ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                │
│           │  Optimizer  │  │  Optimizer  │  │  Optimizer  │                │
│           │     :ga     │  │    :tpe     │  │   :cma_es   │                │
│           │  (Elixir)   │  │  (Pythonx)  │  │  (Pythonx)  │                │
│           └─────────────┘  └─────────────┘  └─────────────┘                │
│                    │               │               │                        │
│                    └───────────────┴───────────────┘                        │
│                                    │                                         │
│                    ┌───────────────▼───────────────┐                        │
│                    │     Optimizer Behaviour       │                        │
│                    │  • init/2    • observe/3      │                        │
│                    │  • suggest/1 • best/1         │                        │
│                    │  • serialize/1 • deserialize/1│                        │
│                    └───────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────────────┘

Production Deployment (K8s):

┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes Pod                            │
│                                                                  │
│  ┌──────────────────────┐      ┌──────────────────────┐        │
│  │   Elixir Container   │      │   Julia Container    │        │
│  │                      │      │                      │        │
│  │  • PgGaConf app      │ TCP  │  • Sobol analysis    │        │
│  │  • Pythonx (Optuna)  │◄────►│  • JSON server       │        │
│  │  • GA optimizer      │:9999 │  • Long-running      │        │
│  │  • Benchmark runner  │      │                      │        │
│  └──────────────────────┘      └──────────────────────┘        │
│         Nix-based                   Julia-native                │
└─────────────────────────────────────────────────────────────────┘
```

## Optimizer Comparison

| Aspect | GA | TPE | CMA-ES |
|--------|-----|-----|--------|
| Sample efficiency | Low | High | Medium-High |
| Learns correlations | No | Partially | Yes (covariance matrix) |
| Handles categoricals | Native | Native | Integer encoding |
| Escapes local optima | Good | Poor | Good |
| Implementation | Pure Elixir | Pythonx/Optuna | Pythonx/Optuna |
| Best for | Diverse exploration | Low budget (<30 iter) | Correlated continuous params |

## Design Decisions

### 1. Optimizer Interface

All optimizers implement a common behaviour with serialize/deserialize for checkpointing:

```elixir
defmodule PgGaConf.Optimizer do
  @type config :: %{atom() => number()}
  @type score :: float()
  @type state :: term()

  @callback init(knob_space :: map(), opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback suggest(state()) :: {:ok, config(), state()} | {:error, term()}
  @callback observe(state(), config(), score()) :: {:ok, state()}
  @callback best(state()) :: {:ok, config(), score()} | {:error, :no_observations}
  @callback serialize(state()) :: binary()
  @callback deserialize(binary()) :: {:ok, state()} | {:error, term()}

  @callback warm_start(state(), observations :: [{config(), score()}]) :: {:ok, state()}
  @optional_callbacks [warm_start: 2]
end
```

**Rationale:**
- `best/1` is separate from `observe/3` for single responsibility
- Serialize/deserialize enables crash recovery via checkpointing
- TPE/CMA-ES state is pickled Python objects stored as binary in Elixir

### 2. Knob Space Representation

Atoms in Elixir, convert to strings at Python boundary:

```elixir
# Elixir side
%{shared_buffers: {:continuous, 128.0, 16384.0}}

# Python side (after conversion)
{"shared_buffers": [128.0, 16384.0]}
```

**Rationale:** Idiomatic Elixir code, clean boundary conversion using `String.to_existing_atom/1` (safe since knobs are predefined).

### 3. Categorical Encoding for CMA-ES

CMA-ES only handles continuous/integer parameters. Categoricals are integer-encoded:

```elixir
# huge_pages: ["off", "on", "try"]
# Encoded as: 0, 1, 2
# CMA-ES sees: {:int, 0, 2}
# Decoded back to string when applying config
```

**Rationale:** Keeps all knobs in play for CMA-ES, matches Optuna's internal handling.

### 4. State Management for Pythonx Optimizers

Serialize/deserialize (pickle) after each operation:

```elixir
# After each suggest/observe:
study_bytes = Pythonx.eval("pickle.dumps(study)", ...)

# State stored in Elixir struct:
%TPE{study_bytes: <<...>>, knob_space: %{...}, iteration: 5}
```

**Rationale:**
- Crash recovery: state is just bytes, can persist to DB
- No Python GC surprises
- ~1-5ms overhead acceptable (benchmark takes 60+ seconds)

### 5. Sobol Analysis Workflow

On-demand per database with caching by workload fingerprint:

```
First tuning:
  1. Compute workload fingerprint → cluster "oltp"
  2. Check cache for similar fingerprint
     - HIT: Use cached knob ranking
     - MISS: Run Sobol analysis, cache results
  3. Optimize with chosen method

Subsequent tuning (same or similar DB):
  1. Compute fingerprint → cache hit → skip Sobol
```

**Options:**
- `:auto` - Check cache, run if needed (default)
- `:skip` - Use predefined knobs for workload type
- `:force` - Always run fresh analysis

**Sobol Tiers:**

| Mode | Samples | Time | Use Case |
|------|---------|------|----------|
| `:quick` | 64 | ~2 min | Development |
| `:standard` | 128 | ~5 min | Default |
| `:thorough` | 256 | ~10 min | Important DBs |
| `:full` | 1024 | ~40 min | Research |

### 6. Benchmark Runner

Pluggable with pgbench as default:

```elixir
defmodule PgGaConf.Benchmark do
  @callback run(db_conn :: term(), config(), opts :: keyword()) :: {:ok, metrics()} | {:error, term()}
  @callback score(metrics()) :: float()
  @optional_callbacks [score: 1]
end
```

**Default score:** p99 latency (lower is better)

**Custom benchmark example:**
```elixir
PgGaConf.optimize(conn,
  benchmark: MyApp.Benchmark.RealQueries,
  benchmark_opts: [queries: production_queries]
)
```

### 7. Result Storage

Uses user's existing Ecto repo:

```elixir
# config/config.exs
config :pg_ga_conf, repo: MyApp.Repo
```

**Tables:**
- `pg_ga_conf_observations` - Individual (config, score) pairs for transfer learning
- `pg_ga_conf_sessions` - Tuning session history and checkpoints
- `pg_ga_conf_sobol_cache` - Cached sensitivity analysis results

### 8. Error Handling and Recovery

Resilient with checkpointing - never crash the supervisor:

| Scenario | Behavior |
|----------|----------|
| Benchmark timeout | Retry after backoff, skip after 3 consecutive failures |
| DB connection lost | Pause, save state, resume when connection returns |
| Julia crash | Reconnect, retry iteration |
| Python error | Log, skip iteration, continue |
| User stops | Save checkpoint, can resume later |
| App restart | Auto-resume paused/crashed sessions |
| Unrecoverable | Mark failed, preserve history |

**Session states:** `:initializing`, `:running`, `:paused`, `:completed`, `:failed`, `:stopped`

### 9. Julia Communication

Same resilience pattern for local (erlexec) and production (TCP):

- Auto-reconnect with exponential backoff
- Health checks every 30 seconds
- Pending request tracking
- Graceful degradation

**Local dev:** Julia process via erlexec, JSON over stdio
**Production:** Julia container, JSON over TCP port 9999

### 10. Deployment

| Environment | Solution |
|-------------|----------|
| Local dev | Nix devShell (Julia + Elixir + PostgreSQL) |
| Production | Two Docker images deployed to K8s |

**Elixir image:** Nix-based build
**Julia image:** Standard Julia base image

## Public API

### High-Level (Easy Path)

```elixir
# Full pipeline: fingerprint → sobol → optimize
{:ok, result} = PgGaConf.optimize(conn, optimizer: :tpe, max_iterations: 30)

# Async with polling
{:ok, session_id} = PgGaConf.optimize_async(conn, optimizer: :cma_es)
status = PgGaConf.get_status(session_id)
PgGaConf.stop(session_id)
```

### Composable (Advanced Use)

```elixir
# Step by step
{:ok, fingerprint} = PgGaConf.fingerprint(conn)
{:ok, knobs} = PgGaConf.analyze_sensitivity(conn, fingerprint, samples: 256)

# Filter knobs if needed
knobs = Enum.reject(knobs, &(&1 == :huge_pages))

# Choose optimizer
optimizer = PgGaConf.recommend_optimizer(knobs, budget: 50)

# Run with custom benchmark
{:ok, result} = PgGaConf.run_optimizer(conn, knobs,
  optimizer: optimizer,
  benchmark: MyApp.Benchmark.RealQueries
)

# Apply to another database
PgGaConf.apply_config(production_conn, result.best_config)
```

### Utility Functions

```elixir
PgGaConf.recommended_config(:oltp)        # Historical best for workload type
PgGaConf.current_config(conn)             # Get current DB config
PgGaConf.apply_config(conn, config)       # Apply config to DB
PgGaConf.recommend_optimizer(knobs, budget: 30)  # Which optimizer to use
```

## Knob Space

### Full Knob Space (~27 tunable without restart)

**Memory:**
- `shared_buffers`, `work_mem`, `maintenance_work_mem`, `effective_cache_size`
- `huge_pages` (categorical: off/on/try)

**WAL:**
- `wal_buffers`, `checkpoint_completion_target`, `max_wal_size`, `min_wal_size`

**Planner:**
- `random_page_cost`, `seq_page_cost`, `cpu_tuple_cost`, `cpu_index_tuple_cost`
- `effective_io_concurrency`, `default_statistics_target`

**Parallelism:**
- `max_parallel_workers_per_gather`, `max_parallel_workers`, `max_parallel_maintenance_workers`
- `parallel_tuple_cost`, `parallel_setup_cost`

**Autovacuum:**
- `autovacuum_vacuum_scale_factor`, `autovacuum_analyze_scale_factor`
- `autovacuum_vacuum_cost_limit`, `autovacuum_vacuum_cost_delay`

**Background writer:**
- `bgwriter_delay`, `bgwriter_lru_maxpages`

**Connections:**
- `max_connections`

### Predefined Reduced Knob Sets (Fallback)

**OLTP (8 knobs):**
```elixir
[:shared_buffers, :work_mem, :effective_cache_size, :random_page_cost,
 :checkpoint_completion_target, :max_wal_size, :autovacuum_vacuum_cost_limit,
 :bgwriter_lru_maxpages]
```

**OLAP (9 knobs):**
```elixir
[:shared_buffers, :work_mem, :maintenance_work_mem, :effective_cache_size,
 :max_parallel_workers_per_gather, :max_parallel_workers, :parallel_tuple_cost,
 :default_statistics_target, :random_page_cost]
```

**Mixed (8 knobs):**
```elixir
[:shared_buffers, :work_mem, :effective_cache_size, :random_page_cost,
 :max_parallel_workers_per_gather, :checkpoint_completion_target,
 :autovacuum_vacuum_scale_factor, :max_wal_size]
```

## Workload Fingerprinting

### Feature Vector (15 dimensions)

Computed from `pg_stat_statements`, `pg_stat_user_tables`, `pg_stat_database`:

- `read_write_ratio` - SELECT / (INSERT + UPDATE + DELETE)
- `avg_query_time_ms`, `p99_query_time_ms`
- `sequential_scan_ratio`, `index_scan_ratio`
- `avg_rows_per_query`
- `join_ratio`, `aggregation_ratio`
- `insert_ratio`, `update_ratio`, `delete_ratio`
- `temp_files_ratio`
- `cache_hit_ratio`
- `transactions_per_sec`
- `avg_transaction_size`

### Classification

```elixir
cond do
  read_write_ratio > 5 and avg_query_time_ms < 10 and cache_hit_ratio > 0.95 ->
    :oltp
  read_write_ratio < 2 and avg_query_time_ms > 100 and aggregation_ratio > 0.3 ->
    :olap
  true ->
    :mixed
end
```

## File Structure

```
lib/
├── pg_ga_conf.ex                          # Public API
├── pg_ga_conf/
│   ├── application.ex                     # Supervisor tree
│   ├── orchestrator.ex                    # Coordinates tuning workflow
│   ├── tuning_job.ex                      # GenServer for single session
│   │
│   ├── optimizer.ex                       # Behaviour definition
│   ├── optimizer/
│   │   ├── ga.ex                          # Genetic Algorithm (existing)
│   │   ├── tpe.ex                         # TPE via Pythonx
│   │   ├── cma_es.ex                      # CMA-ES via Pythonx
│   │   └── utils.ex                       # Encoding/decoding helpers
│   │
│   ├── knob_space.ex                      # Knob definitions and types
│   ├── fingerprint.ex                     # Workload fingerprinting
│   ├── sobol.ex                           # Sobol analysis orchestration
│   │
│   ├── benchmark.ex                       # Behaviour definition
│   ├── benchmark/
│   │   └── pgbench.ex                     # Default pgbench implementation
│   │
│   ├── config.ex                          # Config application helpers
│   ├── result_store.ex                    # Ecto queries
│   ├── migrations.ex                      # Migration helpers
│   │
│   ├── schema/
│   │   ├── observation.ex
│   │   ├── session.ex
│   │   └── sobol_cache.ex
│   │
│   ├── julia.ex                           # Resilient Julia client
│   ├── julia/
│   │   ├── client.ex                      # Behaviour
│   │   ├── local_backend.ex               # erlexec implementation
│   │   └── tcp_backend.ex                 # TCP implementation
│   │
│   ├── session_recovery.ex                # Auto-resume on startup
│   └── telemetry.ex                       # Telemetry events

priv/
├── julia/
│   ├── Project.toml                       # Julia dependencies
│   ├── Manifest.toml
│   ├── sensitivity.jl                     # Sobol analysis functions
│   └── server.jl                          # JSON server (TCP mode)

config/
├── config.exs
├── dev.exs
├── test.exs
└── prod.exs

# Docker
docker/
├── elixir/
│   └── Dockerfile                         # Nix-based Elixir image
└── julia/
    └── Dockerfile                         # Julia image

# Nix
flake.nix                                  # Dev shell + package definitions
```

## Database Schema

### pg_ga_conf_observations

```sql
CREATE TABLE pg_ga_conf_observations (
  id BIGSERIAL PRIMARY KEY,
  db_id VARCHAR NOT NULL,
  config JSONB NOT NULL,
  score DOUBLE PRECISION NOT NULL,
  metrics JSONB,
  workload_cluster VARCHAR NOT NULL,
  fingerprint_vector DOUBLE PRECISION[],
  inserted_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE INDEX idx_observations_cluster ON pg_ga_conf_observations(workload_cluster);
CREATE INDEX idx_observations_db_id ON pg_ga_conf_observations(db_id);
```

### pg_ga_conf_sessions

```sql
CREATE TABLE pg_ga_conf_sessions (
  id BIGSERIAL PRIMARY KEY,
  db_id VARCHAR NOT NULL,
  optimizer VARCHAR NOT NULL,
  status VARCHAR DEFAULT 'initializing',

  -- Checkpoint data
  optimizer_state BYTEA,
  current_iteration INTEGER DEFAULT 0,
  max_iterations INTEGER,
  knobs_used VARCHAR[],

  -- Results
  best_config JSONB,
  best_score DOUBLE PRECISION,
  initial_score DOUBLE PRECISION,
  improvement_pct DOUBLE PRECISION,
  history JSONB[],

  -- Error tracking
  last_error TEXT,
  error_count INTEGER DEFAULT 0,
  consecutive_errors INTEGER DEFAULT 0,

  -- Metadata
  workload_cluster VARCHAR,
  fingerprint_vector DOUBLE PRECISION[],

  inserted_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE INDEX idx_sessions_db_id ON pg_ga_conf_sessions(db_id);
CREATE INDEX idx_sessions_status ON pg_ga_conf_sessions(status);
```

### pg_ga_conf_sobol_cache

```sql
CREATE TABLE pg_ga_conf_sobol_cache (
  id BIGSERIAL PRIMARY KEY,
  fingerprint_cluster VARCHAR NOT NULL,
  fingerprint_vector DOUBLE PRECISION[],
  knob_rankings JSONB[],
  top_knobs VARCHAR[],
  samples_used INTEGER,
  analysis_duration_ms INTEGER,
  inserted_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE INDEX idx_sobol_cache_cluster ON pg_ga_conf_sobol_cache(fingerprint_cluster);
```

## Configuration

```elixir
# config/config.exs
config :pg_ga_conf,
  repo: MyApp.Repo,

  # Default tuning parameters
  default_optimizer: :tpe,
  max_iterations: 30,

  # Benchmark defaults
  benchmark_duration: 60,
  benchmark_clients: 10,
  warmup_duration: 10,

  # Sobol defaults
  sobol_samples: 128,
  sobol_cache_ttl: :timer.hours(24 * 30),

  # Error handling
  max_consecutive_errors: 3,
  error_backoff_ms: 5_000,

  # Julia connection
  julia_mode: :auto,  # :auto, :local, :tcp
  julia_host: "localhost",
  julia_port: 9999,
  julia_health_check_interval: 30_000

# config/dev.exs
config :pg_ga_conf,
  julia_mode: :local,
  max_iterations: 10,
  sobol_samples: 64

# config/prod.exs
config :pg_ga_conf,
  julia_mode: :tcp,
  julia_host: System.get_env("JULIA_SERVICE_HOST", "localhost"),
  julia_port: String.to_integer(System.get_env("JULIA_SERVICE_PORT", "9999"))
```

## Telemetry Events

```elixir
# Tuning lifecycle
[:pg_ga_conf, :tuning, :start]       # %{session_id, optimizer, db_id}
[:pg_ga_conf, :tuning, :iteration]   # %{session_id, iteration, config, score}
[:pg_ga_conf, :tuning, :complete]    # %{session_id, best_score, improvement_pct}
[:pg_ga_conf, :tuning, :error]       # %{session_id, error, recoverable}

# Benchmark
[:pg_ga_conf, :benchmark, :start]    # %{config}
[:pg_ga_conf, :benchmark, :complete] # %{metrics, duration_ms}

# Sobol analysis
[:pg_ga_conf, :sobol, :start]        # %{samples, knob_count}
[:pg_ga_conf, :sobol, :complete]     # %{duration_ms, top_knobs}
[:pg_ga_conf, :sobol, :cache_hit]    # %{cluster}

# Julia communication
[:pg_ga_conf, :julia, :request]      # %{type}
[:pg_ga_conf, :julia, :response]     # %{type, duration_ms}
[:pg_ga_conf, :julia, :reconnect]    # %{attempt}
```

## Implementation Order

### Phase 1: Core Infrastructure
- [ ] Nix flake with Julia support
- [ ] Application supervisor tree
- [ ] Ecto migrations and schemas
- [ ] KnobSpace with full and reduced definitions
- [ ] Configuration module

### Phase 2: Julia Integration
- [ ] Julia server script (priv/julia/server.jl)
- [ ] Sobol analysis functions (priv/julia/sensitivity.jl)
- [ ] Julia client behaviour
- [ ] Local backend (erlexec)
- [ ] TCP backend
- [ ] Resilient client wrapper

### Phase 3: Optimizer Behaviour and GA
- [ ] Optimizer behaviour definition
- [ ] Refactor existing GA to implement behaviour
- [ ] Add serialize/deserialize to GA
- [ ] Utils for knob encoding/decoding

### Phase 4: Pythonx Optimizers
- [ ] Pythonx initialization
- [ ] TPE optimizer
- [ ] CMA-ES optimizer with categorical encoding
- [ ] Warm-start support

### Phase 5: Workload Analysis
- [ ] Fingerprint computation from pg_stat views
- [ ] Workload classification
- [ ] Similarity/distance functions
- [ ] Sobol orchestration with caching

### Phase 6: Benchmark System
- [ ] Benchmark behaviour
- [ ] pgbench implementation
- [ ] Config formatting and application

### Phase 7: Tuning Job and Orchestrator
- [ ] TuningJob GenServer with checkpointing
- [ ] Error handling and recovery
- [ ] Session recovery on startup
- [ ] Orchestrator coordinating full pipeline

### Phase 8: Public API and Polish
- [ ] Public API module
- [ ] Result store queries
- [ ] Telemetry events
- [ ] Documentation

### Phase 9: Docker and K8s
- [ ] Julia Dockerfile
- [ ] Elixir Dockerfile (Nix-based)
- [ ] K8s deployment manifests
- [ ] Integration testing

## Usage Examples

### Basic Usage

```elixir
# Connect to database
{:ok, conn} = Postgrex.start_link(
  hostname: "localhost",
  database: "myapp_prod",
  username: "postgres",
  password: "secret"
)

# Run optimization with defaults (TPE, 30 iterations)
{:ok, result} = PgGaConf.optimize(conn)

IO.puts("Best config: #{inspect(result.best_config)}")
IO.puts("Improved p99 latency by #{result.improvement_pct}%")
```

### Choosing an Optimizer

```elixir
# Low budget - use TPE (most sample efficient)
{:ok, result} = PgGaConf.optimize(conn, optimizer: :tpe, max_iterations: 20)

# Want to explore diverse configurations - use GA
{:ok, result} = PgGaConf.optimize(conn, optimizer: :ga, max_iterations: 50)

# Continuous knobs, expect correlations - use CMA-ES
{:ok, result} = PgGaConf.optimize(conn, optimizer: :cma_es, max_iterations: 40)

# Let the system recommend
{:ok, fp} = PgGaConf.fingerprint(conn)
{:ok, knobs} = PgGaConf.analyze_sensitivity(conn, fp)
optimizer = PgGaConf.recommend_optimizer(knobs, budget: 30)
{:ok, result} = PgGaConf.run_optimizer(conn, knobs, optimizer: optimizer)
```

### Custom Benchmark

```elixir
defmodule MyApp.Benchmark.ProductionQueries do
  @behaviour PgGaConf.Benchmark

  @impl true
  def run(db_conn, config, opts) do
    queries = opts[:queries] || load_from_pg_stat_statements(db_conn)

    with :ok <- PgGaConf.Config.apply(db_conn, config) do
      metrics = replay_queries(db_conn, queries, opts)
      {:ok, metrics}
    end
  end

  @impl true
  def score(metrics) do
    # Custom scoring: 70% p99, 30% throughput
    metrics.p99_latency_ms * 0.7 + (1000 / metrics.tps) * 0.3
  end
end

# Use custom benchmark
{:ok, result} = PgGaConf.optimize(conn,
  benchmark: MyApp.Benchmark.ProductionQueries,
  benchmark_opts: [duration: 120]
)
```

### Async with Progress Monitoring

```elixir
# Start async
{:ok, session_id} = PgGaConf.optimize_async(conn, optimizer: :cma_es)

# Poll for progress
Stream.interval(10_000)
|> Stream.each(fn _ ->
  case PgGaConf.get_status(session_id) do
    {:ok, %{status: :running, current_iteration: i, max_iterations: max, best_score: score}} ->
      IO.puts("Progress: #{i}/#{max}, best p99: #{score}ms")

    {:ok, %{status: :completed, improvement_pct: pct}} ->
      IO.puts("Done! Improved by #{pct}%")

    {:ok, %{status: :failed, last_error: error}} ->
      IO.puts("Failed: #{error}")
  end
end)
|> Stream.run()
```

### Transfer Learning

```elixir
# First database - full analysis
{:ok, result1} = PgGaConf.optimize(staging_conn,
  knob_discovery: :force,  # Run fresh Sobol analysis
  sobol_samples: 256
)

# Second similar database - uses cached Sobol results
{:ok, result2} = PgGaConf.optimize(production_conn,
  knob_discovery: :auto  # Will hit cache if fingerprint similar
)

# Warm-start from historical observations
{:ok, fp} = PgGaConf.fingerprint(new_conn)
similar_obs = PgGaConf.ResultStore.find_similar_observations(fp, :oltp, limit: 20)

{:ok, state} = PgGaConf.Optimizer.TPE.init(knob_space, [])
{:ok, state} = PgGaConf.Optimizer.TPE.warm_start(state, similar_obs)
# Now TPE starts with prior knowledge
```

## Open Questions

1. **pgvector for similarity search?** - Currently using simple filtering by cluster. For large observation sets, pgvector would enable efficient vector similarity search.

2. **Multi-objective optimization?** - Current design optimizes single metric (p99 latency). Could extend to Pareto optimization of latency vs throughput vs resource usage.

3. **Continuous tuning mode?** - Detect workload drift and automatically re-tune. Would require background monitoring.

4. **Query-aware workload generation?** - Instead of pgbench, replay actual query patterns captured from pg_stat_statements.

---

## Approval

- [ ] Architecture approved
- [ ] API design approved
- [ ] Deployment strategy approved
- [ ] Ready for implementation

**Notes:**

