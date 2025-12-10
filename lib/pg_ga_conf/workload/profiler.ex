defmodule PgGaConf.Workload.Profiler do
  @moduledoc """
  Enhanced workload profiling with 25+ features from multiple pg_stat_* sources.

  Collects metrics from:
  - pg_stat_statements (query patterns)
  - pg_stat_user_tables (access patterns)
  - pg_stat_activity (concurrency and wait events)
  - pg_stat_bgwriter (checkpoint pressure)
  - pg_stat_database (database-level stats)

  Returns a normalized profile that can be used for workload classification.
  """

  alias PgGaConf.Repo

  require Logger

  @type profile :: %{
          # Query pattern features
          avg_rows_per_query: float(),
          query_complexity: float(),
          cache_miss_ratio: float(),
          temp_spill_ratio: float(),
          avg_exec_time_ms: float(),
          read_query_ratio: float(),

          # Access pattern features
          seq_scan_ratio: float(),
          index_scan_ratio: float(),
          heap_hit_ratio: float(),
          index_hit_ratio: float(),
          rows_per_seq_scan: float(),
          rows_per_idx_scan: float(),

          # Write pattern features
          write_ratio: float(),
          insert_ratio: float(),
          update_ratio: float(),
          delete_ratio: float(),
          hot_update_ratio: float(),

          # Vacuum pressure features
          dead_tuple_ratio: float(),
          tables_needing_vacuum_ratio: float(),

          # Concurrency features
          connection_utilization: float(),
          active_query_ratio: float(),

          # Wait event features
          io_wait_ratio: float(),
          lock_wait_ratio: float(),
          lwlock_wait_ratio: float(),
          client_wait_ratio: float(),

          # Checkpoint/WAL features
          checkpoint_pressure: float(),
          backend_write_ratio: float(),

          # I/O features
          blk_read_time_ratio: float(),
          blk_write_time_ratio: float(),

          # Metadata
          total_queries: integer(),
          has_pg_stat_statements: boolean()
        }

  @doc """
  Profile the workload of the connected database.

  Returns a normalized profile map with 25+ features.

  ## Options

  - `:repo` - Ecto repo to use (default: PgGaConf.Repo)
  - `:sample_duration_ms` - Duration to sample pg_stat_activity (default: 1000)
  - `:activity_samples` - Number of pg_stat_activity samples to take (default: 5)
  """
  @spec profile(keyword()) :: {:ok, profile()} | {:error, term()}
  def profile(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    sample_duration = Keyword.get(opts, :sample_duration_ms, 1000)
    activity_samples = Keyword.get(opts, :activity_samples, 5)

    with {:ok, stmt_stats} <- fetch_statement_stats(repo),
         {:ok, table_stats} <- fetch_table_stats(repo),
         {:ok, activity_stats} <- fetch_activity_stats(repo, sample_duration, activity_samples),
         {:ok, bgwriter_stats} <- fetch_bgwriter_stats(repo),
         {:ok, db_stats} <- fetch_database_stats(repo),
         {:ok, settings} <- fetch_settings(repo) do
      profile = compute_profile(stmt_stats, table_stats, activity_stats, bgwriter_stats, db_stats, settings)
      {:ok, profile}
    end
  end

  @doc """
  Quick profile without pg_stat_activity sampling.

  Faster but less accurate for concurrency/wait event metrics.
  """
  @spec quick_profile(keyword()) :: {:ok, profile()} | {:error, term()}
  def quick_profile(opts \\ []) do
    profile(Keyword.merge(opts, activity_samples: 1, sample_duration_ms: 0))
  end

  # ============================================================================
  # Data Collection
  # ============================================================================

  defp fetch_statement_stats(repo) do
    # Check if pg_stat_statements is available
    check_query = "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'"

    case repo.query(check_query) do
      {:ok, %{rows: [[1]]}} ->
        fetch_statement_stats_impl(repo)

      _ ->
        Logger.info("pg_stat_statements not available, using defaults")
        {:ok, default_statement_stats()}
    end
  end

  defp fetch_statement_stats_impl(repo) do
    query = """
    SELECT
      COUNT(*) AS total_queries,
      COALESCE(SUM(calls), 0) AS total_calls,
      COALESCE(SUM(rows), 0) AS total_rows,
      COALESCE(SUM(total_exec_time), 0) AS total_exec_time,
      COALESCE(SUM(shared_blks_hit), 0) AS total_shared_blks_hit,
      COALESCE(SUM(shared_blks_read), 0) AS total_shared_blks_read,
      COALESCE(SUM(temp_blks_read + temp_blks_written), 0) AS total_temp_blks,
      COUNT(*) FILTER (WHERE temp_blks_written > 0) AS queries_with_temp,
      COUNT(*) FILTER (WHERE query ~* '^\\s*(SELECT|WITH.+SELECT)') AS select_queries
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        stats = row_to_map(columns, row)
        {:ok, Map.put(stats, :has_pg_stat_statements, true)}

      {:ok, %{rows: []}} ->
        {:ok, Map.put(default_statement_stats(), :has_pg_stat_statements, true)}

      {:error, reason} ->
        Logger.warning("Failed to fetch pg_stat_statements: #{inspect(reason)}")
        {:ok, default_statement_stats()}
    end
  end

  defp fetch_table_stats(repo) do
    query = """
    SELECT
      COALESCE(SUM(seq_scan), 0) AS seq_scan,
      COALESCE(SUM(seq_tup_read), 0) AS seq_tup_read,
      COALESCE(SUM(idx_scan), 0) AS idx_scan,
      COALESCE(SUM(idx_tup_fetch), 0) AS idx_tup_fetch,
      COALESCE(SUM(n_tup_ins), 0) AS n_tup_ins,
      COALESCE(SUM(n_tup_upd), 0) AS n_tup_upd,
      COALESCE(SUM(n_tup_del), 0) AS n_tup_del,
      COALESCE(SUM(n_tup_hot_upd), 0) AS n_tup_hot_upd,
      COALESCE(SUM(n_live_tup), 0) AS n_live_tup,
      COALESCE(SUM(n_dead_tup), 0) AS n_dead_tup,
      COUNT(*) AS total_tables,
      COUNT(*) FILTER (WHERE n_dead_tup > n_live_tup * 0.1 AND n_live_tup > 0) AS tables_need_vacuum
    FROM pg_stat_user_tables
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        {:ok, row_to_map(columns, row)}

      {:ok, %{rows: []}} ->
        {:ok, default_table_stats()}

      {:error, reason} ->
        {:error, {:table_stats_error, reason}}
    end
  end

  defp fetch_statio_stats(repo) do
    query = """
    SELECT
      COALESCE(SUM(heap_blks_read), 0) AS heap_blks_read,
      COALESCE(SUM(heap_blks_hit), 0) AS heap_blks_hit,
      COALESCE(SUM(idx_blks_read), 0) AS idx_blks_read,
      COALESCE(SUM(idx_blks_hit), 0) AS idx_blks_hit
    FROM pg_statio_user_tables
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        {:ok, row_to_map(columns, row)}

      _ ->
        {:ok, %{heap_blks_read: 0, heap_blks_hit: 0, idx_blks_read: 0, idx_blks_hit: 0}}
    end
  end

  defp fetch_activity_stats(repo, sample_duration, num_samples) do
    # Take multiple samples to get a better picture of wait events
    samples =
      Enum.map(1..num_samples, fn i ->
        if i > 1 and sample_duration > 0 do
          Process.sleep(div(sample_duration, num_samples))
        end

        fetch_activity_snapshot(repo)
      end)

    # Aggregate samples
    valid_samples = Enum.filter(samples, &match?({:ok, _}, &1)) |> Enum.map(&elem(&1, 1))

    if Enum.empty?(valid_samples) do
      {:ok, default_activity_stats()}
    else
      {:ok, aggregate_activity_samples(valid_samples)}
    end
  end

  defp fetch_activity_snapshot(repo) do
    query = """
    SELECT
      COUNT(*) AS total_backends,
      COUNT(*) FILTER (WHERE state = 'active') AS active_backends,
      COUNT(*) FILTER (WHERE wait_event_type IS NOT NULL) AS waiting_backends,
      COUNT(*) FILTER (WHERE wait_event_type = 'IO') AS io_waiters,
      COUNT(*) FILTER (WHERE wait_event_type = 'Lock') AS lock_waiters,
      COUNT(*) FILTER (WHERE wait_event_type = 'LWLock') AS lwlock_waiters,
      COUNT(*) FILTER (WHERE wait_event_type = 'Client') AS client_waiters,
      COUNT(*) FILTER (WHERE wait_event_type = 'BufferPin') AS bufferpin_waiters
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
      AND pid != pg_backend_pid()
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        {:ok, row_to_map(columns, row)}

      _ ->
        {:ok, default_activity_stats()}
    end
  end

  defp aggregate_activity_samples(samples) do
    # Average the samples
    count = length(samples)

    Enum.reduce(samples, default_activity_stats(), fn sample, acc ->
      Map.merge(acc, sample, fn _k, v1, v2 -> v1 + v2 end)
    end)
    |> Map.new(fn {k, v} -> {k, v / count} end)
  end

  defp fetch_bgwriter_stats(repo) do
    query = """
    SELECT
      COALESCE(checkpoints_timed, 0) AS checkpoints_timed,
      COALESCE(checkpoints_req, 0) AS checkpoints_req,
      COALESCE(buffers_checkpoint, 0) AS buffers_checkpoint,
      COALESCE(buffers_clean, 0) AS buffers_clean,
      COALESCE(buffers_backend, 0) AS buffers_backend,
      COALESCE(buffers_alloc, 0) AS buffers_alloc
    FROM pg_stat_bgwriter
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        {:ok, row_to_map(columns, row)}

      {:ok, %{rows: []}} ->
        {:ok, default_bgwriter_stats()}

      {:error, reason} ->
        {:error, {:bgwriter_stats_error, reason}}
    end
  end

  defp fetch_database_stats(repo) do
    query = """
    SELECT
      COALESCE(xact_commit, 0) AS xact_commit,
      COALESCE(xact_rollback, 0) AS xact_rollback,
      COALESCE(blks_read, 0) AS blks_read,
      COALESCE(blks_hit, 0) AS blks_hit,
      COALESCE(tup_returned, 0) AS tup_returned,
      COALESCE(tup_fetched, 0) AS tup_fetched,
      COALESCE(tup_inserted, 0) AS tup_inserted,
      COALESCE(tup_updated, 0) AS tup_updated,
      COALESCE(tup_deleted, 0) AS tup_deleted,
      COALESCE(temp_files, 0) AS temp_files,
      COALESCE(temp_bytes, 0) AS temp_bytes,
      COALESCE(deadlocks, 0) AS deadlocks,
      COALESCE(blk_read_time, 0) AS blk_read_time,
      COALESCE(blk_write_time, 0) AS blk_write_time
    FROM pg_stat_database
    WHERE datname = current_database()
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        {:ok, row_to_map(columns, row)}

      {:ok, %{rows: []}} ->
        {:ok, default_database_stats()}

      {:error, reason} ->
        {:error, {:db_stats_error, reason}}
    end
  end

  defp fetch_settings(repo) do
    query = """
    SELECT
      (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections
    """

    case repo.query(query) do
      {:ok, %{rows: [[max_conn]]}} ->
        {:ok, %{max_connections: max_conn || 100}}

      _ ->
        {:ok, %{max_connections: 100}}
    end
  end

  # ============================================================================
  # Profile Computation
  # ============================================================================

  defp compute_profile(stmt_stats, table_stats, activity_stats, bgwriter_stats, db_stats, settings) do
    # Fetch statio separately (for heap/index hit ratios)
    statio_stats =
      case fetch_statio_stats(Repo) do
        {:ok, stats} -> stats
        _ -> %{heap_blks_read: 0, heap_blks_hit: 0, idx_blks_read: 0, idx_blks_hit: 0}
      end

    # Pre-compute totals
    total_scans = to_num(table_stats.seq_scan) + to_num(table_stats.idx_scan)
    total_writes = to_num(table_stats.n_tup_ins) + to_num(table_stats.n_tup_upd) + to_num(table_stats.n_tup_del)
    total_heap_blks = to_num(statio_stats.heap_blks_read) + to_num(statio_stats.heap_blks_hit)
    total_idx_blks = to_num(statio_stats.idx_blks_read) + to_num(statio_stats.idx_blks_hit)
    total_shared_blks = to_num(stmt_stats.total_shared_blks_hit) + to_num(stmt_stats.total_shared_blks_read)
    total_checkpoints = to_num(bgwriter_stats.checkpoints_timed) + to_num(bgwriter_stats.checkpoints_req)
    total_buffers_written = to_num(bgwriter_stats.buffers_checkpoint) + to_num(bgwriter_stats.buffers_clean) + to_num(bgwriter_stats.buffers_backend)
    total_io_time = to_num(db_stats.blk_read_time) + to_num(db_stats.blk_write_time)
    total_waiters = to_num(activity_stats.waiting_backends)

    %{
      # Query pattern features
      avg_rows_per_query: safe_div(stmt_stats.total_rows, stmt_stats.total_calls),
      query_complexity: safe_div(stmt_stats.total_temp_blks, total_shared_blks + to_num(stmt_stats.total_temp_blks)),
      cache_miss_ratio: safe_div(stmt_stats.total_shared_blks_read, total_shared_blks),
      temp_spill_ratio: safe_div(stmt_stats.queries_with_temp, stmt_stats.total_queries),
      avg_exec_time_ms: safe_div(stmt_stats.total_exec_time, stmt_stats.total_calls),
      read_query_ratio: safe_div(stmt_stats.select_queries, stmt_stats.total_queries),

      # Access pattern features
      seq_scan_ratio: safe_div(table_stats.seq_scan, total_scans),
      index_scan_ratio: safe_div(table_stats.idx_scan, total_scans),
      heap_hit_ratio: safe_div(statio_stats.heap_blks_hit, total_heap_blks),
      index_hit_ratio: safe_div(statio_stats.idx_blks_hit, total_idx_blks),
      rows_per_seq_scan: safe_div(table_stats.seq_tup_read, table_stats.seq_scan),
      rows_per_idx_scan: safe_div(table_stats.idx_tup_fetch, table_stats.idx_scan),

      # Write pattern features
      write_ratio: safe_div(total_writes, to_num(table_stats.n_live_tup) + total_writes),
      insert_ratio: safe_div(table_stats.n_tup_ins, total_writes),
      update_ratio: safe_div(table_stats.n_tup_upd, total_writes),
      delete_ratio: safe_div(table_stats.n_tup_del, total_writes),
      hot_update_ratio: safe_div(table_stats.n_tup_hot_upd, table_stats.n_tup_upd),

      # Vacuum pressure features
      dead_tuple_ratio: safe_div(table_stats.n_dead_tup, table_stats.n_live_tup),
      tables_needing_vacuum_ratio: safe_div(table_stats.tables_need_vacuum, table_stats.total_tables),

      # Concurrency features
      connection_utilization: safe_div(activity_stats.total_backends, settings.max_connections),
      active_query_ratio: safe_div(activity_stats.active_backends, activity_stats.total_backends),

      # Wait event features
      io_wait_ratio: safe_div(activity_stats.io_waiters, total_waiters),
      lock_wait_ratio: safe_div(activity_stats.lock_waiters, total_waiters),
      lwlock_wait_ratio: safe_div(activity_stats.lwlock_waiters, total_waiters),
      client_wait_ratio: safe_div(activity_stats.client_waiters, total_waiters),

      # Checkpoint/WAL features
      checkpoint_pressure: safe_div(bgwriter_stats.checkpoints_req, total_checkpoints),
      backend_write_ratio: safe_div(bgwriter_stats.buffers_backend, total_buffers_written),

      # I/O features
      blk_read_time_ratio: safe_div(db_stats.blk_read_time, total_io_time),
      blk_write_time_ratio: safe_div(db_stats.blk_write_time, total_io_time),

      # Metadata
      total_queries: to_num(stmt_stats.total_queries) |> trunc(),
      has_pg_stat_statements: Map.get(stmt_stats, :has_pg_stat_statements, false)
    }
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp row_to_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn {col, val} -> {String.to_atom(col), val} end)
  end

  defp safe_div(_, 0), do: 0.0
  defp safe_div(_, denom) when denom == 0.0, do: 0.0
  defp safe_div(nil, _), do: 0.0
  defp safe_div(num, denom), do: to_num(num) / to_num(denom)

  defp to_num(nil), do: 0.0
  defp to_num(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_num(n) when is_integer(n), do: n * 1.0
  defp to_num(n) when is_float(n), do: n
  defp to_num(_), do: 0.0

  # ============================================================================
  # Default Values
  # ============================================================================

  defp default_statement_stats do
    %{
      total_queries: 0,
      total_calls: 0,
      total_rows: 0,
      total_exec_time: 0,
      total_shared_blks_hit: 0,
      total_shared_blks_read: 0,
      total_temp_blks: 0,
      queries_with_temp: 0,
      select_queries: 0,
      has_pg_stat_statements: false
    }
  end

  defp default_table_stats do
    %{
      seq_scan: 0,
      seq_tup_read: 0,
      idx_scan: 0,
      idx_tup_fetch: 0,
      n_tup_ins: 0,
      n_tup_upd: 0,
      n_tup_del: 0,
      n_tup_hot_upd: 0,
      n_live_tup: 0,
      n_dead_tup: 0,
      total_tables: 0,
      tables_need_vacuum: 0
    }
  end

  defp default_activity_stats do
    %{
      total_backends: 0.0,
      active_backends: 0.0,
      waiting_backends: 0.0,
      io_waiters: 0.0,
      lock_waiters: 0.0,
      lwlock_waiters: 0.0,
      client_waiters: 0.0,
      bufferpin_waiters: 0.0
    }
  end

  defp default_bgwriter_stats do
    %{
      checkpoints_timed: 0,
      checkpoints_req: 0,
      buffers_checkpoint: 0,
      buffers_clean: 0,
      buffers_backend: 0,
      buffers_alloc: 0
    }
  end

  defp default_database_stats do
    %{
      xact_commit: 0,
      xact_rollback: 0,
      blks_read: 0,
      blks_hit: 0,
      tup_returned: 0,
      tup_fetched: 0,
      tup_inserted: 0,
      tup_updated: 0,
      tup_deleted: 0,
      temp_files: 0,
      temp_bytes: 0,
      deadlocks: 0,
      blk_read_time: 0,
      blk_write_time: 0
    }
  end
end
