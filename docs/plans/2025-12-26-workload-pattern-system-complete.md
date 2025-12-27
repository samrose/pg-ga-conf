# Workload Pattern Discovery System - Complete Design

## Executive Summary

This system automatically discovers workload patterns across a fleet of PostgreSQL databases, validates which configuration knobs matter for each pattern through Sobol sensitivity analysis, and uses those validated knob sets for future tuning. It replaces hardcoded archetypes with empirically discovered and validated patterns.

**Key principles**:
1. **Measure, don't assume** - Knob importance is validated by Sobol analysis, not domain expertise
2. **Rich profiling** - 59 features across 7 dimensions capture true workload nature
3. **Continuous learning** - New patterns emerge as more databases are profiled
4. **Efficient reuse** - Similar databases share validated knob sets

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              DATA COLLECTION                                     │
│                                                                                  │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐       ┌──────────────────────────────┐  │
│  │  DB 1   │  │  DB 2   │  │  DB N   │       │                              │  │
│  └────┬────┘  └────┬────┘  └────┬────┘       │   Rich Profiler              │  │
│       │            │            │      ───▶   │   (59 features, 7 layers)    │  │
│       └────────────┴────────────┘             │                              │  │
│                                               └──────────────┬───────────────┘  │
│                                                              │                   │
│                                                              ▼                   │
│                                               ┌──────────────────────────────┐  │
│                                               │   database_profiles table    │  │
│                                               │   (time-series of profiles)  │  │
│                                               └──────────────┬───────────────┘  │
└──────────────────────────────────────────────────────────────┼───────────────────┘
                                                               │
                                                               ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            PATTERN DISCOVERY                                     │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │  DBSCAN Clustering                                                        │   │
│  │  - No predefined cluster count                                            │   │
│  │  - Outliers explicitly identified                                         │   │
│  │  - Clusters = natural workload groupings                                  │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                    │                                             │
│          ┌─────────────────────────┼─────────────────────────┐                  │
│          ▼                         ▼                         ▼                  │
│   ┌─────────────┐          ┌─────────────┐          ┌─────────────┐            │
│   │  Pattern A  │          │  Pattern B  │          │  Pattern C  │            │
│   │  847 DBs    │          │  523 DBs    │          │  234 DBs    │            │
│   │  centroid   │          │  centroid   │          │  centroid   │            │
│   └──────┬──────┘          └──────┬──────┘          └──────┬──────┘            │
│          │                        │                        │                    │
└──────────┼────────────────────────┼────────────────────────┼────────────────────┘
           │                        │                        │
           ▼                        ▼                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            SOBOL VALIDATION                                      │
│                                                                                  │
│  For each pattern:                                                               │
│  1. Select representative DB (closest to centroid)                              │
│  2. Run Sobol analysis with starter knob set                                    │
│  3. Extract knobs with ST > 0.05                                                │
│  4. Store validated_knobs + sobol_indices                                       │
│                                                                                  │
│   ┌─────────────┐          ┌─────────────┐          ┌─────────────┐            │
│   │  Pattern A  │          │  Pattern B  │          │  Pattern C  │            │
│   │  validated: │          │  validated: │          │  validated: │            │
│   │  [work_mem, │          │  [wal_buf,  │          │  [parallel, │            │
│   │   shared_b] │          │   sync_com] │          │   work_mem] │            │
│   └─────────────┘          └─────────────┘          └─────────────┘            │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              TUNING TIME                                         │
│                                                                                  │
│  1. Profile target database                                                      │
│  2. Find nearest pattern (cosine similarity)                                    │
│  3. If similarity > 0.85: use pattern's validated knobs                         │
│  4. If similarity < 0.85: run Sobol, create/update pattern                      │
│  5. Optimize using selected knobs                                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Component 1: Rich Profiler (59 Features)

### Overview

The profiler extracts 59 normalized features across 7 dimensions from each PostgreSQL database. This comprehensive profile captures the true nature of a workload far better than simple OLTP/OLAP classification.

### Feature Dimensions

| Dimension | Features | Purpose |
|-----------|----------|---------|
| Schema Structure | 10 | Table shapes, column types, index types, constraints |
| Query Patterns | 15 | CRUD ratios, complexity, diversity, hot paths |
| Execution Characteristics | 8 | Planning, WAL, JIT, timing |
| I/O Patterns | 6 | By backend type, TOAST, buffer behavior |
| Index Effectiveness | 4 | Usage, selectivity, hot concentration |
| Runtime Behavior | 10 | QPS, connections, wait events (time-sampled) |
| Scale Metrics | 6 | Sizes, counts, growth |

### Data Sources

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         POSTGRESQL DATA SOURCES                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  TIER 1: Always Available                                                        │
│  ├── pg_class, pg_attribute, pg_type    → Schema structure                      │
│  ├── pg_index, pg_am                     → Index types                          │
│  ├── pg_constraint                       → Foreign keys, constraints            │
│  ├── pg_stat_database                    → Database-wide stats                  │
│  ├── pg_stat_bgwriter                    → Background writer stats              │
│  ├── pg_stat_user_tables                 → Table access patterns                │
│  ├── pg_stat_user_indexes                → Index usage                          │
│  ├── pg_statio_user_tables               → Table I/O stats                      │
│  └── pg_stat_activity                    → Connection states, waits             │
│                                                                                  │
│  TIER 2: Requires Extension/Config                                              │
│  ├── pg_stat_statements                  → Query patterns (CRITICAL)            │
│  └── pg_stat_user_functions              → Stored procedure usage               │
│                                                                                  │
│  TIER 3: Version-Specific (PG14+)                                               │
│  ├── pg_stat_wal                         → WAL generation patterns              │
│  ├── pg_stat_io (PG16+)                  → Detailed I/O by backend              │
│  └── pg_stat_checkpointer                → Checkpoint timing                    │
│                                                                                  │
│  TIER 4: Sampled Over Time                                                       │
│  ├── pg_stat_activity (repeated)         → Connection/wait patterns             │
│  ├── pg_stat_database (delta)            → QPS calculation                      │
│  └── pg_locks                            → Contention patterns                  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Feature Specification

#### Layer 1: Schema Structure (10 features)

```sql
-- Table structure analysis
WITH table_analysis AS (
    SELECT
        c.oid,
        c.relname,
        c.relkind,
        (SELECT COUNT(*) FROM pg_attribute a
         WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS column_count,
        (SELECT COUNT(*) FROM pg_attribute a
         JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = c.oid AND t.typname = 'jsonb') AS jsonb_cols,
        (SELECT COUNT(*) FROM pg_attribute a
         JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = c.oid AND t.typname LIKE '%[]') AS array_cols,
        (SELECT COUNT(*) FROM pg_attribute a
         JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = c.oid AND t.typname IN ('text', 'varchar')) AS text_cols,
        (SELECT COUNT(*) FROM pg_attribute a
         JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = c.oid AND t.typname IN ('timestamp', 'timestamptz')) AS time_cols,
        c.relkind = 'p' OR c.relispartition AS is_partitioned
    FROM pg_class c
    WHERE c.relkind IN ('r', 'p')
      AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
),
index_types AS (
    SELECT
        am.amname,
        COUNT(*)::float / NULLIF(SUM(COUNT(*)) OVER (), 0) AS ratio
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_am am ON am.oid = c.relam
    WHERE c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
    GROUP BY am.amname
),
constraints AS (
    SELECT
        COUNT(*) FILTER (WHERE contype = 'f') AS fk_count,
        COUNT(*) FILTER (WHERE contype = 'p') AS pk_count,
        COUNT(*) FILTER (WHERE contype = 'u') AS unique_count
    FROM pg_constraint
    WHERE connamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
)
SELECT
    -- Feature 1: Table count (log normalized)
    COUNT(*)::float AS table_count,

    -- Feature 2: Average columns per table
    AVG(column_count)::float AS avg_columns,

    -- Feature 3: JSONB column ratio
    SUM(jsonb_cols)::float / NULLIF(SUM(column_count), 0) AS jsonb_ratio,

    -- Feature 4: Array column ratio
    SUM(array_cols)::float / NULLIF(SUM(column_count), 0) AS array_ratio,

    -- Feature 5: Text column ratio
    SUM(text_cols)::float / NULLIF(SUM(column_count), 0) AS text_ratio,

    -- Feature 6: Time-series pattern (tables with timestamp columns)
    COUNT(*) FILTER (WHERE time_cols > 0)::float / NULLIF(COUNT(*), 0) AS timeseries_ratio,

    -- Feature 7: Partitioned table ratio
    COUNT(*) FILTER (WHERE is_partitioned)::float / NULLIF(COUNT(*), 0) AS partitioned_ratio,

    -- Feature 8: GIN index ratio (from index_types CTE)
    -- Feature 9: GiST index ratio
    -- Feature 10: Foreign key density (fk_count / table_count)
FROM table_analysis;
```

| # | Feature | Normalization | Why It Matters |
|---|---------|---------------|----------------|
| 1 | `table_count` | log(x)/log(1000) | Scale indicator |
| 2 | `avg_columns` | x/100 | Wide vs narrow tables |
| 3 | `jsonb_ratio` | direct [0,1] | Document-store patterns |
| 4 | `array_ratio` | direct [0,1] | Denormalized data |
| 5 | `text_ratio` | direct [0,1] | Text-heavy, TOAST usage |
| 6 | `timeseries_ratio` | direct [0,1] | Time-series workloads |
| 7 | `partitioned_ratio` | direct [0,1] | Large-scale patterns |
| 8 | `gin_index_ratio` | direct [0,1] | Full-text/JSONB search |
| 9 | `gist_index_ratio` | direct [0,1] | Geometric/range queries |
| 10 | `fk_density` | log(x)/log(10) | Relational complexity |


#### Layer 2: Query Patterns (15 features)

Requires `pg_stat_statements`. Falls back to limited features if unavailable.

```sql
WITH query_stats AS (
    SELECT
        queryid,
        query,
        calls,
        total_exec_time,
        total_plan_time,
        rows,
        shared_blks_hit,
        shared_blks_read,
        temp_blks_read + temp_blks_written AS temp_blks,
        wal_bytes
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
),
query_classification AS (
    SELECT
        queryid,
        calls,
        rows,
        total_exec_time,
        shared_blks_hit,
        shared_blks_read,
        temp_blks,

        -- Query type
        CASE
            WHEN query ~* '^\s*(SELECT|WITH\s+\w+\s+AS\s*\(?\s*SELECT)' THEN 'select'
            WHEN query ~* '^\s*INSERT' THEN 'insert'
            WHEN query ~* '^\s*UPDATE' THEN 'update'
            WHEN query ~* '^\s*DELETE' THEN 'delete'
            ELSE 'other'
        END AS query_type,

        -- Complexity markers
        (length(query) - length(replace(lower(query), ' join ', ''))) / 6 AS join_count,
        (query ~* '\bGROUP\s+BY\b' OR query ~* '\bHAVING\b')::int AS has_aggregate,
        (query ~* '\bWINDOW\b' OR query ~* '\bOVER\s*\(')::int AS has_window,
        (query ~* '\bWITH\s+\w+\s+AS\b')::int AS has_cte,
        (query ~* '\bWITH\s+RECURSIVE\b')::int AS has_recursive,
        (query ~* '->>|->|@>|<@|\?|\?\||\?\&')::int AS has_json_ops,
        (query ~ '\$[0-9]+')::int AS is_parameterized,
        (query ~* '\bFOR\s+(UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b')::int AS has_row_locking

    FROM query_stats
),
aggregated AS (
    SELECT
        -- Call distribution
        SUM(calls) AS total_calls,
        COUNT(DISTINCT queryid) AS distinct_queries,

        -- Type distribution (by calls)
        SUM(calls) FILTER (WHERE query_type = 'select') AS select_calls,
        SUM(calls) FILTER (WHERE query_type = 'insert') AS insert_calls,
        SUM(calls) FILTER (WHERE query_type = 'update') AS update_calls,
        SUM(calls) FILTER (WHERE query_type = 'delete') AS delete_calls,

        -- Complexity (by calls)
        SUM(calls) FILTER (WHERE join_count >= 1) AS join_calls,
        SUM(calls) FILTER (WHERE has_aggregate = 1) AS aggregate_calls,
        SUM(calls) FILTER (WHERE has_window = 1) AS window_calls,
        SUM(calls) FILTER (WHERE has_cte = 1) AS cte_calls,
        SUM(calls) FILTER (WHERE has_json_ops = 1) AS json_calls,
        SUM(calls) FILTER (WHERE is_parameterized = 1) AS param_calls,
        SUM(calls) FILTER (WHERE has_row_locking = 1) AS locking_calls,

        -- Performance
        SUM(rows) AS total_rows,
        SUM(shared_blks_hit) AS total_hits,
        SUM(shared_blks_read) AS total_reads,
        SUM(calls) FILTER (WHERE temp_blks > 0) AS spilling_queries,

        -- Hot query concentration (top 10 by calls)
        (SELECT SUM(calls) FROM (
            SELECT calls FROM query_classification ORDER BY calls DESC LIMIT 10
        ) top10) AS top10_calls

    FROM query_classification
)
SELECT
    -- Feature 11: Select ratio
    select_calls::float / NULLIF(total_calls, 0) AS select_ratio,

    -- Feature 12: Insert ratio
    insert_calls::float / NULLIF(total_calls, 0) AS insert_ratio,

    -- Feature 13: Update ratio
    update_calls::float / NULLIF(total_calls, 0) AS update_ratio,

    -- Feature 14: Delete ratio
    delete_calls::float / NULLIF(total_calls, 0) AS delete_ratio,

    -- Feature 15: Join query ratio
    join_calls::float / NULLIF(total_calls, 0) AS join_ratio,

    -- Feature 16: Aggregate query ratio
    aggregate_calls::float / NULLIF(total_calls, 0) AS aggregate_ratio,

    -- Feature 17: Window function ratio
    window_calls::float / NULLIF(total_calls, 0) AS window_ratio,

    -- Feature 18: CTE ratio
    cte_calls::float / NULLIF(total_calls, 0) AS cte_ratio,

    -- Feature 19: JSON operations ratio
    json_calls::float / NULLIF(total_calls, 0) AS json_ratio,

    -- Feature 20: Parameterized query ratio
    param_calls::float / NULLIF(total_calls, 0) AS parameterized_ratio,

    -- Feature 21: Query diversity (distinct / total)
    distinct_queries::float / NULLIF(total_calls, 0) AS query_diversity,

    -- Feature 22: Hot query concentration
    top10_calls::float / NULLIF(total_calls, 0) AS hot_concentration,

    -- Feature 23: Average rows per call (log normalized)
    total_rows::float / NULLIF(total_calls, 0) AS avg_rows_per_call,

    -- Feature 24: Cache hit ratio
    total_hits::float / NULLIF(total_hits + total_reads, 0) AS cache_hit_ratio,

    -- Feature 25: Temp spill ratio
    spilling_queries::float / NULLIF(distinct_queries, 0) AS temp_spill_ratio

FROM aggregated;
```

| # | Feature | Normalization | Why It Matters |
|---|---------|---------------|----------------|
| 11 | `select_ratio` | direct [0,1] | Read vs write balance |
| 12 | `insert_ratio` | direct [0,1] | Insert-heavy → WAL tuning |
| 13 | `update_ratio` | direct [0,1] | Update-heavy → vacuum tuning |
| 14 | `delete_ratio` | direct [0,1] | Delete-heavy → vacuum tuning |
| 15 | `join_ratio` | direct [0,1] | Complex queries → work_mem |
| 16 | `aggregate_ratio` | direct [0,1] | Analytics → work_mem, parallelism |
| 17 | `window_ratio` | direct [0,1] | Analytics patterns |
| 18 | `cte_ratio` | direct [0,1] | Complex query patterns |
| 19 | `json_ratio` | direct [0,1] | Document-store operations |
| 20 | `parameterized_ratio` | direct [0,1] | Prepared statements (plan caching) |
| 21 | `query_diversity` | direct [0,1] | Ad-hoc vs hot path |
| 22 | `hot_concentration` | direct [0,1] | Optimization opportunity |
| 23 | `avg_rows_per_call` | log(x)/log(10000) | OLTP (small) vs OLAP (large) |
| 24 | `cache_hit_ratio` | direct [0,1] | Buffer effectiveness |
| 25 | `temp_spill_ratio` | direct [0,1] | work_mem pressure |


#### Layer 3: Execution Characteristics (8 features)

```sql
-- From pg_stat_statements aggregates
WITH exec_stats AS (
    SELECT
        SUM(total_plan_time) AS total_plan_time,
        SUM(total_exec_time) AS total_exec_time,
        SUM(wal_bytes) AS total_wal_bytes,
        SUM(calls) AS total_calls,
        SUM(wal_fpi) AS total_fpi,
        SUM(wal_records) AS total_wal_records,
        COUNT(*) FILTER (WHERE jit_functions > 0) AS jit_queries,
        COUNT(*) AS total_queries,
        SUM(blk_read_time) AS total_blk_read_time,
        -- Variance calculation
        STDDEV(mean_exec_time) AS exec_time_stddev,
        AVG(mean_exec_time) AS exec_time_mean
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
),
wal_stats AS (
    SELECT
        wal_buffers_full,
        wal_write
    FROM pg_stat_wal
),
func_stats AS (
    SELECT COALESCE(SUM(total_time), 0) AS total_func_time
    FROM pg_stat_user_functions
)
SELECT
    -- Feature 26: Planning overhead ratio
    total_plan_time / NULLIF(total_exec_time, 0) AS planning_overhead,

    -- Feature 27: Execution time variance (stddev/mean)
    exec_time_stddev / NULLIF(exec_time_mean, 0) AS exec_time_cv,

    -- Feature 28: WAL bytes per call (log normalized)
    total_wal_bytes::float / NULLIF(total_calls, 0) AS wal_bytes_per_call,

    -- Feature 29: JIT usage ratio
    jit_queries::float / NULLIF(total_queries, 0) AS jit_ratio,

    -- Feature 30: Block read time ratio
    total_blk_read_time / NULLIF(total_exec_time, 0) AS blk_read_time_ratio,

    -- Feature 31: Full page image ratio
    total_fpi::float / NULLIF(total_wal_records, 0) AS fpi_ratio,

    -- Feature 32: WAL buffer pressure
    wal_buffers_full::float / NULLIF(wal_write, 0) AS wal_buffer_pressure,

    -- Feature 33: Function time ratio
    total_func_time / NULLIF(total_exec_time, 0) AS function_time_ratio

FROM exec_stats, wal_stats, func_stats;
```

| # | Feature | Normalization | Why It Matters |
|---|---------|---------------|----------------|
| 26 | `planning_overhead` | direct | Complex queries that replan |
| 27 | `exec_time_cv` | min(x, 2)/2 | Consistency (low = predictable) |
| 28 | `wal_bytes_per_call` | log(x)/log(10000) | Write amplification |
| 29 | `jit_ratio` | direct [0,1] | Complex query prevalence |
| 30 | `blk_read_time_ratio` | direct [0,1] | I/O bound indicator |
| 31 | `fpi_ratio` | direct [0,1] | Checkpoint frequency impact |
| 32 | `wal_buffer_pressure` | direct [0,1] | wal_buffers sizing |
| 33 | `function_time_ratio` | direct [0,1] | Procedural vs declarative |


#### Layer 4: I/O Patterns (6 features)

Requires PostgreSQL 16+ for full detail, degrades gracefully.

```sql
-- pg_stat_io (PG16+)
WITH io_by_backend AS (
    SELECT
        backend_type,
        SUM(reads) AS reads,
        SUM(writes) AS writes,
        SUM(hits) AS hits,
        SUM(evictions) AS evictions,
        SUM(reuses) AS reuses
    FROM pg_stat_io
    GROUP BY backend_type
),
io_totals AS (
    SELECT
        SUM(reads) AS total_reads,
        SUM(writes) AS total_writes,
        SUM(hits) AS total_hits,
        SUM(evictions) AS total_evictions,
        SUM(reuses) AS total_reuses
    FROM io_by_backend
),
io_by_context AS (
    SELECT
        context,
        SUM(reads) AS reads
    FROM pg_stat_io
    GROUP BY context
),
toast_stats AS (
    SELECT
        SUM(toast_blks_read + toast_blks_hit) AS toast_blks,
        SUM(heap_blks_read + heap_blks_hit) AS heap_blks
    FROM pg_statio_user_tables
)
SELECT
    -- Feature 34: Autovacuum I/O ratio
    (SELECT reads + writes FROM io_by_backend WHERE backend_type = 'autovacuum worker')::float /
        NULLIF((SELECT total_reads + total_writes FROM io_totals), 0) AS autovacuum_io_ratio,

    -- Feature 35: Checkpointer write ratio
    (SELECT writes FROM io_by_backend WHERE backend_type = 'checkpointer')::float /
        NULLIF((SELECT total_writes FROM io_totals), 0) AS checkpoint_write_ratio,

    -- Feature 36: Bulk read ratio (sequential scans)
    (SELECT reads FROM io_by_context WHERE context = 'bulkread')::float /
        NULLIF((SELECT total_reads FROM io_totals), 0) AS bulkread_ratio,

    -- Feature 37: Extend ratio (table growth)
    -- Approximated from table stats if pg_stat_io unavailable

    -- Feature 38: Buffer reuse ratio
    (SELECT total_reuses FROM io_totals)::float /
        NULLIF((SELECT total_reuses + total_evictions FROM io_totals), 0) AS buffer_reuse_ratio,

    -- Feature 39: TOAST usage ratio
    (SELECT toast_blks::float / NULLIF(heap_blks, 0) FROM toast_stats) AS toast_ratio;
```

| # | Feature | Normalization | Why It Matters |
|---|---------|---------------|----------------|
| 34 | `autovacuum_io_ratio` | direct [0,1] | Vacuum pressure |
| 35 | `checkpoint_write_ratio` | direct [0,1] | Checkpoint sizing needs |
| 36 | `bulkread_ratio` | direct [0,1] | Sequential scan prevalence |
| 37 | `extend_ratio` | direct [0,1] | Table growth rate |
| 38 | `buffer_reuse_ratio` | direct [0,1] | Buffer pressure |
| 39 | `toast_ratio` | direct [0,1] | Large value storage |


#### Layer 5: Index Effectiveness (4 features)

```sql
WITH index_stats AS (
    SELECT
        indexrelid,
        idx_scan,
        idx_tup_read,
        idx_tup_fetch
    FROM pg_stat_user_indexes
),
aggregated AS (
    SELECT
        COUNT(*) AS total_indexes,
        COUNT(*) FILTER (WHERE idx_scan = 0) AS unused_indexes,
        SUM(idx_tup_fetch)::float / NULLIF(SUM(idx_tup_read), 0) AS avg_selectivity,
        SUM(idx_scan) AS total_scans
    FROM index_stats
),
top_indexes AS (
    SELECT SUM(idx_scan) AS top5_scans
    FROM (SELECT idx_scan FROM index_stats ORDER BY idx_scan DESC LIMIT 5) t
),
sizes AS (
    SELECT
        SUM(pg_indexes_size(oid)) AS index_size,
        SUM(pg_table_size(oid)) AS table_size
    FROM pg_class
    WHERE relkind = 'r' AND relnamespace NOT IN (
        'pg_catalog'::regnamespace, 'information_schema'::regnamespace
    )
)
SELECT
    -- Feature 40: Unused index ratio
    unused_indexes::float / NULLIF(total_indexes, 0) AS unused_index_ratio,

    -- Feature 41: Average index selectivity
    avg_selectivity AS index_selectivity,

    -- Feature 42: Hot index concentration (top 5 / total)
    (SELECT top5_scans FROM top_indexes)::float / NULLIF(total_scans, 0) AS index_hot_concentration,

    -- Feature 43: Index to table size ratio
    (SELECT index_size::float / NULLIF(table_size, 0) FROM sizes) AS index_size_ratio

FROM aggregated;
```

| # | Feature | Normalization | Why It Matters |
|---|---------|---------------|----------------|
| 40 | `unused_index_ratio` | direct [0,1] | Index overhead/bloat |
| 41 | `index_selectivity` | direct [0,1] | Index quality (1.0 = perfect) |
| 42 | `index_hot_concentration` | direct [0,1] | Hot path identification |
| 43 | `index_size_ratio` | min(x, 2)/2 | Index overhead |


#### Layer 6: Runtime Behavior (10 features) - Time Sampled

These features require collecting multiple samples over a time window.

```elixir
def sample_runtime(repo, window_seconds, sample_count) do
  interval_ms = div(window_seconds * 1000, sample_count)

  samples = Enum.map(1..sample_count, fn i ->
    if i > 1, do: Process.sleep(interval_ms)

    %{
      timestamp: System.monotonic_time(:millisecond),
      activity: sample_activity(repo),
      xacts: sample_xact_count(repo),
      locks: sample_locks(repo)
    }
  end)

  # Compute deltas and statistics
  %{
    qps: compute_qps(samples),
    connections: Enum.map(samples, & &1.activity.total),
    active_ratio: Enum.map(samples, & &1.activity.active_ratio),
    wait_io: Enum.map(samples, & &1.activity.wait_io_ratio),
    wait_lock: Enum.map(samples, & &1.activity.wait_lock_ratio),
    wait_lwlock: Enum.map(samples, & &1.activity.wait_lwlock_ratio),
    wait_client: Enum.map(samples, & &1.activity.wait_client_ratio),
    lock_wait_ratio: Enum.map(samples, & &1.locks.wait_ratio)
  }
end
```

```sql
-- Activity sample query
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE state = 'active') AS active,
    COUNT(*) FILTER (WHERE wait_event_type = 'IO') AS wait_io,
    COUNT(*) FILTER (WHERE wait_event_type = 'Lock') AS wait_lock,
    COUNT(*) FILTER (WHERE wait_event_type = 'LWLock') AS wait_lwlock,
    COUNT(*) FILTER (WHERE wait_event_type = 'Client') AS wait_client
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid != pg_backend_pid();

-- Lock sample query
SELECT
    COUNT(*) FILTER (WHERE NOT granted)::float /
        NULLIF(COUNT(*), 0) AS wait_ratio
FROM pg_locks
WHERE pid != pg_backend_pid();
```

| # | Feature | Normalization | Why It Matters |
|---|---------|---------------|----------------|
| 44 | `qps_mean` | log(x)/log(10000) | Baseline throughput |
| 45 | `qps_cv` | min(x, 2)/2 | Burstiness (stddev/mean) |
| 46 | `connections_mean` | log(x)/log(500) | Connection volume |
| 47 | `connections_cv` | min(x, 2)/2 | Connection stability |
| 48 | `active_ratio` | direct [0,1] | Connection utilization |
| 49 | `wait_io_ratio` | direct [0,1] | I/O bottleneck |
| 50 | `wait_lock_ratio` | direct [0,1] | Lock contention |
| 51 | `wait_lwlock_ratio` | direct [0,1] | Internal contention |
| 52 | `wait_client_ratio` | direct [0,1] | Client-limited |
| 53 | `lock_wait_ratio` | direct [0,1] | Overall contention |


#### Layer 7: Scale Metrics (6 features)

```sql
SELECT
    -- Feature 54: Database size
    pg_database_size(current_database())::float / (1024^3) AS db_size_gb,

    -- Feature 55: Largest table size
    (SELECT MAX(pg_total_relation_size(oid))::float / (1024^3)
     FROM pg_class WHERE relkind = 'r'
     AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
    ) AS largest_table_gb,

    -- Feature 56: Total index size
    (SELECT SUM(pg_indexes_size(oid))::float / (1024^3)
     FROM pg_class WHERE relkind = 'r'
     AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
    ) AS total_index_gb,

    -- Feature 57: Table count
    (SELECT COUNT(*) FROM pg_class WHERE relkind IN ('r', 'p')
     AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
    ) AS table_count,

    -- Feature 58: Estimated total rows
    (SELECT SUM(reltuples) FROM pg_class WHERE relkind = 'r'
     AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
    ) AS estimated_rows,

    -- Feature 59: Average row width
    (SELECT AVG(
        (SELECT SUM(avg_width) FROM pg_stats s WHERE s.tablename = c.relname)
     ) FROM pg_class c WHERE relkind = 'r'
     AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
    ) AS avg_row_width;
```

| # | Feature | Normalization | Why It Matters |
|---|---------|---------------|----------------|
| 54 | `db_size_gb` | log(x)/log(1000) | Overall scale |
| 55 | `largest_table_gb` | log(x)/log(100) | Largest single table |
| 56 | `total_index_gb` | log(x)/log(500) | Index overhead |
| 57 | `table_count` | log(x)/log(10000) | Schema complexity |
| 58 | `estimated_rows` | log(x)/log(10^11) | Data volume |
| 59 | `avg_row_width` | log(x)/log(1000) | Row size |


### Feature Vector Assembly

```elixir
defmodule PgGaConf.Workload.RichProfiler do
  @feature_count 59

  def profile(repo, opts \\ []) do
    sample_window = Keyword.get(opts, :sample_window_seconds, 60)
    sample_count = Keyword.get(opts, :sample_count, 12)

    with {:ok, schema} <- profile_schema(repo),
         {:ok, queries} <- profile_queries(repo),
         {:ok, execution} <- profile_execution(repo),
         {:ok, io} <- profile_io(repo),
         {:ok, indexes} <- profile_indexes(repo),
         {:ok, runtime} <- profile_runtime(repo, sample_window, sample_count),
         {:ok, scale} <- profile_scale(repo) do

      feature_vector = build_feature_vector(
        schema, queries, execution, io, indexes, runtime, scale
      )

      {:ok, %{
        schema_features: schema,
        query_features: queries,
        execution_features: execution,
        io_features: io,
        index_features: indexes,
        runtime_features: runtime,
        scale_features: scale,
        feature_vector: feature_vector,
        feature_count: @feature_count,
        has_pg_stat_statements: queries.has_pg_stat_statements,
        pg_version: get_pg_version(repo),
        profiled_at: DateTime.utc_now()
      }}
    end
  end

  defp build_feature_vector(schema, queries, execution, io, indexes, runtime, scale) do
    [
      # Layer 1: Schema (10)
      normalize_log(schema.table_count, 1000),
      schema.avg_columns / 100,
      schema.jsonb_ratio,
      schema.array_ratio,
      schema.text_ratio,
      schema.timeseries_ratio,
      schema.partitioned_ratio,
      schema.gin_index_ratio,
      schema.gist_index_ratio,
      normalize_log(schema.fk_density, 10),

      # Layer 2: Query Patterns (15)
      queries.select_ratio,
      queries.insert_ratio,
      queries.update_ratio,
      queries.delete_ratio,
      queries.join_ratio,
      queries.aggregate_ratio,
      queries.window_ratio,
      queries.cte_ratio,
      queries.json_ratio,
      queries.parameterized_ratio,
      queries.query_diversity,
      queries.hot_concentration,
      normalize_log(queries.avg_rows_per_call, 10000),
      queries.cache_hit_ratio,
      queries.temp_spill_ratio,

      # Layer 3: Execution (8)
      min(execution.planning_overhead, 1.0),
      min(execution.exec_time_cv, 2.0) / 2,
      normalize_log(execution.wal_bytes_per_call, 10000),
      execution.jit_ratio,
      execution.blk_read_time_ratio,
      execution.fpi_ratio,
      execution.wal_buffer_pressure,
      execution.function_time_ratio,

      # Layer 4: I/O (6)
      io.autovacuum_io_ratio,
      io.checkpoint_write_ratio,
      io.bulkread_ratio,
      io.extend_ratio,
      io.buffer_reuse_ratio,
      io.toast_ratio,

      # Layer 5: Indexes (4)
      indexes.unused_index_ratio,
      indexes.index_selectivity,
      indexes.index_hot_concentration,
      min(indexes.index_size_ratio, 2.0) / 2,

      # Layer 6: Runtime (10)
      normalize_log(runtime.qps_mean, 10000),
      min(runtime.qps_cv, 2.0) / 2,
      normalize_log(runtime.connections_mean, 500),
      min(runtime.connections_cv, 2.0) / 2,
      runtime.active_ratio,
      runtime.wait_io_ratio,
      runtime.wait_lock_ratio,
      runtime.wait_lwlock_ratio,
      runtime.wait_client_ratio,
      runtime.lock_wait_ratio,

      # Layer 7: Scale (6)
      normalize_log(scale.db_size_gb, 1000),
      normalize_log(scale.largest_table_gb, 100),
      normalize_log(scale.total_index_gb, 500),
      normalize_log(scale.table_count, 10000),
      normalize_log(scale.estimated_rows, 100_000_000_000),
      normalize_log(scale.avg_row_width, 1000)
    ]
  end

  defp normalize_log(value, max_expected) when value > 0 do
    :math.log(value + 1) / :math.log(max_expected + 1)
  end
  defp normalize_log(_, _), do: 0.0
end
```

---

## Component 2: Pattern Discovery

### Clustering Algorithm

DBSCAN (Density-Based Spatial Clustering of Applications with Noise) is used because:

1. **No predefined cluster count** - We don't know how many natural patterns exist
2. **Outlier detection** - Unusual workloads are explicitly identified, not forced into wrong clusters
3. **Arbitrary cluster shapes** - Workload patterns may not be spherical in feature space
4. **Deterministic** - Same input produces same output

```elixir
defmodule PgGaConf.PatternDiscovery do
  @eps 0.20            # Cosine distance threshold (0.20 = similarity > 0.80)
  @min_samples 15      # Minimum databases to form a pattern

  def discover_patterns(repo) do
    # Get aggregated profiles (median of recent profiles per database)
    profiles = get_aggregated_profiles(repo)

    # Build distance matrix
    vectors = Enum.map(profiles, & &1.feature_vector)
    distance_matrix = build_distance_matrix(vectors, &cosine_distance/2)

    # Run DBSCAN
    {labels, _} = dbscan(distance_matrix, @eps, @min_samples)

    # Group by cluster label
    clusters =
      profiles
      |> Enum.zip(labels)
      |> Enum.group_by(fn {_profile, label} -> label end, fn {profile, _} -> profile end)

    # Create patterns for each cluster (excluding noise labeled -1)
    patterns =
      clusters
      |> Enum.reject(fn {label, _} -> label == -1 end)
      |> Enum.map(fn {_label, members} ->
        create_pattern(members, repo)
      end)

    # Return patterns and outliers
    outliers = Map.get(clusters, -1, [])

    {:ok, %{patterns: patterns, outliers: outliers}}
  end

  defp create_pattern(members, repo) do
    vectors = Enum.map(members, & &1.feature_vector)
    db_ids = Enum.map(members, & &1.db_id)

    centroid = compute_centroid(vectors)
    radius = compute_radius(centroid, vectors)

    pattern = %WorkloadPattern{
      id: Ecto.UUID.generate(),
      centroid_vector: centroid,
      radius: radius,
      member_count: length(members),
      member_db_ids: db_ids,
      description: generate_description(centroid),
      created_at: DateTime.utc_now()
    }

    Repo.insert!(pattern)

    # Update database assignments
    Enum.each(members, fn member ->
      similarity = 1.0 - cosine_distance(member.feature_vector, centroid)
      upsert_assignment(member.db_id, pattern.id, similarity, repo)
    end)

    pattern
  end

  defp compute_centroid(vectors) do
    n = length(vectors)
    dim = length(hd(vectors))

    Enum.reduce(vectors, List.duplicate(0.0, dim), fn vec, acc ->
      Enum.zip(acc, vec) |> Enum.map(fn {a, v} -> a + v end)
    end)
    |> Enum.map(& &1 / n)
  end

  defp compute_radius(centroid, vectors) do
    vectors
    |> Enum.map(&cosine_distance(&1, centroid))
    |> Enum.max()
  end

  defp cosine_distance(vec1, vec2) do
    1.0 - cosine_similarity(vec1, vec2)
  end

  defp cosine_similarity(vec1, vec2) do
    dot = Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    mag1 = :math.sqrt(Enum.map(vec1, &(&1 * &1)) |> Enum.sum())
    mag2 = :math.sqrt(Enum.map(vec2, &(&1 * &1)) |> Enum.sum())

    if mag1 == 0 or mag2 == 0, do: 0.0, else: dot / (mag1 * mag2)
  end

  defp generate_description(centroid) do
    # Generate human-readable description from centroid features
    traits = []

    # Query patterns (features 11-14)
    traits = cond do
      Enum.at(centroid, 10) > 0.8 -> ["read-heavy" | traits]
      Enum.at(centroid, 11) > 0.3 -> ["insert-heavy" | traits]
      Enum.at(centroid, 12) > 0.3 -> ["update-heavy" | traits]
      true -> traits
    end

    # Complexity (features 15-18)
    traits = if Enum.at(centroid, 14) > 0.3, do: ["join-heavy" | traits], else: traits
    traits = if Enum.at(centroid, 15) > 0.2, do: ["analytical" | traits], else: traits

    # JSON usage (feature 19)
    traits = if Enum.at(centroid, 18) > 0.2, do: ["json-heavy" | traits], else: traits

    # Scale (feature 54)
    traits = cond do
      Enum.at(centroid, 53) > 0.7 -> ["large-scale" | traits]
      Enum.at(centroid, 53) < 0.2 -> ["small-scale" | traits]
      true -> traits
    end

    # Concurrency (features 44, 48)
    traits = if Enum.at(centroid, 47) > 0.5, do: ["high-concurrency" | traits], else: traits

    Enum.join(traits, ", ")
  end
end
```

### Pattern Maintenance

Patterns evolve over time:

```elixir
defmodule PgGaConf.PatternMaintenance do
  @drift_threshold 0.15  # Reassign if distance > this from assigned pattern

  def check_drift(repo) do
    # Find databases that have drifted from their assigned pattern
    assignments = Repo.all(from a in DatabasePatternAssignment, preload: [:pattern])

    drifted =
      assignments
      |> Enum.filter(fn assignment ->
        current_profile = get_latest_profile(assignment.db_id, repo)
        current_distance = cosine_distance(
          current_profile.feature_vector,
          assignment.pattern.centroid_vector
        )
        current_distance > @drift_threshold
      end)

    # Reassign drifted databases
    Enum.each(drifted, fn assignment ->
      reassign_database(assignment.db_id, repo)
    end)

    {:ok, %{drifted_count: length(drifted)}}
  end

  def reassign_database(db_id, repo) do
    profile = get_latest_profile(db_id, repo)
    {pattern_id, similarity} = find_nearest_pattern(profile.feature_vector, repo)

    if similarity > 0.80 do
      upsert_assignment(db_id, pattern_id, similarity, repo)
    else
      # No good match - mark as outlier for potential new pattern
      delete_assignment(db_id, repo)
    end
  end

  def recluster(repo) do
    # Full re-clustering - run periodically (weekly)
    # Discovers new patterns, merges shrinking ones, updates centroids
    PatternDiscovery.discover_patterns(repo)
  end
end
```

---

## Component 3: Sobol Validation

### Starter Knob Set

```elixir
@starter_knobs [
  # Memory - always relevant
  :shared_buffers,
  :work_mem,
  :effective_cache_size,
  :maintenance_work_mem,
  :hash_mem_multiplier,

  # Planner - affects query execution
  :random_page_cost,
  :effective_io_concurrency,
  :default_statistics_target,

  # Checkpointing - write workloads
  :checkpoint_completion_target,
  :max_wal_size,

  # Parallelism - complex queries
  :max_parallel_workers_per_gather,
  :max_parallel_workers,

  # Autovacuum - write/update workloads
  :autovacuum_vacuum_cost_limit,
  :autovacuum_vacuum_scale_factor,

  # WAL - write workloads
  :wal_buffers,
  :synchronous_commit
]
# 16 knobs → 32 * 18 = 576 evaluations
```

### Validation Process

```elixir
defmodule PgGaConf.PatternValidation do
  @sobol_samples 32
  @importance_threshold 0.05

  def validate_pattern(pattern, repo) do
    # 1. Select representative database (closest to centroid)
    representative = find_representative(pattern, repo)

    Logger.info("Validating pattern #{pattern.id} using database #{representative.db_id}")

    # 2. Set up benchmark
    {:ok, benchmark} = Benchmark.Pgbench.init(
      db_url: representative.db_url,
      duration: 15,
      clients: 8
    )

    # 3. Run Sobol analysis
    knob_space = KnobSpace.subset(@starter_knobs)

    {:ok, indices} = Sobol.analyze(knob_space, benchmark.run_fn,
      n_samples: @sobol_samples,
      restart_fn: fn params ->
        Benchmark.Pgbench.apply_config(benchmark, params)
        Benchmark.Pgbench.restart_postgres(benchmark)
      end
    )

    # 4. Extract important knobs
    validated_knobs =
      indices
      |> Enum.filter(fn {_knob, %{st: st}} -> st >= @importance_threshold end)
      |> Enum.sort_by(fn {_knob, %{st: st}} -> st end, :desc)
      |> Enum.map(fn {knob, _} -> Atom.to_string(knob) end)

    Logger.info("Pattern #{pattern.id}: validated #{length(validated_knobs)} knobs")
    Logger.info("  Knobs: #{Enum.join(validated_knobs, ", ")}")

    # 5. Update pattern
    pattern
    |> WorkloadPattern.changeset(%{
      validated_knobs: validated_knobs,
      sobol_indices: serialize_indices(indices),
      sobol_validated_at: DateTime.utc_now(),
      sobol_db_id: representative.db_id
    })
    |> repo.update!()
  end

  defp find_representative(pattern, repo) do
    # Get all member databases with their profiles
    members =
      pattern.member_db_ids
      |> Enum.map(fn db_id ->
        profile = get_latest_profile(db_id, repo)
        distance = cosine_distance(profile.feature_vector, pattern.centroid_vector)
        %{db_id: db_id, profile: profile, distance: distance}
      end)
      |> Enum.sort_by(& &1.distance)

    # Return the one closest to centroid
    hd(members)
  end

  def get_validation_queue(repo) do
    # Patterns without validated knobs, ordered by member count
    Repo.all(
      from p in WorkloadPattern,
      where: is_nil(p.validated_knobs),
      order_by: [desc: p.member_count],
      limit: 10
    )
  end

  def validation_job_runner(repo) do
    # Run as a scheduled job
    queue = get_validation_queue(repo)

    Enum.each(queue, fn pattern ->
      case validate_pattern(pattern, repo) do
        {:ok, _} ->
          Logger.info("Successfully validated pattern #{pattern.id}")
        {:error, reason} ->
          Logger.error("Failed to validate pattern #{pattern.id}: #{inspect(reason)}")
      end
    end)
  end
end
```

---

## Component 4: Pattern Matching at Tuning Time

```elixir
defmodule PgGaConf.PatternMatcher do
  @similarity_threshold 0.85

  def get_knobs_for_database(db_id, repo) do
    # 1. Get or create current profile
    {:ok, profile} = RichProfiler.profile(db_id, repo)

    # 2. Save profile to history
    save_profile(db_id, profile, repo)

    # 3. Find nearest validated pattern
    validated_patterns = Repo.all(
      from p in WorkloadPattern,
      where: not is_nil(p.validated_knobs)
    )

    if Enum.empty?(validated_patterns) do
      # No validated patterns yet - run Sobol
      {:needs_validation, %{reason: :no_patterns}}
    else
      matches =
        validated_patterns
        |> Enum.map(fn pattern ->
          similarity = cosine_similarity(profile.feature_vector, pattern.centroid_vector)
          {pattern, similarity}
        end)
        |> Enum.sort_by(fn {_, sim} -> sim end, :desc)

      {best_pattern, best_similarity} = hd(matches)

      if best_similarity >= @similarity_threshold do
        # Good match - use pattern's validated knobs
        Logger.info("Database #{db_id} matches pattern #{best_pattern.id} " <>
                    "(similarity: #{Float.round(best_similarity, 3)})")

        {:ok, %{
          pattern_id: best_pattern.id,
          similarity: best_similarity,
          knobs: best_pattern.validated_knobs,
          source: :pattern_match,
          description: best_pattern.description
        }}
      else
        # No good match
        Logger.info("Database #{db_id} has no good pattern match " <>
                    "(best: #{Float.round(best_similarity, 3)})")

        {:needs_validation, %{
          best_pattern_id: best_pattern.id,
          best_similarity: best_similarity,
          reason: :low_similarity
        }}
      end
    end
  end

  def handle_no_match(db_id, repo) do
    # Run Sobol directly for this database
    {:ok, profile} = RichProfiler.profile(db_id, repo)

    # Run Sobol
    knob_space = KnobSpace.subset(@starter_knobs)
    {:ok, benchmark} = setup_benchmark(db_id)

    {:ok, indices} = Sobol.analyze(knob_space, benchmark.run_fn,
      n_samples: 32,
      restart_fn: benchmark.restart_fn
    )

    validated_knobs =
      indices
      |> Enum.filter(fn {_, %{st: st}} -> st >= 0.05 end)
      |> Enum.map(fn {knob, _} -> Atom.to_string(knob) end)

    # Save as database-specific validation
    upsert_assignment(db_id, nil, nil, repo, %{
      custom_validated_knobs: validated_knobs,
      custom_sobol_indices: indices,
      custom_validated_at: DateTime.utc_now()
    })

    {:ok, %{
      knobs: validated_knobs,
      source: :direct_sobol
    }}
  end

  defp cosine_similarity(vec1, vec2) do
    dot = Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    mag1 = :math.sqrt(Enum.map(vec1, &(&1 * &1)) |> Enum.sum())
    mag2 = :math.sqrt(Enum.map(vec2, &(&1 * &1)) |> Enum.sum())
    if mag1 == 0 or mag2 == 0, do: 0.0, else: dot / (mag1 * mag2)
  end
end
```

---

## Data Model

```sql
-- Profile history (time series of database profiles)
CREATE TABLE database_profiles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    db_id text NOT NULL,
    captured_at timestamptz NOT NULL DEFAULT now(),

    -- Feature groups (for analysis/debugging)
    schema_features jsonb NOT NULL,
    query_features jsonb NOT NULL,
    execution_features jsonb NOT NULL,
    io_features jsonb NOT NULL,
    index_features jsonb NOT NULL,
    runtime_features jsonb NOT NULL,
    scale_features jsonb NOT NULL,

    -- Normalized feature vector (59 floats)
    feature_vector float8[59] NOT NULL,

    -- Metadata
    has_pg_stat_statements boolean NOT NULL DEFAULT false,
    pg_version text,
    profile_duration_ms integer,

    CONSTRAINT unique_db_profile UNIQUE (db_id, captured_at)
);

CREATE INDEX idx_profiles_db_id ON database_profiles(db_id);
CREATE INDEX idx_profiles_captured ON database_profiles(captured_at DESC);

-- Workload patterns (discovered clusters)
CREATE TABLE workload_patterns (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Cluster geometry
    centroid_vector float8[59] NOT NULL,
    radius float8 NOT NULL,
    member_count integer NOT NULL DEFAULT 0,

    -- Sobol validation results (null until validated)
    validated_knobs text[],
    sobol_indices jsonb,
    sobol_validated_at timestamptz,
    sobol_db_id text,

    -- Metadata
    description text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Database → Pattern assignments
CREATE TABLE database_pattern_assignments (
    db_id text PRIMARY KEY,
    pattern_id uuid REFERENCES workload_patterns(id),
    similarity float8,
    assigned_at timestamptz NOT NULL DEFAULT now(),

    -- Database-specific validation (if no pattern match)
    custom_validated_knobs text[],
    custom_sobol_indices jsonb,
    custom_validated_at timestamptz
);

CREATE INDEX idx_assignments_pattern ON database_pattern_assignments(pattern_id);

-- Validation job tracking
CREATE TABLE pattern_validation_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pattern_id uuid REFERENCES workload_patterns(id),
    status text NOT NULL DEFAULT 'pending',
    representative_db_id text,
    started_at timestamptz,
    completed_at timestamptz,
    sobol_samples integer,
    total_evaluations integer,
    error_message text,

    CONSTRAINT unique_pending_validation UNIQUE (pattern_id, status)
);
```

---

## Implementation Phases

### What Already Exists

The following components are **complete and tested**:

| Component | Location | Status |
|-----------|----------|--------|
| **Sobol Analysis** | `lib/pg_ga_conf/sobol.ex` | ✅ Complete - `Sobol.analyze/3` runs sensitivity analysis |
| **TuningJob Orchestration** | `lib/pg_ga_conf/tuning_job.ex` | ✅ Complete - orchestrates profiling, benchmarking, optimization |
| **Benchmark.Pgbench** | `lib/pg_ga_conf/benchmark/pgbench.ex` | ✅ Complete - runs benchmarks against target databases |
| **Optimizers** | `lib/pg_ga_conf/optimizer/{ga,tpe,cma_es}.ex` | ✅ Complete - GA, TPE, and CMA-ES optimizers |
| **Basic Profiler** | `lib/pg_ga_conf/workload/profiler.ex` | ⚠️ Partial - 30 features, needs upgrade to 59 |
| **Rule-based Classifier** | `lib/pg_ga_conf/workload/classifier.ex` | ❌ Replace - hardcoded archetypes, not empirically validated |
| **Archetype Knobs** | `lib/pg_ga_conf/knob_space.ex` | ❌ Deprecate - `@archetype_knobs` to be replaced by validated patterns |

### Phase 1: Rich Profiler Upgrade

Upgrade existing profiler from 30 to 59 features:

1. Add schema structure layer (features 1-10) - new queries against pg_class, pg_attribute, pg_type
2. Expand query patterns layer (features 11-25) - more pg_stat_statements analysis
3. Add execution characteristics layer (features 26-33) - pg_stat_wal, JIT stats
4. Add I/O patterns layer (features 34-39) - pg_stat_io (PG16+) with graceful degradation
5. Add index effectiveness layer (features 40-43) - pg_stat_user_indexes aggregates
6. Add runtime behavior layer (features 44-53) - time-sampled from pg_stat_activity
7. Add scale metrics layer (features 54-59) - database size, row estimates

**Deliverables**:
- Updated `PgGaConf.Workload.Profiler` module (rename to `RichProfiler`)
- `database_profiles` table schema (Ecto migration)
- Tests validating all 59 features extract correctly

### Phase 2: Pattern Discovery

New module implementing DBSCAN clustering:

1. Implement DBSCAN with cosine distance metric
2. Implement centroid calculation and radius
3. Implement description generation from centroid features
4. Create pattern storage and database assignments

**Deliverables**:
- `PgGaConf.PatternDiscovery` module
- `workload_patterns` table schema
- `database_pattern_assignments` table schema

### Phase 3: Pattern Validation

Wire existing Sobol analysis to validate discovered patterns:

1. Implement validation queue (patterns ordered by member count)
2. Implement representative database selection (closest to centroid)
3. Wire `Sobol.analyze/3` to run against representative
4. Store validated knobs on pattern record

**Deliverables**:
- `PgGaConf.PatternValidation` module
- Validation job scheduler

### Phase 4: Pattern Matcher Integration

Update TuningJob to use pattern-based knob selection:

1. Create `PatternMatcher.get_knobs_for_database/2`
2. Update `TuningJob.determine_knob_space/5` to call PatternMatcher
3. Handle no-match cases with direct Sobol fallback
4. Remove dependency on hardcoded `@archetype_knobs`

**Deliverables**:
- `PgGaConf.PatternMatcher` module
- Updated `TuningJob` using pattern-based knob selection

### Phase 5: Continuous Learning

Maintenance and drift detection:

1. Implement drift detection (check if databases moved from assigned pattern)
2. Implement reassignment logic
3. Schedule periodic re-clustering
4. Invalidate pattern validations when centroid drifts significantly

**Deliverables**:
- `PgGaConf.PatternMaintenance` module
- Scheduled jobs for drift detection and re-clustering

---

## Success Metrics

| Metric | Target | How to Measure |
|--------|--------|----------------|
| **Profile completeness** | >90% have pg_stat_statements | Check `has_pg_stat_statements` |
| **Pattern coverage** | >80% of DBs match a pattern | Count assignments with similarity > 0.85 |
| **Validation coverage** | Top 10 patterns validated | Count patterns with validated_knobs |
| **Knob accuracy** | Validated knobs capture >80% of ST | Compare to full Sobol on sample |
| **Tuning efficiency** | Same results with 50% fewer iterations | A/B test pattern knobs vs starter set |

---

## Appendix: Feature Reference

| # | Feature | Layer | Source | Normalization |
|---|---------|-------|--------|---------------|
| 1 | table_count | Schema | pg_class | log/log(1000) |
| 2 | avg_columns | Schema | pg_attribute | /100 |
| 3 | jsonb_ratio | Schema | pg_attribute + pg_type | direct |
| 4 | array_ratio | Schema | pg_attribute + pg_type | direct |
| 5 | text_ratio | Schema | pg_attribute + pg_type | direct |
| 6 | timeseries_ratio | Schema | pg_attribute + pg_type | direct |
| 7 | partitioned_ratio | Schema | pg_class | direct |
| 8 | gin_index_ratio | Schema | pg_am | direct |
| 9 | gist_index_ratio | Schema | pg_am | direct |
| 10 | fk_density | Schema | pg_constraint | log/log(10) |
| 11 | select_ratio | Query | pg_stat_statements | direct |
| 12 | insert_ratio | Query | pg_stat_statements | direct |
| 13 | update_ratio | Query | pg_stat_statements | direct |
| 14 | delete_ratio | Query | pg_stat_statements | direct |
| 15 | join_ratio | Query | pg_stat_statements | direct |
| 16 | aggregate_ratio | Query | pg_stat_statements | direct |
| 17 | window_ratio | Query | pg_stat_statements | direct |
| 18 | cte_ratio | Query | pg_stat_statements | direct |
| 19 | json_ratio | Query | pg_stat_statements | direct |
| 20 | parameterized_ratio | Query | pg_stat_statements | direct |
| 21 | query_diversity | Query | pg_stat_statements | direct |
| 22 | hot_concentration | Query | pg_stat_statements | direct |
| 23 | avg_rows_per_call | Query | pg_stat_statements | log/log(10000) |
| 24 | cache_hit_ratio | Query | pg_stat_statements | direct |
| 25 | temp_spill_ratio | Query | pg_stat_statements | direct |
| 26 | planning_overhead | Execution | pg_stat_statements | min(x, 1) |
| 27 | exec_time_cv | Execution | pg_stat_statements | min(x, 2)/2 |
| 28 | wal_bytes_per_call | Execution | pg_stat_statements | log/log(10000) |
| 29 | jit_ratio | Execution | pg_stat_statements | direct |
| 30 | blk_read_time_ratio | Execution | pg_stat_statements | direct |
| 31 | fpi_ratio | Execution | pg_stat_wal | direct |
| 32 | wal_buffer_pressure | Execution | pg_stat_wal | direct |
| 33 | function_time_ratio | Execution | pg_stat_user_functions | direct |
| 34 | autovacuum_io_ratio | I/O | pg_stat_io | direct |
| 35 | checkpoint_write_ratio | I/O | pg_stat_io | direct |
| 36 | bulkread_ratio | I/O | pg_stat_io | direct |
| 37 | extend_ratio | I/O | pg_stat_io | direct |
| 38 | buffer_reuse_ratio | I/O | pg_stat_io | direct |
| 39 | toast_ratio | I/O | pg_statio_user_tables | direct |
| 40 | unused_index_ratio | Index | pg_stat_user_indexes | direct |
| 41 | index_selectivity | Index | pg_stat_user_indexes | direct |
| 42 | index_hot_concentration | Index | pg_stat_user_indexes | direct |
| 43 | index_size_ratio | Index | pg_class | min(x, 2)/2 |
| 44 | qps_mean | Runtime | pg_stat_database (delta) | log/log(10000) |
| 45 | qps_cv | Runtime | pg_stat_database (delta) | min(x, 2)/2 |
| 46 | connections_mean | Runtime | pg_stat_activity | log/log(500) |
| 47 | connections_cv | Runtime | pg_stat_activity | min(x, 2)/2 |
| 48 | active_ratio | Runtime | pg_stat_activity | direct |
| 49 | wait_io_ratio | Runtime | pg_stat_activity | direct |
| 50 | wait_lock_ratio | Runtime | pg_stat_activity | direct |
| 51 | wait_lwlock_ratio | Runtime | pg_stat_activity | direct |
| 52 | wait_client_ratio | Runtime | pg_stat_activity | direct |
| 53 | lock_wait_ratio | Runtime | pg_locks | direct |
| 54 | db_size_gb | Scale | pg_database_size | log/log(1000) |
| 55 | largest_table_gb | Scale | pg_class | log/log(100) |
| 56 | total_index_gb | Scale | pg_indexes_size | log/log(500) |
| 57 | table_count | Scale | pg_class | log/log(10000) |
| 58 | estimated_rows | Scale | pg_class.reltuples | log/log(10^11) |
| 59 | avg_row_width | Scale | pg_stats | log/log(1000) |
