defmodule PgGaConf.Fingerprint do
  @moduledoc """
  Workload fingerprinting for PostgreSQL databases.

  Extracts a 15-dimension feature vector from pg_stat_* views that characterizes
  the workload pattern. Used for:
  - Workload classification (OLTP/OLAP/Mixed)
  - Transfer learning (warm-start from similar historical observations)
  - Sobol cache lookup (reuse sensitivity analysis for similar workloads)

  ## Feature Vector

  The fingerprint captures:
  1. Read/write ratio
  2. Sequential vs index scan ratio
  3. Average tuple sizes
  4. Table vs index hit ratios
  5. Transaction patterns
  6. Lock contention indicators
  7. Temp file usage patterns
  """

  alias PgGaConf.Repo

  @type fingerprint :: %{
          read_write_ratio: float(),
          seq_scan_ratio: float(),
          index_scan_ratio: float(),
          heap_blks_hit_ratio: float(),
          idx_blks_hit_ratio: float(),
          avg_tuple_size: float(),
          temp_files_ratio: float(),
          deadlock_ratio: float(),
          xact_commit_ratio: float(),
          tup_returned_per_fetch: float(),
          tup_inserted_ratio: float(),
          tup_updated_ratio: float(),
          tup_deleted_ratio: float(),
          blk_read_time_ratio: float(),
          blk_write_time_ratio: float()
        }

  @type workload_type :: :oltp | :olap | :mixed

  @doc """
  Extract workload fingerprint from the connected database.

  Returns a normalized 15-dimension feature vector.
  """
  @spec extract(Ecto.Repo.t() | nil) :: {:ok, fingerprint()} | {:error, term()}
  def extract(repo \\ nil) do
    repo = repo || Repo

    with {:ok, db_stats} <- fetch_database_stats(repo),
         {:ok, table_stats} <- fetch_table_stats(repo),
         {:ok, bgwriter_stats} <- fetch_bgwriter_stats(repo) do
      fingerprint = compute_fingerprint(db_stats, table_stats, bgwriter_stats)
      {:ok, fingerprint}
    end
  end

  @doc """
  Classify workload type based on fingerprint.

  ## Classification Rules

  - OLTP: High read_write_ratio variance, high index_scan_ratio, small tuples
  - OLAP: Low read_write_ratio (more reads), high seq_scan_ratio, large result sets
  - Mixed: Characteristics of both
  """
  @spec classify(fingerprint()) :: workload_type()
  def classify(fingerprint) do
    oltp_score = compute_oltp_score(fingerprint)
    olap_score = compute_olap_score(fingerprint)

    cond do
      oltp_score > 0.7 and olap_score < 0.3 -> :oltp
      olap_score > 0.7 and oltp_score < 0.3 -> :olap
      true -> :mixed
    end
  end

  @doc """
  Compute similarity between two fingerprints using cosine similarity.

  Returns a value between 0 (completely different) and 1 (identical).
  """
  @spec similarity(fingerprint(), fingerprint()) :: float()
  def similarity(fp1, fp2) do
    vec1 = fingerprint_to_vector(fp1)
    vec2 = fingerprint_to_vector(fp2)

    dot_product = Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    magnitude1 = :math.sqrt(Enum.map(vec1, &(&1 * &1)) |> Enum.sum())
    magnitude2 = :math.sqrt(Enum.map(vec2, &(&1 * &1)) |> Enum.sum())

    if magnitude1 == 0 or magnitude2 == 0 do
      0.0
    else
      dot_product / (magnitude1 * magnitude2)
    end
  end

  @doc """
  Convert fingerprint to vector form for ML/similarity operations.
  """
  @spec fingerprint_to_vector(fingerprint()) :: [float()]
  def fingerprint_to_vector(fp) do
    [
      fp.read_write_ratio,
      fp.seq_scan_ratio,
      fp.index_scan_ratio,
      fp.heap_blks_hit_ratio,
      fp.idx_blks_hit_ratio,
      fp.avg_tuple_size,
      fp.temp_files_ratio,
      fp.deadlock_ratio,
      fp.xact_commit_ratio,
      fp.tup_returned_per_fetch,
      fp.tup_inserted_ratio,
      fp.tup_updated_ratio,
      fp.tup_deleted_ratio,
      fp.blk_read_time_ratio,
      fp.blk_write_time_ratio
    ]
  end

  @doc """
  Serialize fingerprint to binary for storage.
  """
  @spec serialize(fingerprint()) :: binary()
  def serialize(fingerprint) do
    :erlang.term_to_binary(fingerprint)
  end

  @doc """
  Deserialize fingerprint from binary.
  """
  @spec deserialize(binary()) :: {:ok, fingerprint()} | {:error, :invalid_fingerprint}
  def deserialize(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    _ -> {:error, :invalid_fingerprint}
  end

  # Private functions

  defp fetch_database_stats(repo) do
    query = """
    SELECT
      COALESCE(xact_commit, 0) as xact_commit,
      COALESCE(xact_rollback, 0) as xact_rollback,
      COALESCE(blks_read, 0) as blks_read,
      COALESCE(blks_hit, 0) as blks_hit,
      COALESCE(tup_returned, 0) as tup_returned,
      COALESCE(tup_fetched, 0) as tup_fetched,
      COALESCE(tup_inserted, 0) as tup_inserted,
      COALESCE(tup_updated, 0) as tup_updated,
      COALESCE(tup_deleted, 0) as tup_deleted,
      COALESCE(conflicts, 0) as conflicts,
      COALESCE(temp_files, 0) as temp_files,
      COALESCE(temp_bytes, 0) as temp_bytes,
      COALESCE(deadlocks, 0) as deadlocks,
      COALESCE(blk_read_time, 0) as blk_read_time,
      COALESCE(blk_write_time, 0) as blk_write_time
    FROM pg_stat_database
    WHERE datname = current_database()
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        stats = Enum.zip(columns, row) |> Map.new(fn {k, v} -> {String.to_atom(k), v || 0} end)
        {:ok, stats}

      {:ok, %{rows: []}} ->
        {:ok, default_db_stats()}

      {:error, reason} ->
        {:error, {:db_stats_error, reason}}
    end
  end

  defp fetch_table_stats(repo) do
    query = """
    SELECT
      COALESCE(SUM(seq_scan), 0) as seq_scan,
      COALESCE(SUM(seq_tup_read), 0) as seq_tup_read,
      COALESCE(SUM(idx_scan), 0) as idx_scan,
      COALESCE(SUM(idx_tup_fetch), 0) as idx_tup_fetch,
      COALESCE(SUM(n_tup_ins), 0) as n_tup_ins,
      COALESCE(SUM(n_tup_upd), 0) as n_tup_upd,
      COALESCE(SUM(n_tup_del), 0) as n_tup_del,
      COALESCE(SUM(n_live_tup), 0) as n_live_tup,
      COALESCE(SUM(heap_blks_read), 0) as heap_blks_read,
      COALESCE(SUM(heap_blks_hit), 0) as heap_blks_hit,
      COALESCE(SUM(idx_blks_read), 0) as idx_blks_read,
      COALESCE(SUM(idx_blks_hit), 0) as idx_blks_hit
    FROM pg_stat_user_tables
    LEFT JOIN pg_statio_user_tables USING (relid)
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        stats = Enum.zip(columns, row) |> Map.new(fn {k, v} -> {String.to_atom(k), v || 0} end)
        {:ok, stats}

      {:ok, %{rows: []}} ->
        {:ok, default_table_stats()}

      {:error, reason} ->
        {:error, {:table_stats_error, reason}}
    end
  end

  defp fetch_bgwriter_stats(repo) do
    query = """
    SELECT
      COALESCE(checkpoints_timed, 0) as checkpoints_timed,
      COALESCE(checkpoints_req, 0) as checkpoints_req,
      COALESCE(buffers_checkpoint, 0) as buffers_checkpoint,
      COALESCE(buffers_clean, 0) as buffers_clean,
      COALESCE(buffers_backend, 0) as buffers_backend
    FROM pg_stat_bgwriter
    """

    case repo.query(query) do
      {:ok, %{rows: [row], columns: columns}} ->
        stats = Enum.zip(columns, row) |> Map.new(fn {k, v} -> {String.to_atom(k), v || 0} end)
        {:ok, stats}

      {:ok, %{rows: []}} ->
        {:ok, default_bgwriter_stats()}

      {:error, reason} ->
        {:error, {:bgwriter_stats_error, reason}}
    end
  end

  defp compute_fingerprint(db_stats, table_stats, _bgwriter_stats) do
    total_xact = to_number(db_stats.xact_commit) + to_number(db_stats.xact_rollback)
    total_tup_modified = to_number(db_stats.tup_inserted) + to_number(db_stats.tup_updated) + to_number(db_stats.tup_deleted)
    total_tup_read = to_number(db_stats.tup_returned) + to_number(db_stats.tup_fetched)
    total_scans = to_number(table_stats.seq_scan) + to_number(table_stats.idx_scan)
    _total_blks = to_number(db_stats.blks_read) + to_number(db_stats.blks_hit)
    total_heap_blks = to_number(table_stats.heap_blks_read) + to_number(table_stats.heap_blks_hit)
    total_idx_blks = to_number(table_stats.idx_blks_read) + to_number(table_stats.idx_blks_hit)
    total_blk_time = to_number(db_stats.blk_read_time) + to_number(db_stats.blk_write_time)

    %{
      # Read/write ratio: higher = more reads
      read_write_ratio: safe_ratio(total_tup_read, total_tup_read + total_tup_modified),

      # Scan patterns
      seq_scan_ratio: safe_ratio(table_stats.seq_scan, total_scans),
      index_scan_ratio: safe_ratio(table_stats.idx_scan, total_scans),

      # Cache hit ratios
      heap_blks_hit_ratio: safe_ratio(table_stats.heap_blks_hit, total_heap_blks),
      idx_blks_hit_ratio: safe_ratio(table_stats.idx_blks_hit, total_idx_blks),

      # Tuple characteristics
      avg_tuple_size: safe_ratio(db_stats.temp_bytes, max(db_stats.temp_files, 1)),
      temp_files_ratio: safe_ratio(db_stats.temp_files, total_xact),

      # Transaction patterns
      deadlock_ratio: safe_ratio(db_stats.deadlocks, total_xact),
      xact_commit_ratio: safe_ratio(db_stats.xact_commit, total_xact),

      # Access patterns
      tup_returned_per_fetch: safe_ratio(db_stats.tup_returned, max(db_stats.tup_fetched, 1)),

      # Modification patterns (normalized to total modifications)
      tup_inserted_ratio: safe_ratio(db_stats.tup_inserted, total_tup_modified),
      tup_updated_ratio: safe_ratio(db_stats.tup_updated, total_tup_modified),
      tup_deleted_ratio: safe_ratio(db_stats.tup_deleted, total_tup_modified),

      # I/O patterns
      blk_read_time_ratio: safe_ratio(db_stats.blk_read_time, total_blk_time),
      blk_write_time_ratio: safe_ratio(db_stats.blk_write_time, total_blk_time)
    }
  end

  defp safe_ratio(_numerator, 0), do: 0.0
  defp safe_ratio(_numerator, denominator) when denominator == 0.0, do: 0.0
  defp safe_ratio(numerator, denominator), do: to_number(numerator) / to_number(denominator)

  # Convert Decimal or other numeric types to plain float
  defp to_number(nil), do: 0.0
  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(n) when is_integer(n), do: n * 1.0
  defp to_number(n) when is_float(n), do: n
  defp to_number(n), do: n

  defp compute_oltp_score(fp) do
    # OLTP indicators: high index usage, high commit ratio, balanced modifications
    index_weight = fp.index_scan_ratio * 0.3
    commit_weight = fp.xact_commit_ratio * 0.2
    hit_weight = fp.heap_blks_hit_ratio * 0.2
    # OLTP has more balanced insert/update/delete
    modification_balance =
      1.0 - abs(fp.tup_inserted_ratio - 0.33) - abs(fp.tup_updated_ratio - 0.33)

    modification_weight = max(0, modification_balance) * 0.15
    # Low temp files (small transactions)
    temp_weight = (1.0 - fp.temp_files_ratio) * 0.15

    index_weight + commit_weight + hit_weight + modification_weight + temp_weight
  end

  defp compute_olap_score(fp) do
    # OLAP indicators: sequential scans, large result sets, mostly reads
    seq_weight = fp.seq_scan_ratio * 0.3
    read_weight = fp.read_write_ratio * 0.25
    # Large tuples returned per fetch indicates analytical queries
    large_result_weight = min(1.0, fp.tup_returned_per_fetch / 1000) * 0.25
    # Higher temp file usage (complex queries)
    temp_weight = min(1.0, fp.temp_files_ratio * 10) * 0.2

    seq_weight + read_weight + large_result_weight + temp_weight
  end

  defp default_db_stats do
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
      conflicts: 0,
      temp_files: 0,
      temp_bytes: 0,
      deadlocks: 0,
      blk_read_time: 0,
      blk_write_time: 0
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
      n_live_tup: 0,
      heap_blks_read: 0,
      heap_blks_hit: 0,
      idx_blks_read: 0,
      idx_blks_hit: 0
    }
  end

  defp default_bgwriter_stats do
    %{
      checkpoints_timed: 0,
      checkpoints_req: 0,
      buffers_checkpoint: 0,
      buffers_clean: 0,
      buffers_backend: 0
    }
  end
end
