# Workload Pattern Discovery and Validated Knob Selection

## Problem Statement

The current workload classification system has fundamental accuracy issues:

1. **Hardcoded archetypes**: 8 predefined categories (high_concurrency_oltp, analytical, etc.) are assumed, not discovered
2. **Assumed knob mappings**: Each archetype maps to a fixed set of "important" knobs based on domain expertise, not empirical validation
3. **Shallow profiling**: Current profiler captures 30 features from cumulative pg_stat_* counters, missing:
   - Schema structure (JSONB usage, index types, partitioning)
   - Query complexity (joins, CTEs, subqueries)
   - Time-varying behavior (steady vs bursty)
   - Scale characteristics

The result: we cannot prove the archetype → knob mappings are correct, and the profiling may not capture what actually distinguishes workloads.

## Solution Overview

Replace assumed archetypes with **empirically discovered patterns** validated by **Sobol sensitivity analysis**:

```
┌────────────────────────────────────────────────────────────────────────────┐
│ CONTINUOUS PROFILING                                                        │
│ Every hosted database → Rich 4-layer profile → Store in profile_history   │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ PATTERN DISCOVERY                                                           │
│ Cluster profiles → Find natural groupings → No predefined categories       │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ SOBOL VALIDATION                                                            │
│ Per pattern: Run Sobol on representative DB → Discover which knobs matter  │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ TUNING                                                                      │
│ New DB → Find matching pattern → Use validated knobs → Optimize            │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Component 1: Rich Profiling

### Why Current Profiling Is Insufficient

The current `Workload.Profiler` collects ~30 features, primarily ratios derived from cumulative pg_stat_* counters:

| Limitation | Impact |
|------------|--------|
| **Cumulative stats** | Counters since last reset (could be months). Profile reflects entire history, not current behavior. |
| **No schema analysis** | Can't distinguish JSONB-heavy document store from normalized relational schema. |
| **No query complexity** | Can't distinguish simple key-value lookups from complex analytical joins. |
| **Point-in-time snapshot** | Misses time-varying patterns (OLTP by day, batch at night). |
| **No scale awareness** | 1GB database and 1TB database may have same ratios but need different tuning. |

### Four-Layer Profiling Model

#### Layer 1: Schema Structure

Schema structure is relatively static and reveals fundamental workload characteristics.

**Collection method**: Query `information_schema` and `pg_catalog` tables.

```sql
-- Table shape analysis
SELECT
    COUNT(*) AS table_count,
    AVG(column_count) AS avg_columns,
    MAX(column_count) AS max_columns,
    COUNT(*) FILTER (WHERE has_jsonb) AS jsonb_tables,
    COUNT(*) FILTER (WHERE has_array) AS array_tables,
    COUNT(*) FILTER (WHERE is_partitioned) AS partitioned_tables
FROM (
    SELECT
        c.relname,
        COUNT(a.attnum) AS column_count,
        bool_or(t.typname = 'jsonb') AS has_jsonb,
        bool_or(t.typname LIKE '%[]') AS has_array,
        c.relkind = 'p' AS is_partitioned
    FROM pg_class c
    JOIN pg_attribute a ON a.attrelid = c.oid
    JOIN pg_type t ON t.oid = a.atttypid
    WHERE c.relkind IN ('r', 'p')
      AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
      AND a.attnum > 0
    GROUP BY c.oid, c.relname, c.relkind
) table_info;

-- Index type distribution
SELECT
    am.amname AS index_type,
    COUNT(*) AS count,
    COUNT(*)::float / SUM(COUNT(*)) OVER () AS ratio
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam
GROUP BY am.amname;

-- Foreign key density (relational complexity)
SELECT COUNT(*) AS fk_count
FROM pg_constraint
WHERE contype = 'f';
```

**Features extracted**:

| Feature | Type | Why It Matters |
|---------|------|----------------|
| `table_count` | integer | Scale indicator |
| `avg_columns_per_table` | float | Wide tables need different memory tuning |
| `jsonb_column_ratio` | float | JSONB-heavy → GIN indexes, different query patterns |
| `array_column_ratio` | float | Array operations have specific performance characteristics |
| `text_column_ratio` | float | Text-heavy → TOAST storage, different I/O patterns |
| `partitioned_table_ratio` | float | Partitioning indicates time-series or large-scale patterns |
| `index_type_distribution` | map | btree vs GIN vs GiST reveals query types |
| `fk_density` | float | High FK count = complex relational model |
| `has_timeseries_pattern` | boolean | Tables with timestamp + created_at patterns |
| `has_audit_pattern` | boolean | Tables named *_audit, *_history, *_log |

**Why this is accurate**: Schema structure is deterministic - we're querying the actual catalog, not sampling. A JSONB-heavy schema will always show high `jsonb_column_ratio`.


#### Layer 2: Query Patterns

Query patterns reveal what the application actually does with the data.

**Collection method**: Analyze `pg_stat_statements` with query text pattern matching.

```sql
-- Query type distribution by calls
SELECT
    CASE
        WHEN query ~* '^\s*(SELECT|WITH.+SELECT)' THEN 'select'
        WHEN query ~* '^\s*INSERT' THEN 'insert'
        WHEN query ~* '^\s*UPDATE' THEN 'update'
        WHEN query ~* '^\s*DELETE' THEN 'delete'
        ELSE 'other'
    END AS query_type,
    SUM(calls) AS total_calls,
    SUM(calls)::float / SUM(SUM(calls)) OVER () AS call_ratio,
    SUM(total_exec_time) AS total_time,
    SUM(rows) AS total_rows
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
GROUP BY 1;

-- Query complexity indicators
SELECT
    COUNT(*) FILTER (WHERE query ~* '\bJOIN\b') AS join_queries,
    COUNT(*) FILTER (WHERE query ~* '\bGROUP BY\b') AS aggregate_queries,
    COUNT(*) FILTER (WHERE query ~* '\bWITH\b') AS cte_queries,
    COUNT(*) FILTER (WHERE query ~* '\(\s*SELECT\b') AS subquery_queries,
    COUNT(*) FILTER (WHERE query ~* '\bWINDOW\b|\bOVER\s*\(') AS window_queries,
    COUNT(*) AS total_distinct_queries,
    SUM(calls) AS total_calls
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- Hot query concentration (top 10 queries as % of total calls)
WITH ranked AS (
    SELECT
        calls,
        SUM(calls) OVER () AS total_calls,
        ROW_NUMBER() OVER (ORDER BY calls DESC) AS rank
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
)
SELECT SUM(calls)::float / MAX(total_calls) AS top_10_concentration
FROM ranked
WHERE rank <= 10;
```

**Features extracted**:

| Feature | Type | Why It Matters |
|---------|------|----------------|
| `select_ratio` | float | Read vs write balance |
| `insert_ratio` | float | Insert-heavy → WAL pressure |
| `update_ratio` | float | Update-heavy → vacuum pressure, dead tuples |
| `delete_ratio` | float | Delete-heavy → vacuum pressure |
| `join_query_ratio` | float | Joins → work_mem critical, parallel query beneficial |
| `aggregate_query_ratio` | float | Aggregates → work_mem for sorts/hashes |
| `cte_query_ratio` | float | CTEs → memory pressure, optimization barriers |
| `subquery_query_ratio` | float | Subqueries → planner complexity |
| `window_query_ratio` | float | Window functions → work_mem for sorts |
| `query_diversity` | float | Distinct queries / total calls. Low = hot path optimization. High = ad-hoc. |
| `hot_query_concentration` | float | Top 10 queries as % of calls. High = cacheable patterns. |
| `avg_rows_per_call` | float | Large result sets → effective_cache_size matters |
| `avg_time_per_call_ms` | float | Baseline query latency |
| `cache_hit_ratio` | float | shared_blks_hit / (hit + read) |
| `temp_usage_ratio` | float | Queries spilling to disk |

**Why this is accurate**: pg_stat_statements captures actual executed queries. We're not guessing what the workload does - we're measuring it. The regex patterns reliably identify query types (JOINs, aggregates, etc.) because SQL syntax is unambiguous.

**Limitation**: Requires pg_stat_statements extension. If not available, these features fall back to defaults and the profile will be less distinctive.


#### Layer 3: Runtime Behavior

Runtime behavior captures time-varying characteristics that cumulative stats miss.

**Collection method**: Take multiple samples over a time window and compute statistics.

```elixir
def profile_runtime(repo, opts) do
  window_seconds = Keyword.get(opts, :window_seconds, 60)
  sample_count = Keyword.get(opts, :sample_count, 12)  # Every 5 seconds for 1 minute
  sample_interval_ms = div(window_seconds * 1000, sample_count)

  # Collect samples
  samples = Enum.map(1..sample_count, fn i ->
    if i > 1, do: Process.sleep(sample_interval_ms)
    take_sample(repo)
  end)

  # Compute time-delta metrics
  qps_values = compute_qps_between_samples(samples)

  %{
    qps_mean: Statistics.mean(qps_values),
    qps_stddev: Statistics.stddev(qps_values),
    qps_peak: Enum.max(qps_values),
    qps_coefficient_of_variation: Statistics.stddev(qps_values) / max(Statistics.mean(qps_values), 1),

    connections_mean: samples |> Enum.map(& &1.connections) |> Statistics.mean(),
    connections_peak: samples |> Enum.map(& &1.connections) |> Enum.max(),
    connections_stddev: samples |> Enum.map(& &1.connections) |> Statistics.stddev(),

    active_query_ratio_mean: samples |> Enum.map(& &1.active_ratio) |> Statistics.mean(),

    # Wait event distribution (averaged across samples)
    wait_io_ratio: samples |> Enum.map(& &1.wait_io) |> Statistics.mean(),
    wait_lock_ratio: samples |> Enum.map(& &1.wait_lock) |> Statistics.mean(),
    wait_lwlock_ratio: samples |> Enum.map(& &1.wait_lwlock) |> Statistics.mean(),
    wait_client_ratio: samples |> Enum.map(& &1.wait_client) |> Statistics.mean()
  }
end

defp take_sample(repo) do
  # Current connections and states
  activity_query = """
  SELECT
    COUNT(*) AS total_connections,
    COUNT(*) FILTER (WHERE state = 'active') AS active,
    COUNT(*) FILTER (WHERE state = 'idle') AS idle,
    COUNT(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction,
    COUNT(*) FILTER (WHERE wait_event_type = 'IO') AS wait_io,
    COUNT(*) FILTER (WHERE wait_event_type = 'Lock') AS wait_lock,
    COUNT(*) FILTER (WHERE wait_event_type = 'LWLock') AS wait_lwlock,
    COUNT(*) FILTER (WHERE wait_event_type = 'Client') AS wait_client
  FROM pg_stat_activity
  WHERE backend_type = 'client backend'
    AND pid != pg_backend_pid()
  """

  # Current cumulative stats (for computing deltas)
  stats_query = """
  SELECT xact_commit + xact_rollback AS total_xacts
  FROM pg_stat_database
  WHERE datname = current_database()
  """

  # Execute both and return sample
  %{
    timestamp: System.monotonic_time(:millisecond),
    connections: activity.total_connections,
    active: activity.active,
    active_ratio: activity.active / max(activity.total_connections, 1),
    wait_io: activity.wait_io / max(activity.total_connections, 1),
    wait_lock: activity.wait_lock / max(activity.total_connections, 1),
    wait_lwlock: activity.wait_lwlock / max(activity.total_connections, 1),
    wait_client: activity.wait_client / max(activity.total_connections, 1),
    cumulative_xacts: stats.total_xacts
  }
end

defp compute_qps_between_samples(samples) do
  samples
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.map(fn [s1, s2] ->
    time_delta_seconds = (s2.timestamp - s1.timestamp) / 1000
    xact_delta = s2.cumulative_xacts - s1.cumulative_xacts
    xact_delta / time_delta_seconds
  end)
end
```

**Features extracted**:

| Feature | Type | Why It Matters |
|---------|------|----------------|
| `qps_mean` | float | Baseline throughput |
| `qps_stddev` | float | Traffic variability |
| `qps_coefficient_of_variation` | float | stddev/mean - burstiness indicator |
| `connections_mean` | float | Typical connection count |
| `connections_peak` | float | Max observed connections |
| `active_query_ratio_mean` | float | How busy are connections |
| `wait_io_ratio` | float | I/O bound indicator |
| `wait_lock_ratio` | float | Contention indicator |
| `wait_lwlock_ratio` | float | Internal contention |
| `wait_client_ratio` | float | Client-limited (network, app) |

**Why this is accurate**:
- Time-windowed sampling captures current behavior, not historical accumulation
- Computing deltas between samples gives true rates (QPS), not cumulative totals
- Wait event sampling reveals actual bottlenecks
- Standard deviation and coefficient of variation capture burstiness that point-in-time snapshots miss

**Trade-off**: Requires a sampling window (default 60 seconds). Longer windows are more accurate but slower.


#### Layer 4: Scale Metrics

Scale affects which tuning strategies work. A 1GB database and 1TB database with identical usage ratios need different configurations.

**Collection method**: Query pg_catalog for size information.

```sql
-- Database and table sizes
SELECT
    pg_database_size(current_database()) AS db_size_bytes,
    (SELECT SUM(pg_total_relation_size(oid))
     FROM pg_class
     WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace) AS total_table_bytes,
    (SELECT SUM(pg_indexes_size(oid))
     FROM pg_class
     WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace) AS total_index_bytes,
    (SELECT MAX(pg_total_relation_size(oid))
     FROM pg_class
     WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace) AS largest_table_bytes;

-- Row count estimates
SELECT SUM(reltuples)::bigint AS estimated_rows
FROM pg_class
WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace;
```

**Features extracted**:

| Feature | Type | Why It Matters |
|---------|------|----------------|
| `database_size_gb` | float | Overall scale |
| `largest_table_gb` | float | Largest single table affects seq scan cost |
| `total_table_size_gb` | float | Data volume |
| `total_index_size_gb` | float | Index overhead, memory needs |
| `index_to_table_ratio` | float | Index-heavy = read-optimized |
| `estimated_total_rows` | integer | Row count scale |
| `avg_row_size_bytes` | float | Wide rows vs narrow rows |

**Why this is accurate**: Size metrics are precise - we're querying actual storage usage, not estimating.


### Feature Vector Construction

All features are combined into a normalized vector suitable for clustering and similarity comparison.

```elixir
def build_feature_vector(schema, queries, runtime, scale) do
  [
    # Schema features (7 features)
    normalize_log(schema.table_count, 1000),
    schema.jsonb_column_ratio,
    schema.array_column_ratio,
    schema.partitioned_table_ratio,
    schema.index_type_distribution[:gin] || 0,
    schema.index_type_distribution[:gist] || 0,
    normalize_log(schema.fk_count, 500),

    # Query features (12 features)
    queries.select_ratio,
    queries.insert_ratio,
    queries.update_ratio,
    queries.delete_ratio,
    queries.join_query_ratio,
    queries.aggregate_query_ratio,
    queries.cte_query_ratio,
    queries.window_query_ratio,
    queries.query_diversity,
    queries.hot_query_concentration,
    queries.cache_hit_ratio,
    queries.temp_usage_ratio,

    # Runtime features (8 features)
    normalize_log(runtime.qps_mean, 10000),
    runtime.qps_coefficient_of_variation,
    normalize_log(runtime.connections_mean, 500),
    runtime.active_query_ratio_mean,
    runtime.wait_io_ratio,
    runtime.wait_lock_ratio,
    runtime.wait_lwlock_ratio,
    runtime.wait_client_ratio,

    # Scale features (4 features)
    normalize_log(scale.database_size_gb, 1000),
    normalize_log(scale.largest_table_gb, 100),
    scale.index_to_table_ratio,
    normalize_log(scale.estimated_total_rows, 10_000_000_000)
  ]
  # Total: 31 features
end

# Log normalization for scale-invariant features
# Maps [0, max_expected] to approximately [0, 1]
defp normalize_log(value, max_expected) do
  :math.log(value + 1) / :math.log(max_expected + 1)
end
```

**Normalization rationale**:
- Ratio features (0-1) are used directly
- Count/size features use log normalization to compress wide ranges
- All features end up in approximately [0, 1] range for fair distance calculations

---

## Component 2: Pattern Discovery

### Why Clustering Works

Databases with similar profiles likely have similar optimal configurations because:

1. **Schema structure constrains access patterns**: A JSONB-heavy schema will use GIN indexes and have specific query patterns regardless of who operates it
2. **Query patterns determine bottlenecks**: JOIN-heavy workloads stress work_mem; write-heavy workloads stress WAL
3. **Scale affects which knobs matter**: Small databases are less sensitive to most tuning; large databases amplify configuration effects

### Clustering Algorithm: DBSCAN

We use DBSCAN (Density-Based Spatial Clustering of Applications with Noise) rather than k-means because:

| k-means | DBSCAN |
|---------|--------|
| Requires specifying k (number of clusters) upfront | Discovers natural cluster count |
| Forces every point into a cluster | Identifies outliers explicitly |
| Assumes spherical clusters | Handles arbitrary cluster shapes |
| Sensitive to initialization | Deterministic |

**Algorithm parameters**:

- `eps` (epsilon): Maximum distance between points in same cluster. For cosine distance on 31-dim normalized vectors, 0.15-0.30 works well.
- `min_samples`: Minimum points to form a cluster. Set to 10-20 to avoid micro-clusters.

```elixir
defmodule PgGaConf.PatternDiscovery do
  @eps 0.25  # Cosine distance threshold
  @min_samples 15  # Minimum databases per pattern

  def discover_patterns do
    # Get latest aggregated profile per database
    profiles = get_aggregated_profiles()

    # Extract feature vectors and metadata
    points = Enum.map(profiles, fn p ->
      %{db_id: p.db_id, vector: p.feature_vector}
    end)

    # Compute pairwise cosine distances
    distance_matrix = compute_distance_matrix(points, &cosine_distance/2)

    # Run DBSCAN
    clusters = dbscan(distance_matrix, @eps, @min_samples)

    # Process results
    process_clusters(clusters, points)
  end

  defp dbscan(distance_matrix, eps, min_samples) do
    n = length(distance_matrix)
    labels = :array.new(n, default: :undefined)  # -1 = noise, >= 0 = cluster id
    cluster_id = 0

    Enum.reduce(0..(n-1), {labels, cluster_id}, fn point_idx, {labels, cluster_id} ->
      if :array.get(point_idx, labels) != :undefined do
        {labels, cluster_id}  # Already processed
      else
        neighbors = region_query(distance_matrix, point_idx, eps)

        if length(neighbors) < min_samples do
          {:array.set(point_idx, -1, labels), cluster_id}  # Mark as noise
        else
          # Expand cluster
          {new_labels, _} = expand_cluster(
            distance_matrix, point_idx, neighbors,
            cluster_id, labels, eps, min_samples
          )
          {new_labels, cluster_id + 1}
        end
      end
    end)
  end

  defp region_query(distance_matrix, point_idx, eps) do
    distance_matrix
    |> Enum.at(point_idx)
    |> Enum.with_index()
    |> Enum.filter(fn {dist, _idx} -> dist <= eps end)
    |> Enum.map(fn {_dist, idx} -> idx end)
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
end
```

### Cluster Representation

Each discovered cluster becomes a **workload pattern** with:

```elixir
%WorkloadPattern{
  id: uuid,

  # Cluster geometry
  centroid_vector: [0.12, 0.85, ...],  # 31-dim centroid (mean of member vectors)
  radius: 0.18,                         # Max distance from centroid to any member
  member_count: 247,                    # Number of databases in this pattern

  # Validation status
  validated_knobs: nil | ["shared_buffers", "work_mem", ...],
  sobol_indices: nil | %{shared_buffers: %{s1: 0.23, st: 0.31}, ...},
  sobol_validated_at: nil | ~U[2025-12-25 10:30:00Z],
  sobol_db_id: nil | "db-abc-123",     # Which database was used for validation

  # Metadata
  description: "read-heavy, join-heavy, large-scale",  # Auto-generated
  created_at: ~U[2025-12-20 08:00:00Z],
  updated_at: ~U[2025-12-25 10:30:00Z]
}
```

### Pattern Maintenance

Patterns evolve as the database fleet changes:

1. **New databases**: Assigned to nearest pattern if similarity > threshold, else flagged as outlier
2. **Drift detection**: If a database's profile moves far from its assigned pattern, reassign
3. **Re-clustering**: Periodically (weekly) re-run clustering to discover new patterns or merge/split existing ones
4. **Outlier promotion**: If enough outliers cluster together, create a new pattern

---

## Component 3: Sobol Validation

### Why Sobol Works

Sobol sensitivity analysis measures how much each configuration parameter contributes to performance variance through systematic experimentation.

**Key insight**: Instead of assuming "write-heavy workloads need WAL tuning", we MEASURE whether WAL knobs actually affect performance for a specific workload.

### Validation Process

For each pattern without validated knobs:

```elixir
defmodule PgGaConf.PatternValidation do
  @starter_knobs [
    # Memory
    :shared_buffers, :work_mem, :effective_cache_size, :maintenance_work_mem,
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
  # 15 knobs → ~500 evaluations for n_samples=32

  def validate_pattern(pattern) do
    # 1. Find representative database (closest to centroid)
    representative = find_representative(pattern)

    # 2. Set up benchmark for this database
    {:ok, benchmark} = setup_benchmark(representative)

    # 3. Run Sobol analysis
    knob_space = KnobSpace.subset(@starter_knobs)

    {:ok, indices} = Sobol.analyze(knob_space, benchmark.run_fn,
      n_samples: 32,
      restart_fn: benchmark.restart_fn
    )

    # 4. Extract important knobs (ST > 0.05)
    validated_knobs =
      indices
      |> Enum.filter(fn {_knob, %{st: st}} -> st > 0.05 end)
      |> Enum.sort_by(fn {_knob, %{st: st}} -> st end, :desc)
      |> Enum.map(fn {knob, _} -> knob end)

    # 5. Update pattern with results
    Repo.update(pattern, %{
      validated_knobs: validated_knobs,
      sobol_indices: indices,
      sobol_validated_at: DateTime.utc_now(),
      sobol_db_id: representative.db_id
    })
  end

  defp find_representative(pattern) do
    # Database closest to centroid = most typical member
    pattern
    |> get_member_databases()
    |> Enum.min_by(fn db ->
      cosine_distance(db.profile_vector, pattern.centroid_vector)
    end)
  end
end
```

### Why This Is Accurate

1. **Direct measurement**: We run actual benchmarks and measure actual performance changes
2. **Representative sample**: The database closest to the centroid is the most typical member of the pattern
3. **Statistical rigor**: Sobol analysis uses quasi-random sampling with variance decomposition to isolate each parameter's contribution
4. **Threshold filtering**: Only knobs with ST > 0.05 (>5% contribution to variance) are kept, filtering out noise

### Validation Prioritization

Not all patterns need immediate validation. Prioritize by:

1. **Member count**: Larger patterns affect more databases
2. **Tuning request frequency**: Patterns whose members request tuning more often
3. **Age**: Newly discovered patterns need validation

```elixir
def get_validation_queue do
  Repo.all(
    from p in WorkloadPattern,
    where: is_nil(p.validated_knobs),
    order_by: [desc: p.member_count, asc: p.created_at],
    limit: 10
  )
end
```

---

## Component 4: Pattern Matching at Tuning Time

When a database requests tuning:

```elixir
defmodule PgGaConf.PatternMatcher do
  @similarity_threshold 0.85

  def get_knobs_for_database(db_id) do
    # 1. Get current profile
    {:ok, profile} = RichProfiler.profile(db_id)

    # 2. Find best matching pattern
    patterns = Repo.all(
      from p in WorkloadPattern,
      where: not is_nil(p.validated_knobs)
    )

    best_match =
      patterns
      |> Enum.map(fn pattern ->
        similarity = cosine_similarity(profile.feature_vector, pattern.centroid_vector)
        {pattern, similarity}
      end)
      |> Enum.max_by(fn {_pattern, similarity} -> similarity end)

    case best_match do
      {pattern, similarity} when similarity >= @similarity_threshold ->
        # Good match - use validated knobs
        {:ok, %{
          pattern_id: pattern.id,
          similarity: similarity,
          knobs: pattern.validated_knobs,
          source: :pattern_match
        }}

      {_pattern, similarity} ->
        # No good match - needs Sobol
        {:needs_validation, %{
          best_similarity: similarity,
          recommendation: :run_sobol
        }}
    end
  end
end
```

### Handling No-Match Cases

When a database doesn't match any validated pattern:

1. **Run Sobol screening**: Use the starter knob set
2. **Create or update pattern**:
   - If the database is an outlier (noise in DBSCAN), it may form a new pattern later
   - If it's close to an unvalidated pattern, this validates that pattern
3. **Cache the result**: Store validated knobs for this database specifically

---

## Data Model

```sql
-- Profiles collected over time
CREATE TABLE database_profiles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    db_id text NOT NULL,
    captured_at timestamptz NOT NULL DEFAULT now(),

    -- Raw feature groups (for debugging/analysis)
    schema_features jsonb NOT NULL,
    query_features jsonb NOT NULL,
    runtime_features jsonb NOT NULL,
    scale_features jsonb NOT NULL,

    -- Normalized vector for similarity (31 floats)
    feature_vector float8[] NOT NULL,

    -- Flags
    has_pg_stat_statements boolean NOT NULL DEFAULT false,
    profile_duration_ms integer,

    CONSTRAINT unique_profile UNIQUE (db_id, captured_at)
);

CREATE INDEX idx_profiles_db_id ON database_profiles(db_id);
CREATE INDEX idx_profiles_captured ON database_profiles(captured_at DESC);

-- Discovered workload patterns (clusters)
CREATE TABLE workload_patterns (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Cluster geometry
    centroid_vector float8[] NOT NULL,
    radius float8,
    member_count integer NOT NULL DEFAULT 0,

    -- Sobol validation results
    validated_knobs text[],
    sobol_indices jsonb,
    sobol_validated_at timestamptz,
    sobol_db_id text,

    -- Metadata
    description text,  -- Auto-generated from centroid features
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Current pattern assignment per database
CREATE TABLE database_pattern_assignments (
    db_id text PRIMARY KEY,
    pattern_id uuid REFERENCES workload_patterns(id),
    similarity float8 NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),

    -- If no pattern match, store per-database validation
    custom_validated_knobs text[],
    custom_sobol_indices jsonb,
    custom_validated_at timestamptz
);

-- Validation job tracking
CREATE TABLE pattern_validation_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pattern_id uuid REFERENCES workload_patterns(id),
    status text NOT NULL DEFAULT 'pending',  -- pending, running, completed, failed
    representative_db_id text,
    started_at timestamptz,
    completed_at timestamptz,
    error_message text,
    sobol_samples integer,
    total_evaluations integer
);
```

---

## Accuracy Guarantees

### Why This System Is Accurate

| Claim | Evidence |
|-------|----------|
| **Profiles capture true workload nature** | 4-layer profiling includes schema structure (deterministic), query patterns (from actual pg_stat_statements), runtime behavior (time-windowed sampling), and scale (measured sizes) |
| **Patterns represent real groupings** | DBSCAN finds natural clusters with minimum size requirements; outliers are explicitly identified rather than forced into wrong clusters |
| **Knob selections are validated** | Sobol analysis directly measures each knob's impact on performance through controlled experimentation |
| **Matching is reliable** | Cosine similarity on normalized 31-dim vectors; threshold (0.85) ensures only confident matches |
| **System improves over time** | New databases add data; re-clustering finds emerging patterns; validation backlog is prioritized |

### Failure Modes and Mitigations

| Failure Mode | Mitigation |
|--------------|------------|
| pg_stat_statements not available | Query features fall back to defaults; schema/runtime/scale features still work; profile is flagged |
| Database too new (insufficient stats) | Minimum query count threshold; flag for re-profile later |
| Workload drift (pattern no longer matches) | Periodic re-profiling; drift detection triggers reassignment |
| Representative database not truly representative | Use database closest to centroid; validate on multiple databases if Sobol results are inconsistent |
| Sobol analysis on non-representative benchmark | Use actual production-like benchmark; require benchmark approval before validation |

---

## Implementation Phases

### Phase 1: Rich Profiling
- Implement 4-layer profiler
- Deploy to collect profiles from all databases
- Store in `database_profiles` table
- Build monitoring dashboard for profile data

### Phase 2: Pattern Discovery
- Implement DBSCAN clustering
- Run initial clustering on collected profiles
- Store patterns in `workload_patterns`
- Assign databases to patterns

### Phase 3: Sobol Validation
- Implement validation queue and job runner
- Validate highest-priority patterns
- Store results back to patterns

### Phase 4: Integration
- Integrate pattern matching into TuningJob
- Handle no-match cases with on-demand Sobol
- Add fallback for databases without validated patterns

### Phase 5: Continuous Learning
- Schedule periodic re-clustering
- Implement drift detection
- Add pattern evolution tracking

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Profile accuracy | Query features available for >90% of databases | Check `has_pg_stat_statements` flag |
| Pattern coverage | >80% of databases match a validated pattern | Count assignments with similarity > 0.85 |
| Validation efficiency | Validated patterns cover >90% of tuning requests | Track pattern_id usage in tuning jobs |
| Knob prediction accuracy | Validated knobs capture >80% of actual important knobs | Compare against full Sobol on sample |
| Optimization speedup | Tuning with pattern knobs achieves >90% of full-space results | A/B test validated knobs vs starter set |
