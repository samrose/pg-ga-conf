defmodule PgGaConf.Workload.RichProfiler do
  @moduledoc """
  Comprehensive workload profiler with 59 features across 7 layers.

  ## Feature Layers

  1. **Schema Structure (10 features)** - Table shapes, column types, index types
  2. **Query Patterns (15 features)** - CRUD ratios, complexity, diversity
  3. **Execution Characteristics (8 features)** - Planning, WAL, JIT, timing
  4. **I/O Patterns (6 features)** - By backend type, TOAST, buffer behavior
  5. **Index Effectiveness (4 features)** - Usage, selectivity, hot concentration
  6. **Runtime Behavior (10 features)** - QPS, connections, wait events (time-sampled)
  7. **Scale Metrics (6 features)** - Sizes, counts, growth

  ## Usage

      {:ok, profile} = RichProfiler.profile(repo)
      profile.feature_vector  # [59 normalized floats]

  ## PostgreSQL Version Compatibility

  - Tier 1 (always available): pg_class, pg_stat_database, pg_stat_user_tables
  - Tier 2 (extension required): pg_stat_statements
  - Tier 3 (version specific): pg_stat_wal (PG14+), pg_stat_io (PG16+)
  """

  require Logger

  @feature_count 59

  @type profile :: %{
          schema_features: map(),
          query_features: map(),
          execution_features: map(),
          io_features: map(),
          index_features: map(),
          runtime_features: map(),
          scale_features: map(),
          feature_vector: [float()],
          feature_count: integer(),
          has_pg_stat_statements: boolean(),
          pg_version: integer(),
          profiled_at: DateTime.t()
        }

  @doc """
  Profile the workload of the connected database.

  Returns a comprehensive profile with 59 normalized features.

  ## Options

  - `:repo` - Ecto repo to use (required or configured)
  - `:sample_window_seconds` - Duration to sample runtime metrics (default: 60)
  - `:sample_count` - Number of runtime samples to take (default: 12)
  """
  @spec profile(Ecto.Repo.t(), keyword()) :: {:ok, profile()} | {:error, term()}
  def profile(repo, opts \\ []) do
    sample_window = Keyword.get(opts, :sample_window_seconds, 60)
    sample_count = Keyword.get(opts, :sample_count, 12)

    with {:ok, pg_version} <- get_pg_version(repo),
         {:ok, schema} <- profile_schema(repo),
         {:ok, queries} <- profile_queries(repo),
         {:ok, execution} <- profile_execution(repo, pg_version),
         {:ok, io} <- profile_io(repo, pg_version),
         {:ok, indexes} <- profile_indexes(repo),
         {:ok, runtime} <- profile_runtime(repo, sample_window, sample_count),
         {:ok, scale} <- profile_scale(repo) do
      feature_vector =
        build_feature_vector(schema, queries, execution, io, indexes, runtime, scale)

      {:ok,
       %{
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
         pg_version: pg_version,
         profiled_at: DateTime.utc_now()
       }}
    end
  end

  @doc """
  Quick profile without time-sampled runtime metrics.

  Faster but less accurate for QPS and connection patterns.
  """
  @spec quick_profile(Ecto.Repo.t(), keyword()) :: {:ok, profile()} | {:error, term()}
  def quick_profile(repo, opts \\ []) do
    profile(repo, Keyword.merge(opts, sample_window_seconds: 0, sample_count: 1))
  end

  @doc """
  Returns just the 59-element feature vector.
  """
  @spec feature_vector(Ecto.Repo.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def feature_vector(repo, opts \\ []) do
    case profile(repo, opts) do
      {:ok, profile} -> {:ok, profile.feature_vector}
      error -> error
    end
  end

  # ============================================================================
  # Layer 1: Schema Structure (10 features)
  # ============================================================================

  defp profile_schema(repo) do
    query = """
    WITH table_analysis AS (
        SELECT
            c.oid,
            c.relname,
            c.relkind,
            c.relispartition,
            (SELECT COUNT(*) FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS column_count,
            (SELECT COUNT(*) FROM pg_attribute a
             JOIN pg_type t ON t.oid = a.atttypid
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               AND t.typname = 'jsonb') AS jsonb_cols,
            (SELECT COUNT(*) FROM pg_attribute a
             JOIN pg_type t ON t.oid = a.atttypid
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               AND t.typname LIKE '%\\[\\]' ESCAPE '\\\\') AS array_cols,
            (SELECT COUNT(*) FROM pg_attribute a
             JOIN pg_type t ON t.oid = a.atttypid
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               AND t.typname IN ('text', 'varchar', 'char', 'bpchar')) AS text_cols,
            (SELECT COUNT(*) FROM pg_attribute a
             JOIN pg_type t ON t.oid = a.atttypid
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               AND t.typname IN ('timestamp', 'timestamptz', 'date')) AS time_cols
        FROM pg_class c
        WHERE c.relkind IN ('r', 'p')
          AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
    ),
    index_types AS (
        SELECT
            am.amname,
            COUNT(*)::float AS count
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am am ON am.oid = c.relam
        WHERE c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
        GROUP BY am.amname
    ),
    index_totals AS (
        SELECT COALESCE(SUM(count), 0) AS total FROM index_types
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
        COALESCE(COUNT(*), 0)::float AS table_count,
        COALESCE(AVG(column_count), 0)::float AS avg_columns,
        COALESCE(SUM(jsonb_cols)::float / NULLIF(SUM(column_count), 0), 0) AS jsonb_ratio,
        COALESCE(SUM(array_cols)::float / NULLIF(SUM(column_count), 0), 0) AS array_ratio,
        COALESCE(SUM(text_cols)::float / NULLIF(SUM(column_count), 0), 0) AS text_ratio,
        COALESCE(COUNT(*) FILTER (WHERE time_cols > 0)::float / NULLIF(COUNT(*), 0), 0) AS timeseries_ratio,
        COALESCE(COUNT(*) FILTER (WHERE relkind = 'p' OR relispartition)::float / NULLIF(COUNT(*), 0), 0) AS partitioned_ratio,
        COALESCE((SELECT count FROM index_types WHERE amname = 'gin') / NULLIF((SELECT total FROM index_totals), 0), 0) AS gin_index_ratio,
        COALESCE((SELECT count FROM index_types WHERE amname = 'gist') / NULLIF((SELECT total FROM index_totals), 0), 0) AS gist_index_ratio,
        COALESCE((SELECT fk_count FROM constraints)::float / NULLIF(COUNT(*), 0), 0) AS fk_density
    FROM table_analysis
    """

    case repo.query(query) do
      {:ok, %{rows: [[tc, ac, jr, ar, tr, tsr, pr, gir, gisr, fkd]]}} ->
        {:ok,
         %{
           table_count: to_float(tc),
           avg_columns: to_float(ac),
           jsonb_ratio: to_float(jr),
           array_ratio: to_float(ar),
           text_ratio: to_float(tr),
           timeseries_ratio: to_float(tsr),
           partitioned_ratio: to_float(pr),
           gin_index_ratio: to_float(gir),
           gist_index_ratio: to_float(gisr),
           fk_density: to_float(fkd)
         }}

      {:ok, %{rows: []}} ->
        {:ok, default_schema_features()}

      {:error, reason} ->
        Logger.warning("Schema profiling failed: #{inspect(reason)}")
        {:ok, default_schema_features()}
    end
  end

  # ============================================================================
  # Layer 2: Query Patterns (15 features)
  # ============================================================================

  defp profile_queries(repo) do
    # Check if pg_stat_statements is available
    case check_pg_stat_statements(repo) do
      true -> profile_queries_with_statements(repo)
      false -> {:ok, default_query_features()}
    end
  end

  defp check_pg_stat_statements(repo) do
    query = "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'"

    case repo.query(query) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp profile_queries_with_statements(repo) do
    query = """
    WITH query_stats AS (
        SELECT
            queryid,
            query,
            calls,
            rows,
            shared_blks_hit,
            shared_blks_read,
            temp_blks_read + temp_blks_written AS temp_blks
        FROM pg_stat_statements
        WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    ),
    query_classification AS (
        SELECT
            queryid,
            calls,
            rows,
            shared_blks_hit,
            shared_blks_read,
            temp_blks,
            CASE
                WHEN query ~* '^\\s*(SELECT|WITH\\s+\\w+\\s+AS\\s*\\(?\\s*SELECT)' THEN 'select'
                WHEN query ~* '^\\s*INSERT' THEN 'insert'
                WHEN query ~* '^\\s*UPDATE' THEN 'update'
                WHEN query ~* '^\\s*DELETE' THEN 'delete'
                ELSE 'other'
            END AS query_type,
            (length(query) - length(replace(lower(query), ' join ', ''))) / 6 AS join_count,
            (query ~* '\\bGROUP\\s+BY\\b' OR query ~* '\\bHAVING\\b')::int AS has_aggregate,
            (query ~* '\\bWINDOW\\b' OR query ~* '\\bOVER\\s*\\(')::int AS has_window,
            (query ~* '\\bWITH\\s+\\w+\\s+AS\\b')::int AS has_cte,
            (query ~* '->>|->|@>|<@|\\?|\\?\\||\\?\\&')::int AS has_json_ops,
            (query ~ '\\$[0-9]+')::int AS is_parameterized
        FROM query_stats
    ),
    aggregated AS (
        SELECT
            SUM(calls) AS total_calls,
            COUNT(DISTINCT queryid) AS distinct_queries,
            SUM(calls) FILTER (WHERE query_type = 'select') AS select_calls,
            SUM(calls) FILTER (WHERE query_type = 'insert') AS insert_calls,
            SUM(calls) FILTER (WHERE query_type = 'update') AS update_calls,
            SUM(calls) FILTER (WHERE query_type = 'delete') AS delete_calls,
            SUM(calls) FILTER (WHERE join_count >= 1) AS join_calls,
            SUM(calls) FILTER (WHERE has_aggregate = 1) AS aggregate_calls,
            SUM(calls) FILTER (WHERE has_window = 1) AS window_calls,
            SUM(calls) FILTER (WHERE has_cte = 1) AS cte_calls,
            SUM(calls) FILTER (WHERE has_json_ops = 1) AS json_calls,
            SUM(calls) FILTER (WHERE is_parameterized = 1) AS param_calls,
            SUM(rows) AS total_rows,
            SUM(shared_blks_hit) AS total_hits,
            SUM(shared_blks_read) AS total_reads,
            COUNT(*) FILTER (WHERE temp_blks > 0) AS spilling_queries
        FROM query_classification
    ),
    top10 AS (
        SELECT COALESCE(SUM(calls), 0) AS top10_calls
        FROM (SELECT calls FROM query_classification ORDER BY calls DESC LIMIT 10) t
    )
    SELECT
        COALESCE(select_calls::float / NULLIF(total_calls, 0), 0) AS select_ratio,
        COALESCE(insert_calls::float / NULLIF(total_calls, 0), 0) AS insert_ratio,
        COALESCE(update_calls::float / NULLIF(total_calls, 0), 0) AS update_ratio,
        COALESCE(delete_calls::float / NULLIF(total_calls, 0), 0) AS delete_ratio,
        COALESCE(join_calls::float / NULLIF(total_calls, 0), 0) AS join_ratio,
        COALESCE(aggregate_calls::float / NULLIF(total_calls, 0), 0) AS aggregate_ratio,
        COALESCE(window_calls::float / NULLIF(total_calls, 0), 0) AS window_ratio,
        COALESCE(cte_calls::float / NULLIF(total_calls, 0), 0) AS cte_ratio,
        COALESCE(json_calls::float / NULLIF(total_calls, 0), 0) AS json_ratio,
        COALESCE(param_calls::float / NULLIF(total_calls, 0), 0) AS parameterized_ratio,
        COALESCE(distinct_queries::float / NULLIF(total_calls, 0), 0) AS query_diversity,
        COALESCE((SELECT top10_calls FROM top10)::float / NULLIF(total_calls, 0), 0) AS hot_concentration,
        COALESCE(total_rows::float / NULLIF(total_calls, 0), 0) AS avg_rows_per_call,
        COALESCE(total_hits::float / NULLIF(total_hits + total_reads, 0), 0) AS cache_hit_ratio,
        COALESCE(spilling_queries::float / NULLIF(distinct_queries, 0), 0) AS temp_spill_ratio
    FROM aggregated
    """

    case repo.query(query) do
      {:ok, %{rows: [[sr, ir, ur, dr, jr, ar, wr, cr, jsr, pr, qd, hc, arpc, chr, tsr]]}} ->
        {:ok,
         %{
           select_ratio: to_float(sr),
           insert_ratio: to_float(ir),
           update_ratio: to_float(ur),
           delete_ratio: to_float(dr),
           join_ratio: to_float(jr),
           aggregate_ratio: to_float(ar),
           window_ratio: to_float(wr),
           cte_ratio: to_float(cr),
           json_ratio: to_float(jsr),
           parameterized_ratio: to_float(pr),
           query_diversity: to_float(qd),
           hot_concentration: to_float(hc),
           avg_rows_per_call: to_float(arpc),
           cache_hit_ratio: to_float(chr),
           temp_spill_ratio: to_float(tsr),
           has_pg_stat_statements: true
         }}

      {:ok, %{rows: []}} ->
        {:ok, Map.put(default_query_features(), :has_pg_stat_statements, true)}

      {:error, reason} ->
        Logger.warning("Query profiling failed: #{inspect(reason)}")
        {:ok, default_query_features()}
    end
  end

  # ============================================================================
  # Layer 3: Execution Characteristics (8 features)
  # ============================================================================

  defp profile_execution(repo, pg_version) do
    # Base query for pg_stat_statements metrics
    base_query = """
    SELECT
        COALESCE(SUM(total_plan_time), 0) AS total_plan_time,
        COALESCE(SUM(total_exec_time), 0) AS total_exec_time,
        COALESCE(SUM(calls), 0) AS total_calls,
        COALESCE(SUM(blk_read_time), 0) AS total_blk_read_time,
        COALESCE(STDDEV(mean_exec_time), 0) AS exec_time_stddev,
        COALESCE(AVG(mean_exec_time), 0) AS exec_time_mean
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    """

    # WAL stats (PG 13+ in pg_stat_statements, PG 14+ has pg_stat_wal)
    wal_query =
      if pg_version >= 130_000 do
        """
        SELECT
            COALESCE(SUM(wal_bytes), 0) AS total_wal_bytes,
            COALESCE(SUM(wal_fpi), 0) AS total_fpi,
            COALESCE(SUM(wal_records), 0) AS total_wal_records
        FROM pg_stat_statements
        WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        """
      else
        nil
      end

    # pg_stat_wal for buffer pressure (PG 14+)
    wal_buffer_query =
      if pg_version >= 140_000 do
        """
        SELECT
            COALESCE(wal_buffers_full, 0) AS wal_buffers_full,
            COALESCE(wal_write, 0) AS wal_write
        FROM pg_stat_wal
        """
      else
        nil
      end

    # JIT stats (PG 15+ in pg_stat_statements)
    jit_query =
      if pg_version >= 150_000 do
        """
        SELECT
            COUNT(*) FILTER (WHERE jit_functions > 0) AS jit_queries,
            COUNT(*) AS total_queries
        FROM pg_stat_statements
        WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        """
      else
        nil
      end

    # Function time
    func_query = """
    SELECT COALESCE(SUM(total_time), 0) AS total_func_time
    FROM pg_stat_user_functions
    """

    with {:ok, base} <- safe_query(repo, base_query, [:total_plan_time, :total_exec_time, :total_calls, :total_blk_read_time, :exec_time_stddev, :exec_time_mean]),
         {:ok, wal} <- safe_query_optional(repo, wal_query, [:total_wal_bytes, :total_fpi, :total_wal_records]),
         {:ok, wal_buf} <- safe_query_optional(repo, wal_buffer_query, [:wal_buffers_full, :wal_write]),
         {:ok, jit} <- safe_query_optional(repo, jit_query, [:jit_queries, :total_queries]),
         {:ok, func} <- safe_query(repo, func_query, [:total_func_time]) do
      planning_overhead =
        if base.total_exec_time > 0,
          do: base.total_plan_time / base.total_exec_time,
          else: 0.0

      exec_time_cv =
        if base.exec_time_mean > 0,
          do: base.exec_time_stddev / base.exec_time_mean,
          else: 0.0

      wal_bytes_per_call =
        if base.total_calls > 0,
          do: Map.get(wal, :total_wal_bytes, 0) / base.total_calls,
          else: 0.0

      jit_ratio =
        if Map.get(jit, :total_queries, 0) > 0,
          do: Map.get(jit, :jit_queries, 0) / jit.total_queries,
          else: 0.0

      blk_read_time_ratio =
        if base.total_exec_time > 0,
          do: base.total_blk_read_time / base.total_exec_time,
          else: 0.0

      fpi_ratio =
        if Map.get(wal, :total_wal_records, 0) > 0,
          do: Map.get(wal, :total_fpi, 0) / wal.total_wal_records,
          else: 0.0

      wal_buffer_pressure =
        if Map.get(wal_buf, :wal_write, 0) > 0,
          do: Map.get(wal_buf, :wal_buffers_full, 0) / wal_buf.wal_write,
          else: 0.0

      function_time_ratio =
        if base.total_exec_time > 0,
          do: func.total_func_time / base.total_exec_time,
          else: 0.0

      {:ok,
       %{
         planning_overhead: planning_overhead,
         exec_time_cv: exec_time_cv,
         wal_bytes_per_call: wal_bytes_per_call,
         jit_ratio: jit_ratio,
         blk_read_time_ratio: blk_read_time_ratio,
         fpi_ratio: fpi_ratio,
         wal_buffer_pressure: wal_buffer_pressure,
         function_time_ratio: function_time_ratio
       }}
    else
      {:error, reason} ->
        Logger.warning("Execution profiling failed: #{inspect(reason)}")
        {:ok, default_execution_features()}
    end
  end

  # ============================================================================
  # Layer 4: I/O Patterns (6 features)
  # ============================================================================

  defp profile_io(repo, pg_version) do
    if pg_version >= 160_000 do
      profile_io_pg16(repo)
    else
      profile_io_fallback(repo)
    end
  end

  defp profile_io_pg16(repo) do
    query = """
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
            SUM(evictions) AS total_evictions,
            SUM(reuses) AS total_reuses
        FROM io_by_backend
    ),
    io_by_context AS (
        SELECT context, SUM(reads) AS reads, SUM(extends) AS extends
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
        COALESCE((SELECT reads + writes FROM io_by_backend WHERE backend_type = 'autovacuum worker')::float /
            NULLIF((SELECT total_reads + total_writes FROM io_totals), 0), 0) AS autovacuum_io_ratio,
        COALESCE((SELECT writes FROM io_by_backend WHERE backend_type = 'checkpointer')::float /
            NULLIF((SELECT total_writes FROM io_totals), 0), 0) AS checkpoint_write_ratio,
        COALESCE((SELECT reads FROM io_by_context WHERE context = 'bulkread')::float /
            NULLIF((SELECT total_reads FROM io_totals), 0), 0) AS bulkread_ratio,
        COALESCE((SELECT extends FROM io_by_context WHERE context = 'normal')::float /
            NULLIF((SELECT total_writes FROM io_totals), 0), 0) AS extend_ratio,
        COALESCE((SELECT total_reuses FROM io_totals)::float /
            NULLIF((SELECT total_reuses + total_evictions FROM io_totals), 0), 0) AS buffer_reuse_ratio,
        COALESCE((SELECT toast_blks::float / NULLIF(heap_blks, 0) FROM toast_stats), 0) AS toast_ratio
    """

    case repo.query(query) do
      {:ok, %{rows: [[avr, cwr, brr, er, brur, tr]]}} ->
        {:ok,
         %{
           autovacuum_io_ratio: to_float(avr),
           checkpoint_write_ratio: to_float(cwr),
           bulkread_ratio: to_float(brr),
           extend_ratio: to_float(er),
           buffer_reuse_ratio: to_float(brur),
           toast_ratio: to_float(tr)
         }}

      {:error, reason} ->
        Logger.warning("I/O profiling (PG16) failed: #{inspect(reason)}")
        profile_io_fallback(repo)
    end
  end

  defp profile_io_fallback(repo) do
    # Fallback for older PG versions - use bgwriter stats and statio
    query = """
    WITH bgw AS (
        SELECT
            buffers_checkpoint,
            buffers_clean,
            buffers_backend,
            buffers_alloc
        FROM pg_stat_bgwriter
    ),
    toast_stats AS (
        SELECT
            SUM(toast_blks_read + toast_blks_hit) AS toast_blks,
            SUM(heap_blks_read + heap_blks_hit) AS heap_blks
        FROM pg_statio_user_tables
    )
    SELECT
        0.0 AS autovacuum_io_ratio,
        COALESCE((SELECT buffers_checkpoint::float /
            NULLIF(buffers_checkpoint + buffers_clean + buffers_backend, 0) FROM bgw), 0) AS checkpoint_write_ratio,
        0.0 AS bulkread_ratio,
        0.0 AS extend_ratio,
        0.5 AS buffer_reuse_ratio,
        COALESCE((SELECT toast_blks::float / NULLIF(heap_blks, 0) FROM toast_stats), 0) AS toast_ratio
    """

    case repo.query(query) do
      {:ok, %{rows: [[avr, cwr, brr, er, brur, tr]]}} ->
        {:ok,
         %{
           autovacuum_io_ratio: to_float(avr),
           checkpoint_write_ratio: to_float(cwr),
           bulkread_ratio: to_float(brr),
           extend_ratio: to_float(er),
           buffer_reuse_ratio: to_float(brur),
           toast_ratio: to_float(tr)
         }}

      {:error, reason} ->
        Logger.warning("I/O profiling (fallback) failed: #{inspect(reason)}")
        {:ok, default_io_features()}
    end
  end

  # ============================================================================
  # Layer 5: Index Effectiveness (4 features)
  # ============================================================================

  defp profile_indexes(repo) do
    query = """
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
        SELECT COALESCE(SUM(idx_scan), 0) AS top5_scans
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
        COALESCE(unused_indexes::float / NULLIF(total_indexes, 0), 0) AS unused_index_ratio,
        COALESCE(avg_selectivity, 0) AS index_selectivity,
        COALESCE((SELECT top5_scans FROM top_indexes)::float / NULLIF(total_scans, 0), 0) AS index_hot_concentration,
        COALESCE((SELECT index_size::float / NULLIF(table_size, 0) FROM sizes), 0) AS index_size_ratio
    FROM aggregated
    """

    case repo.query(query) do
      {:ok, %{rows: [[uir, is, ihc, isr]]}} ->
        {:ok,
         %{
           unused_index_ratio: to_float(uir),
           index_selectivity: to_float(is),
           index_hot_concentration: to_float(ihc),
           index_size_ratio: to_float(isr)
         }}

      {:ok, %{rows: []}} ->
        {:ok, default_index_features()}

      {:error, reason} ->
        Logger.warning("Index profiling failed: #{inspect(reason)}")
        {:ok, default_index_features()}
    end
  end

  # ============================================================================
  # Layer 6: Runtime Behavior (10 features) - Time Sampled
  # ============================================================================

  defp profile_runtime(repo, window_seconds, sample_count) do
    if window_seconds == 0 or sample_count <= 1 do
      # Single snapshot mode
      case sample_runtime_snapshot(repo) do
        {:ok, snapshot} ->
          {:ok,
           %{
             qps_mean: 0.0,
             qps_cv: 0.0,
             connections_mean: to_float(snapshot.total_backends),
             connections_cv: 0.0,
             active_ratio: to_float(snapshot.active_ratio),
             wait_io_ratio: to_float(snapshot.wait_io_ratio),
             wait_lock_ratio: to_float(snapshot.wait_lock_ratio),
             wait_lwlock_ratio: to_float(snapshot.wait_lwlock_ratio),
             wait_client_ratio: to_float(snapshot.wait_client_ratio),
             lock_wait_ratio: to_float(snapshot.lock_wait_ratio)
           }}

        error ->
          error
      end
    else
      sample_runtime_over_time(repo, window_seconds, sample_count)
    end
  end

  defp sample_runtime_over_time(repo, window_seconds, sample_count) do
    interval_ms = div(window_seconds * 1000, sample_count)

    samples =
      Enum.map(1..sample_count, fn i ->
        if i > 1 and interval_ms > 0, do: Process.sleep(interval_ms)

        xacts = get_xact_count(repo)

        case sample_runtime_snapshot(repo) do
          {:ok, snapshot} ->
            %{
              timestamp: System.monotonic_time(:millisecond),
              xacts: xacts,
              snapshot: snapshot
            }

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if length(samples) < 2 do
      {:ok, default_runtime_features()}
    else
      # Calculate QPS from xact deltas
      qps_values =
        samples
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [s1, s2] ->
          dt_seconds = (s2.timestamp - s1.timestamp) / 1000
          if dt_seconds > 0, do: (s2.xacts - s1.xacts) / dt_seconds, else: 0.0
        end)

      connections = Enum.map(samples, & &1.snapshot.total_backends)

      qps_mean = mean(qps_values)
      qps_cv = cv(qps_values)
      conn_mean = mean(connections)
      conn_cv = cv(connections)

      # Average the snapshot ratios
      {:ok,
       %{
         qps_mean: qps_mean,
         qps_cv: qps_cv,
         connections_mean: conn_mean,
         connections_cv: conn_cv,
         active_ratio: mean(Enum.map(samples, & &1.snapshot.active_ratio)),
         wait_io_ratio: mean(Enum.map(samples, & &1.snapshot.wait_io_ratio)),
         wait_lock_ratio: mean(Enum.map(samples, & &1.snapshot.wait_lock_ratio)),
         wait_lwlock_ratio: mean(Enum.map(samples, & &1.snapshot.wait_lwlock_ratio)),
         wait_client_ratio: mean(Enum.map(samples, & &1.snapshot.wait_client_ratio)),
         lock_wait_ratio: mean(Enum.map(samples, & &1.snapshot.lock_wait_ratio))
       }}
    end
  end

  defp sample_runtime_snapshot(repo) do
    activity_query = """
    SELECT
        COUNT(*) AS total_backends,
        COUNT(*) FILTER (WHERE state = 'active') AS active_backends,
        COUNT(*) FILTER (WHERE wait_event_type = 'IO') AS wait_io,
        COUNT(*) FILTER (WHERE wait_event_type = 'Lock') AS wait_lock,
        COUNT(*) FILTER (WHERE wait_event_type = 'LWLock') AS wait_lwlock,
        COUNT(*) FILTER (WHERE wait_event_type = 'Client') AS wait_client
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
      AND pid != pg_backend_pid()
    """

    lock_query = """
    SELECT
        COUNT(*) FILTER (WHERE NOT granted)::float /
            NULLIF(COUNT(*), 0) AS wait_ratio
    FROM pg_locks
    WHERE pid != pg_backend_pid()
    """

    with {:ok, %{rows: [[tb, ab, wio, wl, wlw, wc]]}} <- repo.query(activity_query),
         {:ok, %{rows: [[lwr]]}} <- repo.query(lock_query) do
      total = to_float(tb)
      waiting = to_float(wio) + to_float(wl) + to_float(wlw)

      {:ok,
       %{
         total_backends: total,
         active_ratio: if(total > 0, do: to_float(ab) / total, else: 0.0),
         wait_io_ratio: if(waiting > 0, do: to_float(wio) / waiting, else: 0.0),
         wait_lock_ratio: if(waiting > 0, do: to_float(wl) / waiting, else: 0.0),
         wait_lwlock_ratio: if(waiting > 0, do: to_float(wlw) / waiting, else: 0.0),
         wait_client_ratio: if(total > 0, do: to_float(wc) / total, else: 0.0),
         lock_wait_ratio: to_float(lwr)
       }}
    else
      _ -> {:ok, default_runtime_snapshot()}
    end
  end

  defp get_xact_count(repo) do
    query = """
    SELECT xact_commit + xact_rollback
    FROM pg_stat_database
    WHERE datname = current_database()
    """

    case repo.query(query) do
      {:ok, %{rows: [[count]]}} -> to_float(count)
      _ -> 0.0
    end
  end

  # ============================================================================
  # Layer 7: Scale Metrics (6 features)
  # ============================================================================

  defp profile_scale(repo) do
    query = """
    SELECT
        pg_database_size(current_database())::float / (1024*1024*1024) AS db_size_gb,
        (SELECT COALESCE(MAX(pg_total_relation_size(oid)), 0)::float / (1024*1024*1024)
         FROM pg_class WHERE relkind = 'r'
         AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
        ) AS largest_table_gb,
        (SELECT COALESCE(SUM(pg_indexes_size(oid)), 0)::float / (1024*1024*1024)
         FROM pg_class WHERE relkind = 'r'
         AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
        ) AS total_index_gb,
        (SELECT COUNT(*) FROM pg_class WHERE relkind IN ('r', 'p')
         AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
        ) AS table_count,
        (SELECT COALESCE(SUM(reltuples), 0) FROM pg_class WHERE relkind = 'r'
         AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
        ) AS estimated_rows,
        (SELECT COALESCE(AVG(
            (SELECT COALESCE(SUM(avg_width), 0) FROM pg_stats s WHERE s.tablename = c.relname)
         ), 0) FROM pg_class c WHERE relkind = 'r'
         AND relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
        ) AS avg_row_width
    """

    case repo.query(query) do
      {:ok, %{rows: [[dsg, ltg, tig, tc, er, arw]]}} ->
        {:ok,
         %{
           db_size_gb: to_float(dsg),
           largest_table_gb: to_float(ltg),
           total_index_gb: to_float(tig),
           table_count: to_float(tc),
           estimated_rows: to_float(er),
           avg_row_width: to_float(arw)
         }}

      {:error, reason} ->
        Logger.warning("Scale profiling failed: #{inspect(reason)}")
        {:ok, default_scale_features()}
    end
  end

  # ============================================================================
  # Feature Vector Assembly
  # ============================================================================

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

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_pg_version(repo) do
    query = "SHOW server_version_num"

    case repo.query(query) do
      {:ok, %{rows: [[version_str]]}} ->
        {:ok, String.to_integer(version_str)}

      {:error, reason} ->
        {:error, {:version_check_failed, reason}}
    end
  end

  defp safe_query(repo, query, columns) do
    case repo.query(query) do
      {:ok, %{rows: [row]}} ->
        {:ok, Enum.zip(columns, row) |> Map.new(fn {k, v} -> {k, to_float(v)} end)}

      {:ok, %{rows: []}} ->
        {:ok, Map.new(columns, fn k -> {k, 0.0} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_query_optional(_repo, nil, columns) do
    {:ok, Map.new(columns, fn k -> {k, 0.0} end)}
  end

  defp safe_query_optional(repo, query, columns) do
    case repo.query(query) do
      {:ok, %{rows: [row]}} ->
        {:ok, Enum.zip(columns, row) |> Map.new(fn {k, v} -> {k, to_float(v)} end)}

      _ ->
        {:ok, Map.new(columns, fn k -> {k, 0.0} end)}
    end
  end

  defp normalize_log(value, max_expected) when is_number(value) and value > 0 do
    :math.log(value + 1) / :math.log(max_expected + 1)
  end

  defp normalize_log(_, _), do: 0.0

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n
  defp to_float(s) when is_binary(s), do: String.to_float(s)
  defp to_float(_), do: 0.0

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp cv([]), do: 0.0

  defp cv(values) do
    m = mean(values)
    if m == 0, do: 0.0, else: stddev(values) / m
  end

  defp stddev([]), do: 0.0

  defp stddev(values) do
    m = mean(values)
    n = length(values)
    variance = Enum.map(values, fn v -> (v - m) * (v - m) end) |> Enum.sum() |> Kernel./(n)
    :math.sqrt(variance)
  end

  # ============================================================================
  # Default Values
  # ============================================================================

  defp default_schema_features do
    %{
      table_count: 0.0,
      avg_columns: 0.0,
      jsonb_ratio: 0.0,
      array_ratio: 0.0,
      text_ratio: 0.0,
      timeseries_ratio: 0.0,
      partitioned_ratio: 0.0,
      gin_index_ratio: 0.0,
      gist_index_ratio: 0.0,
      fk_density: 0.0
    }
  end

  defp default_query_features do
    %{
      select_ratio: 0.0,
      insert_ratio: 0.0,
      update_ratio: 0.0,
      delete_ratio: 0.0,
      join_ratio: 0.0,
      aggregate_ratio: 0.0,
      window_ratio: 0.0,
      cte_ratio: 0.0,
      json_ratio: 0.0,
      parameterized_ratio: 0.0,
      query_diversity: 0.0,
      hot_concentration: 0.0,
      avg_rows_per_call: 0.0,
      cache_hit_ratio: 0.0,
      temp_spill_ratio: 0.0,
      has_pg_stat_statements: false
    }
  end

  defp default_execution_features do
    %{
      planning_overhead: 0.0,
      exec_time_cv: 0.0,
      wal_bytes_per_call: 0.0,
      jit_ratio: 0.0,
      blk_read_time_ratio: 0.0,
      fpi_ratio: 0.0,
      wal_buffer_pressure: 0.0,
      function_time_ratio: 0.0
    }
  end

  defp default_io_features do
    %{
      autovacuum_io_ratio: 0.0,
      checkpoint_write_ratio: 0.0,
      bulkread_ratio: 0.0,
      extend_ratio: 0.0,
      buffer_reuse_ratio: 0.5,
      toast_ratio: 0.0
    }
  end

  defp default_index_features do
    %{
      unused_index_ratio: 0.0,
      index_selectivity: 0.0,
      index_hot_concentration: 0.0,
      index_size_ratio: 0.0
    }
  end

  defp default_runtime_features do
    %{
      qps_mean: 0.0,
      qps_cv: 0.0,
      connections_mean: 0.0,
      connections_cv: 0.0,
      active_ratio: 0.0,
      wait_io_ratio: 0.0,
      wait_lock_ratio: 0.0,
      wait_lwlock_ratio: 0.0,
      wait_client_ratio: 0.0,
      lock_wait_ratio: 0.0
    }
  end

  defp default_runtime_snapshot do
    %{
      total_backends: 0.0,
      active_ratio: 0.0,
      wait_io_ratio: 0.0,
      wait_lock_ratio: 0.0,
      wait_lwlock_ratio: 0.0,
      wait_client_ratio: 0.0,
      lock_wait_ratio: 0.0
    }
  end

  defp default_scale_features do
    %{
      db_size_gb: 0.0,
      largest_table_gb: 0.0,
      total_index_gb: 0.0,
      table_count: 0.0,
      estimated_rows: 0.0,
      avg_row_width: 0.0
    }
  end
end
