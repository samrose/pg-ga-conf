# Workload Pattern Classifier

This document describes the Workload Pattern Discovery System - an empirical approach to PostgreSQL workload classification and configuration knob selection.

## Overview

The system **automatically discovers workload patterns** across PostgreSQL databases, validates which configuration knobs matter for each pattern via Sobol sensitivity analysis, and reuses those validated knob sets for databases with similar profiles. This replaces hardcoded archetypes with empirically discovered patterns.

### Key Principles

1. **Measure, don't assume** - Knob importance is validated by Sobol analysis, not domain expertise
2. **Rich profiling** - 59 features across 7 dimensions capture true workload nature
3. **Continuous learning** - New patterns emerge as more databases are profiled
4. **Efficient reuse** - Similar databases share validated knob sets

---

## Architecture

```
Database → RichProfiler → PatternDiscovery → PatternValidation → PatternMatcher
             (59 features)    (DBSCAN)         (Sobol)           (at tuning time)
```

### Components

| Component | File | Purpose |
|-----------|------|---------|
| **RichProfiler** | `lib/pg_ga_conf/workload/rich_profiler.ex` | Extracts 59 features across 7 layers |
| **PatternDiscovery** | `lib/pg_ga_conf/pattern_discovery.ex` | DBSCAN clustering of profiles |
| **PatternValidation** | `lib/pg_ga_conf/pattern_validation.ex` | Sobol-based knob validation per pattern |
| **PatternMatcher** | `lib/pg_ga_conf/pattern_matcher.ex` | Matches databases to patterns at tuning time |
| **PatternMaintenance** | `lib/pg_ga_conf/pattern_maintenance.ex` | Drift detection and reassignment |
| **WorkloadPattern** | `lib/pg_ga_conf/schema/workload_pattern.ex` | Ecto schema for patterns |
| **PatternAssignment** | `lib/pg_ga_conf/schema/pattern_assignment.ex` | Ecto schema for DB-to-pattern mapping |

### Data Flow

1. **Profile** databases with `RichProfiler` → 59-element feature vectors
2. **Cluster** profiles with DBSCAN → discover natural workload patterns
3. **Validate** each pattern with Sobol → determine which knobs actually matter
4. **Match** new databases to validated patterns → skip per-database Sobol

---

## How It Works at Tuning Time

```elixir
case PatternMatcher.get_knobs_for_database(db_id, profile_repo, pattern_repo) do
  {:ok, %{knobs: knobs, source: :pattern_match}} ->
    # Use these knobs for optimization (Sobol already done for pattern)
    optimize_with(knobs)

  {:needs_validation, _reason} ->
    # No good pattern match, run Sobol directly for this database
    PatternMatcher.handle_no_match(db_id, repo, benchmark_opts)
end
```

| Scenario | Sobol Runs | Cost |
|----------|------------|------|
| Pattern match (similarity ≥ 0.85) | 0 | Reuses pattern's validation |
| No match | 1 | Saved as custom validation |

The efficiency gain scales with fleet size - validate once per pattern, reuse for hundreds of similar databases.

---

## Key Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| DBSCAN `eps` | 0.20 | Max cosine distance for neighbors |
| DBSCAN `min_samples` | 15 | Min points to form a cluster |
| Similarity threshold | 0.85 | For pattern matching |
| Drift threshold | 0.15 | Triggers reassignment |
| Sobol ST threshold | 0.05 | Knob importance cutoff |
| Starter knobs | 16 | Initial set for Sobol validation |

### Starter Knob Set (16 knobs for validation)

```elixir
@starter_knobs [
  # Memory
  :shared_buffers, :work_mem, :effective_cache_size,
  :maintenance_work_mem, :hash_mem_multiplier,

  # Planner
  :random_page_cost, :effective_io_concurrency, :default_statistics_target,

  # Checkpointing
  :checkpoint_completion_target, :max_wal_size,

  # Parallelism
  :max_parallel_workers_per_gather, :max_parallel_workers,

  # Autovacuum
  :autovacuum_vacuum_cost_limit, :autovacuum_vacuum_scale_factor,

  # WAL
  :wal_buffers, :synchronous_commit
]
```

---

## Comparison to Old Classifier

The old `Classifier` (`lib/pg_ga_conf/workload/classifier.ex`) uses **hardcoded rules** to classify into 8 archetypes:

- `:high_concurrency_oltp`
- `:read_heavy_oltp`
- `:write_heavy_oltp`
- `:update_heavy_oltp`
- `:analytical`
- `:mixed_htap`
- `:batch_etl`
- `:idle_or_unknown`

Each archetype maps to predetermined knob sets based on domain expertise.

**The new system differs by:**

1. **Discovering patterns empirically** from actual database profiles
2. **Validating knob importance via Sobol analysis** rather than assuming
3. **Continuously learning** as new databases are profiled
4. **Handling nuanced workloads** that don't fit neat categories

---

## The 59 Features

The RichProfiler extracts **59 normalized features** to create a workload "fingerprint". These features are grouped into **7 layers**, each capturing a different dimension of database behavior.

### Why 59 Features?

Traditional classification uses simple heuristics like "mostly SELECTs = OLTP". But real workloads are nuanced:

- Read-heavy BUT with complex joins → needs `work_mem`
- Small scale BUT high concurrency → needs connection tuning
- Insert-heavy BUT with JSONB columns → needs GIN index awareness

59 features capture these nuances for accurate pattern matching.

---

### Layer 1: Schema Structure (10 features)

*What does the database schema look like?*

| # | Feature | What it measures |
|---|---------|------------------|
| 1 | `table_count` | Number of tables (log normalized) |
| 2 | `avg_columns` | Average columns per table |
| 3 | `jsonb_ratio` | % of columns that are JSONB |
| 4 | `array_ratio` | % of columns that are arrays |
| 5 | `text_ratio` | % of columns that are text/varchar |
| 6 | `timeseries_ratio` | % of tables with timestamp columns |
| 7 | `partitioned_ratio` | % of tables that are partitioned |
| 8 | `gin_index_ratio` | % of indexes using GIN |
| 9 | `gist_index_ratio` | % of indexes using GiST |
| 10 | `fk_density` | Foreign keys per table |

**Data sources:** `pg_class`, `pg_attribute`, `pg_type`, `pg_index`, `pg_am`, `pg_constraint`

**Tuning relevance:**
- JSONB-heavy → GIN index tuning
- Partitioned → parallel workers
- Wide tables → `shared_buffers`

---

### Layer 2: Query Patterns (15 features)

*What kinds of queries run most often?*

| # | Feature | What it measures |
|---|---------|------------------|
| 11 | `select_ratio` | % of queries that are SELECTs |
| 12 | `insert_ratio` | % that are INSERTs |
| 13 | `update_ratio` | % that are UPDATEs |
| 14 | `delete_ratio` | % that are DELETEs |
| 15 | `join_ratio` | % with JOINs |
| 16 | `aggregate_ratio` | % with GROUP BY/HAVING |
| 17 | `window_ratio` | % with window functions |
| 18 | `cte_ratio` | % with CTEs |
| 19 | `json_ratio` | % with JSON operators |
| 20 | `parameterized_ratio` | % using prepared statements |
| 21 | `query_diversity` | Distinct queries / total calls |
| 22 | `hot_concentration` | % of calls from top 10 queries |
| 23 | `avg_rows_per_call` | Average rows returned |
| 24 | `cache_hit_ratio` | Buffer cache effectiveness |
| 25 | `temp_spill_ratio` | % of queries spilling to disk |

**Data source:** `pg_stat_statements` (falls back to defaults if unavailable)

**Tuning relevance:**
- High `join_ratio` + `temp_spill_ratio` → increase `work_mem`
- High `insert_ratio` → WAL tuning
- High `parameterized_ratio` → plan cache effectiveness

---

### Layer 3: Execution Characteristics (8 features)

*How do queries actually execute?*

| # | Feature | What it measures |
|---|---------|------------------|
| 26 | `planning_overhead` | Plan time / execution time |
| 27 | `exec_time_cv` | Execution time variability |
| 28 | `wal_bytes_per_call` | WAL generated per query |
| 29 | `jit_ratio` | % of queries using JIT |
| 30 | `blk_read_time_ratio` | Time spent reading blocks |
| 31 | `fpi_ratio` | Full page images in WAL |
| 32 | `wal_buffer_pressure` | WAL buffer full events |
| 33 | `function_time_ratio` | Time in stored procedures |

**Data sources:** `pg_stat_statements`, `pg_stat_wal` (PG14+), `pg_stat_user_functions`

**Version-aware:** WAL stats require PG13+, JIT stats require PG15+

**Tuning relevance:**
- High `wal_buffer_pressure` → increase `wal_buffers`
- High `jit_ratio` → tune JIT thresholds
- High `planning_overhead` → `plan_cache_mode`

---

### Layer 4: I/O Patterns (6 features)

*How does the database interact with storage?*

| # | Feature | What it measures |
|---|---------|------------------|
| 34 | `autovacuum_io_ratio` | I/O from autovacuum |
| 35 | `checkpoint_write_ratio` | Writes from checkpointer |
| 36 | `bulkread_ratio` | Sequential scan I/O |
| 37 | `extend_ratio` | Table extension I/O |
| 38 | `buffer_reuse_ratio` | Buffer reuse vs eviction |
| 39 | `toast_ratio` | TOAST table access |

**Data sources:** `pg_stat_io` (PG16+), falls back to `pg_stat_bgwriter`

**Tuning relevance:**
- High `autovacuum_io_ratio` → tune autovacuum cost limits
- High `bulkread_ratio` → increase `effective_io_concurrency`
- Low `buffer_reuse_ratio` → increase `shared_buffers`

---

### Layer 5: Index Effectiveness (4 features)

*How well are indexes being used?*

| # | Feature | What it measures |
|---|---------|------------------|
| 40 | `unused_index_ratio` | % of indexes never scanned |
| 41 | `index_selectivity` | Rows fetched / rows read |
| 42 | `index_hot_concentration` | Top 5 indexes / all scans |
| 43 | `index_size_ratio` | Index size / table size |

**Data source:** `pg_stat_user_indexes`, `pg_class`

**Tuning relevance:**
- Low `index_selectivity` → `random_page_cost` tuning
- High `unused_index_ratio` → maintenance overhead
- High `index_hot_concentration` → hot path optimization

---

### Layer 6: Runtime Behavior (10 features)

*What happens under load over time?*

| # | Feature | What it measures |
|---|---------|------------------|
| 44 | `qps_mean` | Queries per second (average) |
| 45 | `qps_cv` | QPS variability (burstiness) |
| 46 | `connections_mean` | Average active connections |
| 47 | `connections_cv` | Connection count variability |
| 48 | `active_ratio` | % of connections actually active |
| 49 | `wait_io_ratio` | % waiting on I/O |
| 50 | `wait_lock_ratio` | % waiting on locks |
| 51 | `wait_lwlock_ratio` | % waiting on LWLocks |
| 52 | `wait_client_ratio` | % waiting on client |
| 53 | `lock_wait_ratio` | Overall lock contention |

**Data sources:** `pg_stat_activity`, `pg_stat_database`, `pg_locks`

**Time-sampled:** Takes multiple snapshots over configurable window (default: 12 samples over 60 seconds)

**Tuning relevance:**
- High `wait_lock_ratio` → connection pooling
- High `connections_mean` with low `active_ratio` → connection limits
- High `wait_io_ratio` → I/O tuning

---

### Layer 7: Scale Metrics (6 features)

*How big is this database?*

| # | Feature | What it measures |
|---|---------|------------------|
| 54 | `db_size_gb` | Total database size |
| 55 | `largest_table_gb` | Size of largest table |
| 56 | `total_index_gb` | Total index size |
| 57 | `table_count` | Number of tables |
| 58 | `estimated_rows` | Total estimated rows |
| 59 | `avg_row_width` | Average row size |

**Data sources:** `pg_database_size()`, `pg_class`, `pg_stats`

**Tuning relevance:**
- Large `db_size_gb` → `shared_buffers`, `effective_cache_size`
- Large `largest_table_gb` → parallelism settings
- High `estimated_rows` → autovacuum thresholds

---

## Normalization

All 59 features are normalized to **[0, 1]** range for fair comparison in cosine similarity:

```elixir
# Ratios: direct (already 0-1)
schema.jsonb_ratio

# Counts: log-normalized against expected max
normalize_log(schema.table_count, 1000)  # → log(x+1)/log(max+1)

# Variance: capped and scaled
min(runtime.qps_cv, 2.0) / 2  # CV rarely exceeds 2
```

---

## Usage

### Profiling a Database

```elixir
# Full profile with time sampling (60 seconds)
{:ok, profile} = RichProfiler.profile(Repo)
profile.feature_vector  # [0.23, 0.45, 0.0, ...] - 59 floats

# Quick profile (no time sampling)
{:ok, profile} = RichProfiler.quick_profile(Repo)

# Just the vector
{:ok, vector} = RichProfiler.feature_vector(Repo)
```

### Discovering Patterns

```elixir
# Discover patterns from all stored profiles
{:ok, result} = PatternDiscovery.discover_patterns(Repo)
result.patterns   # List of WorkloadPattern structs
result.outliers   # Databases that didn't fit any cluster
```

### Pattern Matching

```elixir
# Get knobs for a database at tuning time
case PatternMatcher.get_knobs_for_database(db_id, profile_repo, pattern_repo) do
  {:ok, %{knobs: knobs, source: :pattern_match, similarity: sim}} ->
    IO.puts("Matched with #{sim} similarity, using: #{inspect(knobs)}")

  {:needs_validation, %{reason: reason}} ->
    IO.puts("No match: #{reason}")
end
```

### Maintenance

```elixir
# Check for drifted databases
{:ok, %{drifted: drifted}} = PatternMaintenance.check_drift(Repo)

# Run full maintenance cycle
{:ok, result} = PatternMaintenance.run_maintenance(Repo)

# Get system stats
stats = PatternMaintenance.get_stats(Repo)
```

---

## PostgreSQL Version Compatibility

The profiler degrades gracefully on older PostgreSQL versions:

| Feature Layer | Minimum PG Version | Fallback |
|---------------|-------------------|----------|
| Schema (1) | Any | Full support |
| Query Patterns (2) | Any + pg_stat_statements | Defaults if extension missing |
| Execution (3) | PG13+ for WAL, PG15+ for JIT | Partial metrics |
| I/O Patterns (4) | PG16+ for full detail | Uses pg_stat_bgwriter |
| Index (5) | Any | Full support |
| Runtime (6) | Any | Full support |
| Scale (7) | Any | Full support |

---

## Demo

Run the demo to see the system in action:

```bash
mix pattern_demo        # Run demo
mix pattern_demo --clean  # Reset and re-run
```

This will:
1. Profile the current database
2. Create simulated fleet profiles
3. Run DBSCAN pattern discovery
4. Demonstrate pattern matching
5. Show maintenance stats
