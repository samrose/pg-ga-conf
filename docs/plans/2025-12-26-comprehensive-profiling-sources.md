# Comprehensive PostgreSQL Workload Profiling

## All Available Data Sources

This document catalogs every source of workload intelligence available in PostgreSQL and how to use each one for accurate pattern discovery.

---

## Part 1: Complete Inventory of PostgreSQL Statistics

### Currently Using (in Workload.Profiler)

| Source | What We Extract | Accuracy |
|--------|-----------------|----------|
| `pg_stat_statements` | Query counts, timing, rows, temp usage | Good for query patterns |
| `pg_stat_user_tables` | Seq/idx scans, tuple operations | Good for access patterns |
| `pg_stat_activity` | Connection states, wait events (sampled) | Snapshot only |
| `pg_stat_bgwriter` | Checkpoint pressure, buffer writes | Good |
| `pg_stat_database` | Transaction counts, block I/O | Cumulative only |

### Not Using (Should Add)

| Source | What It Provides | Why It Matters |
|--------|------------------|----------------|
| `pg_stat_io` (v16+) | I/O by backend type, object, context | Most granular I/O insight |
| `pg_stat_wal` (v14+) | WAL generation rate, sync stats | Write-heavy workload detection |
| `pg_stat_checkpointer` (v14+) | Checkpoint timing details | Checkpoint tuning needs |
| `pg_stat_user_indexes` | Per-index scan counts | Index effectiveness |
| `pg_statio_user_tables` | Heap/index/toast block hits/reads | Cache effectiveness per table |
| `pg_stat_user_functions` | Function execution stats | Stored procedure workloads |
| `pg_stat_slru` | SLRU cache stats | Transaction ID wraparound risk |
| `pg_locks` | Current lock state | Contention patterns |
| `pg_class` + `pg_attribute` | Schema structure | Table shapes, types |
| `pg_index` | Index definitions | Index types, expressions |
| `pg_stats` | Column statistics | Data distribution |
| Query plan analysis | Access methods, costs | True query behavior |

---

## Part 2: Deep Dive on Each Source

### 2.1 pg_stat_statements (The Gold Mine)

This is the single most valuable source. Every query that runs is tracked.

**Full column inventory**:

```sql
SELECT
    -- Identity
    userid, dbid, toplevel, queryid, query,

    -- Execution counts
    calls,                    -- How many times executed

    -- Planning (PG 13+)
    plans,                    -- How many times planned (can differ from calls if prepared)
    total_plan_time,          -- Cumulative planning time (ms)
    min_plan_time, max_plan_time, mean_plan_time, stddev_plan_time,

    -- Execution timing
    total_exec_time,          -- Cumulative execution time (ms)
    min_exec_time, max_exec_time, mean_exec_time, stddev_exec_time,

    -- Row counts
    rows,                     -- Total rows returned/affected

    -- Shared buffer access
    shared_blks_hit,          -- Blocks found in buffer cache
    shared_blks_read,         -- Blocks read from disk
    shared_blks_dirtied,      -- Blocks dirtied by this query
    shared_blks_written,      -- Blocks written by this query

    -- Local buffer access (temp tables)
    local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written,

    -- Temp file access (spilling to disk)
    temp_blks_read,           -- Temp blocks read (sorting/hashing spilled)
    temp_blks_written,        -- Temp blocks written

    -- I/O timing (if track_io_timing = on)
    blk_read_time,            -- Time spent reading blocks (ms)
    blk_write_time,           -- Time spent writing blocks (ms)
    temp_blk_read_time,       -- Time reading temp blocks (PG 15+)
    temp_blk_write_time,      -- Time writing temp blocks (PG 15+)

    -- WAL (PG 13+)
    wal_records,              -- WAL records generated
    wal_fpi,                  -- WAL full page images generated
    wal_bytes,                -- WAL bytes generated

    -- JIT (PG 15+)
    jit_functions,            -- Functions JIT compiled
    jit_generation_time,      -- JIT code generation time (ms)
    jit_inlining_count,       -- Functions inlined
    jit_inlining_time,        -- Inlining time (ms)
    jit_optimization_count,   -- Functions optimized
    jit_optimization_time,    -- Optimization time (ms)
    jit_emission_count,       -- Functions emitted
    jit_emission_time         -- Emission time (ms)
FROM pg_stat_statements;
```

**What we can extract**:

| Feature | Calculation | What It Reveals |
|---------|-------------|-----------------|
| `planning_overhead_ratio` | `total_plan_time / total_exec_time` | Complex queries that re-plan often |
| `plan_to_exec_ratio` | `plans / calls` | Prepared statement usage (ratio < 1 = cached plans) |
| `rows_per_call` | `rows / calls` | OLTP (small) vs OLAP (large) |
| `cache_hit_ratio` | `shared_blks_hit / (hit + read)` | Buffer cache effectiveness |
| `temp_spill_ratio` | `queries with temp > 0 / total` | Work_mem pressure |
| `wal_bytes_per_call` | `wal_bytes / calls` | Write amplification |
| `jit_usage_ratio` | `queries with jit > 0 / total` | Complex query prevalence |
| `query_time_variance` | `stddev_exec_time / mean_exec_time` | Consistency (low = predictable) |
| `block_read_time_ratio` | `blk_read_time / total_exec_time` | I/O bound queries |

**Query classification from text**:

```sql
-- More sophisticated than simple regex
WITH query_analysis AS (
    SELECT
        queryid,
        calls,
        query,

        -- Query type
        CASE
            WHEN query ~* '^\s*SELECT' THEN 'select'
            WHEN query ~* '^\s*INSERT' THEN 'insert'
            WHEN query ~* '^\s*UPDATE' THEN 'update'
            WHEN query ~* '^\s*DELETE' THEN 'delete'
            WHEN query ~* '^\s*WITH' THEN 'cte'
            ELSE 'other'
        END AS query_type,

        -- Complexity indicators
        (length(query) - length(replace(lower(query), ' join ', ''))) / 6 AS join_count,
        query ~* '\bGROUP BY\b' AS has_group_by,
        query ~* '\bORDER BY\b' AS has_order_by,
        query ~* '\bDISTINCT\b' AS has_distinct,
        query ~* '\bUNION\b' AS has_union,
        query ~* '\bEXCEPT\b|\bINTERSECT\b' AS has_set_ops,
        query ~* '\bLIMIT\b' AS has_limit,
        query ~* '\bOFFSET\b' AS has_offset,
        query ~* 'OVER\s*\(' AS has_window_function,
        query ~* '\bFOR UPDATE\b|\bFOR SHARE\b' AS has_row_locking,
        query ~* '\bRECURSIVE\b' AS has_recursive_cte,
        query ~* '\bLATERAL\b' AS has_lateral,
        query ~* '\bARRAY\[' OR query ~* '\bARRAY_AGG\b' AS uses_arrays,
        query ~* '->>' OR query ~* '@>' OR query ~* '\bjsonb?\b' AS uses_json,

        -- Parameterization (normalized queries use $1, $2, etc.)
        query ~ '\$[0-9]+' AS is_parameterized,

        -- Table count estimate (rough)
        array_length(regexp_matches(query, '\bFROM\b|\bJOIN\b', 'gi'), 1) AS table_references

    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
)
SELECT
    -- Aggregated complexity metrics
    SUM(calls) FILTER (WHERE join_count >= 2) / SUM(calls)::float AS multi_join_ratio,
    SUM(calls) FILTER (WHERE has_window_function) / SUM(calls)::float AS window_fn_ratio,
    SUM(calls) FILTER (WHERE uses_json) / SUM(calls)::float AS json_usage_ratio,
    SUM(calls) FILTER (WHERE has_recursive_cte) / SUM(calls)::float AS recursive_cte_ratio,
    SUM(calls) FILTER (WHERE has_row_locking) / SUM(calls)::float AS row_locking_ratio,
    SUM(calls) FILTER (WHERE is_parameterized) / SUM(calls)::float AS parameterized_ratio,
    AVG(join_count) AS avg_joins_per_query
FROM query_analysis;
```


### 2.2 pg_stat_io (PostgreSQL 16+)

The most granular I/O statistics available. Breaks down I/O by:
- Backend type (client, autovacuum, checkpointer, etc.)
- Object type (relation, temp)
- Context (normal, vacuum, bulkread, bulkwrite)

```sql
SELECT
    backend_type,
    object,
    context,
    reads,        -- Number of read operations
    read_time,    -- Time spent reading (ms) - requires track_io_timing
    writes,       -- Number of write operations
    write_time,   -- Time spent writing (ms)
    writebacks,   -- Writeback requests
    writeback_time,
    extends,      -- Number of relation extends
    extend_time,
    op_bytes,     -- Bytes per operation
    hits,         -- Buffer cache hits
    evictions,    -- Buffer evictions
    reuses,       -- Buffer reuses (avoiding eviction)
    fsyncs,       -- Fsync operations
    fsync_time    -- Time spent in fsync
FROM pg_stat_io;
```

**What we can extract**:

| Feature | Calculation | What It Reveals |
|---------|-------------|-----------------|
| `autovacuum_io_ratio` | Autovacuum I/O / Total I/O | Vacuum pressure |
| `checkpoint_write_ratio` | Checkpointer writes / Total writes | Checkpoint sizing |
| `bulkread_ratio` | Bulkread context / Total reads | Sequential scan prevalence |
| `extend_ratio` | Extends / Total writes | Table growth rate |
| `buffer_reuse_ratio` | Reuses / (Reuses + Evictions) | Buffer pressure |


### 2.3 pg_stat_wal (PostgreSQL 14+)

WAL generation patterns reveal write characteristics.

```sql
SELECT
    wal_records,       -- Number of WAL records generated
    wal_fpi,           -- Full page images (after checkpoint)
    wal_bytes,         -- Total WAL bytes generated
    wal_buffers_full,  -- Times WAL buffers were full (contention indicator)
    wal_write,         -- Times WAL written to disk
    wal_sync,          -- Times WAL synced to disk
    wal_write_time,    -- Time spent writing WAL (ms)
    wal_sync_time,     -- Time spent syncing WAL (ms)
    stats_reset        -- When stats were last reset
FROM pg_stat_wal;
```

**What we can extract**:

| Feature | Calculation | What It Reveals |
|---------|-------------|-----------------|
| `wal_bytes_per_second` | `wal_bytes / seconds_since_reset` | Write rate |
| `fpi_ratio` | `wal_fpi / wal_records` | Checkpoint frequency impact |
| `wal_buffer_pressure` | `wal_buffers_full / wal_write` | wal_buffers sizing |
| `sync_time_ratio` | `wal_sync_time / (wal_write_time + wal_sync_time)` | Storage sync performance |


### 2.4 pg_stat_user_indexes

Which indexes are actually used?

```sql
SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,           -- Number of index scans
    idx_tup_read,       -- Index entries read
    idx_tup_fetch,      -- Heap tuples fetched via index
    last_idx_scan       -- Last time index was scanned (PG 16+)
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;
```

**What we can extract**:

| Feature | Calculation | What It Reveals |
|---------|-------------|-----------------|
| `unused_index_ratio` | Indexes with idx_scan = 0 / Total indexes | Index overhead |
| `idx_selectivity` | `idx_tup_fetch / idx_tup_read` | Index quality (1.0 = perfect) |
| `hot_index_concentration` | Top 5 indexes scans / Total scans | Hot path identification |


### 2.5 pg_statio_user_tables

Buffer cache effectiveness per table.

```sql
SELECT
    schemaname,
    relname,
    heap_blks_read,     -- Disk blocks read from heap
    heap_blks_hit,      -- Buffer cache hits for heap
    idx_blks_read,      -- Disk blocks read from indexes
    idx_blks_hit,       -- Buffer cache hits for indexes
    toast_blks_read,    -- TOAST table disk reads
    toast_blks_hit,     -- TOAST table cache hits
    tidx_blks_read,     -- TOAST index disk reads
    tidx_blks_hit       -- TOAST index cache hits
FROM pg_statio_user_tables;
```

**What we can extract**:

| Feature | Calculation | What It Reveals |
|---------|-------------|-----------------|
| `per_table_hit_ratio` | Per-table heap hits / (hits + reads) | Hot vs cold tables |
| `toast_usage_ratio` | `toast_blks / heap_blks` | Large value storage |
| `cold_table_ratio` | Tables with hit_ratio < 0.9 / Total | Working set size issues |


### 2.6 pg_stat_user_functions

Stored procedure usage patterns.

```sql
SELECT
    schemaname,
    funcname,
    calls,
    total_time,      -- Total time in function (ms)
    self_time        -- Time excluding called functions (ms)
FROM pg_stat_user_functions;
```

**What we can extract**:

| Feature | Calculation | What It Reveals |
|---------|-------------|-----------------|
| `function_workload_ratio` | Function time / Total query time | Procedural vs declarative |
| `function_diversity` | Distinct functions called / Total calls | Hot functions vs distributed |


### 2.7 pg_locks (Point-in-Time)

Current locking state reveals contention.

```sql
SELECT
    locktype,
    mode,
    granted,
    COUNT(*) AS count
FROM pg_locks
WHERE pid != pg_backend_pid()
GROUP BY locktype, mode, granted;

-- Lock waits
SELECT
    COUNT(*) FILTER (WHERE NOT granted) AS waiting_locks,
    COUNT(*) FILTER (WHERE granted) AS held_locks,
    COUNT(*) FILTER (WHERE locktype = 'relation') AS table_locks,
    COUNT(*) FILTER (WHERE locktype = 'tuple') AS row_locks,
    COUNT(*) FILTER (WHERE locktype = 'transactionid') AS xact_locks
FROM pg_locks
WHERE pid != pg_backend_pid();
```

**What we can extract** (with sampling):

| Feature | Calculation | What It Reveals |
|---------|-------------|-----------------|
| `lock_wait_ratio` | Samples with waiting locks / Total samples | Contention level |
| `row_lock_ratio` | Tuple locks / Total locks | Row-level contention |
| `table_lock_ratio` | Relation locks / Total locks | DDL or table-level locking |


### 2.8 Schema Structure Analysis

The schema itself reveals workload type.

```sql
-- Table structure analysis
WITH table_analysis AS (
    SELECT
        c.oid,
        c.relname,
        c.relkind,
        c.relpages,
        c.reltuples,
        (SELECT COUNT(*) FROM pg_attribute a
         WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS column_count,
        (SELECT COUNT(*) FROM pg_attribute a
         JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = c.oid AND t.typname = 'jsonb') AS jsonb_columns,
        (SELECT COUNT(*) FROM pg_attribute a
         JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = c.oid AND t.typname LIKE '%[]') AS array_columns,
        (SELECT COUNT(*) FROM pg_attribute a
         JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = c.oid AND t.typname IN ('text', 'varchar', 'char')) AS text_columns,
        (SELECT COUNT(*) FROM pg_attribute a
         JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = c.oid AND t.typname IN ('timestamp', 'timestamptz', 'date')) AS time_columns
    FROM pg_class c
    WHERE c.relkind IN ('r', 'p')
      AND c.relnamespace = 'public'::regnamespace
)
SELECT
    COUNT(*) AS table_count,
    AVG(column_count) AS avg_columns,
    MAX(column_count) AS max_columns,
    SUM(jsonb_columns) / NULLIF(SUM(column_count), 0)::float AS jsonb_ratio,
    SUM(array_columns) / NULLIF(SUM(column_count), 0)::float AS array_ratio,
    SUM(text_columns) / NULLIF(SUM(column_count), 0)::float AS text_ratio,
    COUNT(*) FILTER (WHERE time_columns > 0) / COUNT(*)::float AS timeseries_table_ratio
FROM table_analysis;

-- Index type distribution
SELECT
    am.amname AS index_type,
    COUNT(*) AS count,
    COUNT(*)::float / SUM(COUNT(*)) OVER () AS ratio
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam
WHERE c.relnamespace = 'public'::regnamespace
GROUP BY am.amname;

-- Constraint analysis
SELECT
    contype,
    COUNT(*) AS count
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace
GROUP BY contype;
-- contype: 'p' = primary key, 'f' = foreign key, 'u' = unique, 'c' = check, 'x' = exclusion

-- Trigger count
SELECT COUNT(*) AS trigger_count
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE c.relnamespace = 'public'::regnamespace
  AND NOT t.tgisinternal;

-- Partitioning analysis
SELECT
    COUNT(*) FILTER (WHERE relkind = 'p') AS partitioned_tables,
    COUNT(*) FILTER (WHERE relkind = 'r' AND relispartition) AS partition_count
FROM pg_class
WHERE relnamespace = 'public'::regnamespace;
```

**What we can extract**:

| Feature | What It Reveals |
|---------|-----------------|
| `jsonb_column_ratio` | Document-store patterns |
| `array_column_ratio` | Denormalized data patterns |
| `timeseries_table_ratio` | Time-series workload |
| `gin_index_ratio` | Full-text or JSONB search patterns |
| `gist_index_ratio` | Geometric or range queries |
| `brin_index_ratio` | Large sequential data |
| `fk_density` | Relational complexity |
| `trigger_density` | Event-driven patterns |
| `partition_ratio` | Data lifecycle management |


### 2.9 pg_stats (Column Statistics)

Data distribution reveals query patterns.

```sql
SELECT
    schemaname,
    tablename,
    attname,
    null_frac,        -- Fraction of NULLs
    avg_width,        -- Average column width in bytes
    n_distinct,       -- Number of distinct values (negative = fraction of rows)
    correlation       -- Physical vs logical ordering (-1 to 1)
FROM pg_stats
WHERE schemaname = 'public';
```

**What we can extract**:

| Feature | What It Reveals |
|---------|-----------------|
| `avg_null_frac` | Sparse data patterns |
| `low_cardinality_ratio` | Columns where n_distinct < 100 | Good for partial indexes |
| `high_correlation_ratio` | Columns with abs(correlation) > 0.9 | BRIN index candidates |
| `wide_column_ratio` | Columns with avg_width > 100 | TOAST usage, memory pressure |


### 2.10 Query Plan Analysis (Expensive but Valuable)

For hot queries, analyze actual execution plans.

```sql
-- Get top 10 queries by total time
WITH hot_queries AS (
    SELECT queryid, query, calls, total_exec_time
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    ORDER BY total_exec_time DESC
    LIMIT 10
)
SELECT * FROM hot_queries;

-- Then for each, run EXPLAIN (requires actually executing)
-- This should be done carefully in production
EXPLAIN (ANALYZE false, FORMAT JSON)
SELECT ... -- the query
```

**What we can extract from plans**:

| Feature | What It Reveals |
|---------|-----------------|
| `seq_scan_node_ratio` | Sequential scan usage |
| `index_scan_node_ratio` | Index usage |
| `nested_loop_ratio` | Join strategy |
| `hash_join_ratio` | Hash join usage (work_mem sensitive) |
| `merge_join_ratio` | Merge join usage |
| `sort_node_ratio` | Sorting requirements |
| `aggregate_node_ratio` | Aggregation complexity |
| `parallel_node_ratio` | Parallel query usage |


---

## Part 3: Recommended Profiling Strategy

### Tier 1: Always Collect (Low Cost)

These are cheap to query and always available:

```elixir
def profile_tier1(repo) do
  %{
    # Schema structure (static, query once)
    schema: profile_schema(repo),

    # Database-wide stats (single row)
    database: profile_pg_stat_database(repo),

    # Background writer (single row)
    bgwriter: profile_pg_stat_bgwriter(repo),

    # Table-level aggregates
    tables: profile_pg_stat_user_tables_aggregate(repo),

    # Index-level aggregates
    indexes: profile_pg_stat_user_indexes_aggregate(repo)
  }
end
```

### Tier 2: Collect If Available (Medium Cost)

These provide high value but require extensions or recent PG versions:

```elixir
def profile_tier2(repo) do
  %{
    # pg_stat_statements (requires extension)
    statements: profile_pg_stat_statements(repo),

    # pg_stat_wal (PG 14+)
    wal: profile_pg_stat_wal(repo),

    # pg_stat_io (PG 16+)
    io: profile_pg_stat_io(repo),

    # pg_stat_user_functions (requires track_functions)
    functions: profile_pg_stat_user_functions(repo)
  }
end
```

### Tier 3: Sample Over Time (Higher Cost)

These require multiple samples to be meaningful:

```elixir
def profile_tier3(repo, opts) do
  window_seconds = Keyword.get(opts, :window_seconds, 60)
  samples = Keyword.get(opts, :samples, 12)

  measurements = collect_over_time(repo, window_seconds, samples)

  %{
    # pg_stat_activity samples
    activity: %{
      connections_mean: mean(measurements, :connections),
      connections_stddev: stddev(measurements, :connections),
      active_ratio_mean: mean(measurements, :active_ratio),
      wait_event_distribution: aggregate_wait_events(measurements)
    },

    # QPS from pg_stat_database deltas
    throughput: %{
      qps_mean: mean(measurements, :qps),
      qps_stddev: stddev(measurements, :qps),
      qps_peak: max(measurements, :qps)
    },

    # Lock sampling
    locks: %{
      lock_wait_ratio: mean(measurements, :lock_wait_ratio),
      row_lock_ratio: mean(measurements, :row_lock_ratio)
    }
  }
end
```

---

## Part 4: Complete Feature Vector

Combining all sources into a comprehensive feature vector:

```elixir
@feature_spec [
  # === Schema Features (10) ===
  {:schema_table_count, :log_normalize, 1000},
  {:schema_avg_columns, :linear_normalize, 100},
  {:schema_jsonb_ratio, :direct, nil},
  {:schema_array_ratio, :direct, nil},
  {:schema_text_ratio, :direct, nil},
  {:schema_timeseries_ratio, :direct, nil},
  {:schema_gin_index_ratio, :direct, nil},
  {:schema_gist_index_ratio, :direct, nil},
  {:schema_fk_density, :log_normalize, 10},
  {:schema_partitioned_ratio, :direct, nil},

  # === Query Pattern Features (15) ===
  {:query_select_ratio, :direct, nil},
  {:query_insert_ratio, :direct, nil},
  {:query_update_ratio, :direct, nil},
  {:query_delete_ratio, :direct, nil},
  {:query_join_ratio, :direct, nil},
  {:query_aggregate_ratio, :direct, nil},
  {:query_window_fn_ratio, :direct, nil},
  {:query_cte_ratio, :direct, nil},
  {:query_json_usage_ratio, :direct, nil},
  {:query_parameterized_ratio, :direct, nil},
  {:query_diversity, :direct, nil},
  {:query_hot_concentration, :direct, nil},
  {:query_avg_rows_per_call, :log_normalize, 10000},
  {:query_cache_hit_ratio, :direct, nil},
  {:query_temp_spill_ratio, :direct, nil},

  # === Execution Features (8) ===
  {:exec_planning_overhead, :direct, nil},
  {:exec_time_variance, :direct, nil},  # stddev/mean
  {:exec_wal_bytes_per_call, :log_normalize, 10000},
  {:exec_jit_usage_ratio, :direct, nil},
  {:exec_block_read_time_ratio, :direct, nil},
  {:exec_fpi_ratio, :direct, nil},  # full page images ratio
  {:exec_wal_buffer_pressure, :direct, nil},
  {:exec_function_time_ratio, :direct, nil},

  # === I/O Features (6) ===
  {:io_autovacuum_ratio, :direct, nil},
  {:io_checkpoint_write_ratio, :direct, nil},
  {:io_bulkread_ratio, :direct, nil},
  {:io_extend_ratio, :direct, nil},
  {:io_buffer_reuse_ratio, :direct, nil},
  {:io_toast_usage_ratio, :direct, nil},

  # === Index Features (4) ===
  {:index_unused_ratio, :direct, nil},
  {:index_avg_selectivity, :direct, nil},
  {:index_hot_concentration, :direct, nil},
  {:index_to_table_size_ratio, :direct, nil},

  # === Runtime Features (10) ===
  {:runtime_qps_mean, :log_normalize, 10000},
  {:runtime_qps_cv, :direct, nil},  # coefficient of variation
  {:runtime_connections_mean, :log_normalize, 500},
  {:runtime_connections_cv, :direct, nil},
  {:runtime_active_ratio, :direct, nil},
  {:runtime_wait_io_ratio, :direct, nil},
  {:runtime_wait_lock_ratio, :direct, nil},
  {:runtime_wait_lwlock_ratio, :direct, nil},
  {:runtime_wait_client_ratio, :direct, nil},
  {:runtime_lock_wait_ratio, :direct, nil},

  # === Scale Features (6) ===
  {:scale_db_size_gb, :log_normalize, 1000},
  {:scale_largest_table_gb, :log_normalize, 100},
  {:scale_total_index_gb, :log_normalize, 500},
  {:scale_table_count, :log_normalize, 10000},
  {:scale_estimated_rows, :log_normalize, 100_000_000_000},
  {:scale_avg_row_width, :log_normalize, 1000}
]

# Total: 59 features
```

---

## Part 5: Why This Is Accurate

### Signal Quality by Source

| Source | Signal Quality | Why |
|--------|----------------|-----|
| **Schema structure** | Excellent | Deterministic - we query actual catalog |
| **pg_stat_statements** | Excellent | Actual executed queries, not estimates |
| **pg_stat_io** | Excellent | Direct I/O measurements |
| **pg_stat_wal** | Excellent | Actual WAL generation |
| **Time-sampled activity** | Good | Multiple samples reduce noise |
| **pg_locks sampling** | Moderate | Point-in-time, but sampled |
| **Cumulative stats** | Moderate | Accurate but may include old history |

### Coverage of Workload Dimensions

| Dimension | Features Capturing It |
|-----------|----------------------|
| **Read vs Write** | query_*_ratio, wal_bytes, io_checkpoint |
| **Simple vs Complex** | join_ratio, window_fn, cte, query_diversity |
| **OLTP vs OLAP** | rows_per_call, cache_hit, qps, connections |
| **Point vs Scan** | index features, seq_scan ratio, bulkread |
| **Cached vs I/O bound** | cache_hit_ratio, block_read_time, wait_io |
| **Contended vs Free** | lock_wait, wait_lwlock, wait_lock |
| **Batch vs Interactive** | qps_cv, query_hot_concentration |
| **Procedural vs Declarative** | function_time_ratio |
| **Small vs Large** | scale_* features |

### Distinguishing Similar Workloads

Example: Two "read-heavy OLTP" databases that need different tuning:

| Feature | DB A | DB B | Tuning Implication |
|---------|------|------|-------------------|
| `query_json_usage_ratio` | 0.6 | 0.0 | A needs GIN index tuning |
| `query_join_ratio` | 0.1 | 0.7 | B needs work_mem tuning |
| `runtime_wait_io_ratio` | 0.4 | 0.05 | A needs I/O tuning |
| `index_unused_ratio` | 0.3 | 0.05 | A has index bloat |
| `io_toast_usage_ratio` | 0.2 | 0.0 | A stores large values |

With 59 features, we can distinguish these cases and cluster them separately.

---

## Sources

- [PostgreSQL Cumulative Statistics System](https://www.postgresql.org/docs/current/monitoring-stats.html)
- [pg_stat_statements Documentation](https://www.postgresql.org/docs/current/pgstatstatements.html)
- [Effective PostgreSQL Monitoring (EDB)](https://www.enterprisedb.com/blog/effective-postgresql-monitoring-utilizing-pg-stat-all-tables-and-indexes-postgresql-16)
