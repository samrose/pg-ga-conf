defmodule PgGaConf.Workload.Classifier do
  @moduledoc """
  Rule-based workload classification into 8 archetypes.

  Uses a decision tree approach based on profile metrics to classify
  workloads into specific archetypes, each with its own set of relevant
  PostgreSQL configuration knobs.

  ## Archetypes

  - `:high_concurrency_oltp` - Many connections, small transactions, point lookups
  - `:read_heavy_oltp` - Mostly SELECTs, good cache hits, index scans
  - `:write_heavy_oltp` - Insert/update dominant, WAL pressure
  - `:update_heavy_oltp` - Updates dominant, vacuum pressure, HOT tuning
  - `:analytical` - Few connections, seq scans, large result sets, temp files
  - `:mixed_htap` - Both OLTP and OLAP patterns
  - `:batch_etl` - Bulk loads, high write volume, maintenance ops
  - `:idle_or_unknown` - Insufficient data to classify
  """

  alias PgGaConf.Workload.Profiler

  @type archetype ::
          :high_concurrency_oltp
          | :read_heavy_oltp
          | :write_heavy_oltp
          | :update_heavy_oltp
          | :analytical
          | :mixed_htap
          | :batch_etl
          | :idle_or_unknown

  @type classification_result :: %{
          archetype: archetype(),
          confidence: float(),
          reasons: [String.t()],
          profile: Profiler.profile()
        }

  # Thresholds for classification rules
  @min_queries_for_classification 100
  @high_seq_scan_ratio 0.6
  @high_index_scan_ratio 0.7
  @high_connection_utilization 0.4
  @high_write_ratio 0.4
  @very_high_write_ratio 0.7
  @high_insert_ratio 0.6
  @high_update_ratio 0.5
  @high_read_ratio 0.8
  @high_cache_hit_ratio 0.9
  @high_temp_spill_ratio 0.05
  @high_checkpoint_pressure 0.3
  @high_dead_tuple_ratio 0.1
  @large_result_set_threshold 1000
  @low_connection_utilization 0.2
  @fast_query_threshold_ms 50
  @small_result_set_threshold 100

  @doc """
  Classify a workload based on its profile.

  Returns the archetype with confidence score and reasoning.
  """
  @spec classify(Profiler.profile()) :: classification_result()
  def classify(profile) do
    {archetype, confidence, reasons} = apply_decision_tree(profile)

    %{
      archetype: archetype,
      confidence: confidence,
      reasons: reasons,
      profile: profile
    }
  end

  @doc """
  Classify a workload by first profiling the database.

  Convenience function that combines profiling and classification.
  """
  @spec classify_from_db(keyword()) :: {:ok, classification_result()} | {:error, term()}
  def classify_from_db(opts \\ []) do
    case Profiler.profile(opts) do
      {:ok, profile} -> {:ok, classify(profile)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a simple archetype atom without detailed results.
  """
  @spec archetype(Profiler.profile()) :: archetype()
  def archetype(profile) do
    {archetype, _confidence, _reasons} = apply_decision_tree(profile)
    archetype
  end

  @doc """
  Returns human-readable description of an archetype.
  """
  @spec describe(archetype()) :: String.t()
  def describe(:high_concurrency_oltp) do
    "High-concurrency OLTP: Many simultaneous connections executing small, fast transactions with point lookups"
  end

  def describe(:read_heavy_oltp) do
    "Read-heavy OLTP: Predominantly SELECT queries with good cache utilization and index-based access"
  end

  def describe(:write_heavy_oltp) do
    "Write-heavy OLTP: High insert/write volume creating WAL and checkpoint pressure"
  end

  def describe(:update_heavy_oltp) do
    "Update-heavy OLTP: Frequent updates causing vacuum pressure and dead tuple accumulation"
  end

  def describe(:analytical) do
    "Analytical (OLAP): Complex queries with sequential scans, large result sets, and temp file usage"
  end

  def describe(:mixed_htap) do
    "Mixed HTAP: Hybrid workload with both transactional and analytical query patterns"
  end

  def describe(:batch_etl) do
    "Batch/ETL: Bulk data loading operations with high write volume and low concurrency"
  end

  def describe(:idle_or_unknown) do
    "Idle or Unknown: Insufficient query activity to determine workload characteristics"
  end

  # ============================================================================
  # Decision Tree Implementation
  # ============================================================================

  defp apply_decision_tree(profile) do
    cond do
      # Level 0: Insufficient data
      insufficient_data?(profile) ->
        {:idle_or_unknown, 1.0, ["Fewer than #{@min_queries_for_classification} queries observed"]}

      # Level 1: Check for analytical workload (most distinctive pattern)
      analytical?(profile) ->
        confidence = compute_analytical_confidence(profile)
        reasons = analytical_reasons(profile)
        {:analytical, confidence, reasons}

      # Level 2: Check for batch/ETL (high writes, low concurrency)
      batch_etl?(profile) ->
        confidence = compute_batch_confidence(profile)
        reasons = batch_reasons(profile)
        {:batch_etl, confidence, reasons}

      # Level 3: Check for high concurrency OLTP
      high_concurrency_oltp?(profile) ->
        confidence = compute_high_concurrency_confidence(profile)
        reasons = high_concurrency_reasons(profile)
        {:high_concurrency_oltp, confidence, reasons}

      # Level 4: Check for write-heavy OLTP
      write_heavy_oltp?(profile) ->
        confidence = compute_write_heavy_confidence(profile)
        reasons = write_heavy_reasons(profile)
        {:write_heavy_oltp, confidence, reasons}

      # Level 5: Check for update-heavy OLTP
      update_heavy_oltp?(profile) ->
        confidence = compute_update_heavy_confidence(profile)
        reasons = update_heavy_reasons(profile)
        {:update_heavy_oltp, confidence, reasons}

      # Level 6: Check for read-heavy OLTP
      read_heavy_oltp?(profile) ->
        confidence = compute_read_heavy_confidence(profile)
        reasons = read_heavy_reasons(profile)
        {:read_heavy_oltp, confidence, reasons}

      # Level 7: Default to mixed
      true ->
        confidence = 0.5
        reasons = ["No clear pattern detected", "Characteristics of multiple workload types"]
        {:mixed_htap, confidence, reasons}
    end
  end

  # ============================================================================
  # Classification Predicates
  # ============================================================================

  defp insufficient_data?(profile) do
    profile.total_queries < @min_queries_for_classification
  end

  defp analytical?(profile) do
    profile.seq_scan_ratio > @high_seq_scan_ratio and
      profile.avg_rows_per_query > @large_result_set_threshold and
      profile.temp_spill_ratio > @high_temp_spill_ratio
  end

  defp batch_etl?(profile) do
    profile.write_ratio > @very_high_write_ratio and
      profile.insert_ratio > @high_insert_ratio and
      profile.connection_utilization < @low_connection_utilization
  end

  defp high_concurrency_oltp?(profile) do
    profile.connection_utilization > @high_connection_utilization and
      profile.index_scan_ratio > @high_index_scan_ratio and
      profile.avg_rows_per_query < @small_result_set_threshold and
      profile.avg_exec_time_ms < @fast_query_threshold_ms
  end

  defp write_heavy_oltp?(profile) do
    profile.write_ratio > @high_write_ratio and
      profile.checkpoint_pressure > @high_checkpoint_pressure and
      profile.insert_ratio > @high_insert_ratio
  end

  defp update_heavy_oltp?(profile) do
    profile.update_ratio > @high_update_ratio and
      profile.dead_tuple_ratio > @high_dead_tuple_ratio
  end

  defp read_heavy_oltp?(profile) do
    profile.read_query_ratio > @high_read_ratio and
      profile.index_scan_ratio > @high_seq_scan_ratio and
      profile.heap_hit_ratio > @high_cache_hit_ratio
  end

  # ============================================================================
  # Confidence Computation
  # ============================================================================

  defp compute_analytical_confidence(profile) do
    scores = [
      score(profile.seq_scan_ratio, @high_seq_scan_ratio, 1.0),
      score(profile.avg_rows_per_query, @large_result_set_threshold, 10000),
      score(profile.temp_spill_ratio, @high_temp_spill_ratio, 0.3),
      score(profile.read_query_ratio, 0.7, 1.0)
    ]

    Enum.sum(scores) / length(scores)
  end

  defp compute_batch_confidence(profile) do
    scores = [
      score(profile.write_ratio, @very_high_write_ratio, 1.0),
      score(profile.insert_ratio, @high_insert_ratio, 1.0),
      inverse_score(profile.connection_utilization, 0.0, @low_connection_utilization)
    ]

    Enum.sum(scores) / length(scores)
  end

  defp compute_high_concurrency_confidence(profile) do
    scores = [
      score(profile.connection_utilization, @high_connection_utilization, 1.0),
      score(profile.index_scan_ratio, @high_index_scan_ratio, 1.0),
      inverse_score(profile.avg_rows_per_query, 1, @small_result_set_threshold),
      inverse_score(profile.avg_exec_time_ms, 1, @fast_query_threshold_ms)
    ]

    Enum.sum(scores) / length(scores)
  end

  defp compute_write_heavy_confidence(profile) do
    scores = [
      score(profile.write_ratio, @high_write_ratio, 1.0),
      score(profile.checkpoint_pressure, @high_checkpoint_pressure, 1.0),
      score(profile.insert_ratio, 0.3, 1.0)
    ]

    Enum.sum(scores) / length(scores)
  end

  defp compute_update_heavy_confidence(profile) do
    scores = [
      score(profile.update_ratio, @high_update_ratio, 1.0),
      score(profile.dead_tuple_ratio, @high_dead_tuple_ratio, 0.5)
    ]

    Enum.sum(scores) / length(scores)
  end

  defp compute_read_heavy_confidence(profile) do
    scores = [
      score(profile.read_query_ratio, @high_read_ratio, 1.0),
      score(profile.index_scan_ratio, @high_seq_scan_ratio, 1.0),
      score(profile.heap_hit_ratio, @high_cache_hit_ratio, 1.0)
    ]

    Enum.sum(scores) / length(scores)
  end

  # Score 0-1 based on how far value is between threshold and max
  defp score(value, threshold, max) when max > threshold do
    cond do
      value <= threshold -> 0.0
      value >= max -> 1.0
      true -> (value - threshold) / (max - threshold)
    end
  end

  defp score(_, _, _), do: 0.5

  # Inverse score - higher values give lower scores
  defp inverse_score(value, min, threshold) when threshold > min do
    cond do
      value <= min -> 1.0
      value >= threshold -> 0.0
      true -> 1.0 - (value - min) / (threshold - min)
    end
  end

  defp inverse_score(_, _, _), do: 0.5

  # ============================================================================
  # Reason Generation
  # ============================================================================

  defp analytical_reasons(profile) do
    reasons = []

    reasons =
      if profile.seq_scan_ratio > @high_seq_scan_ratio do
        ["#{format_pct(profile.seq_scan_ratio)} sequential scans (table scans)" | reasons]
      else
        reasons
      end

    reasons =
      if profile.avg_rows_per_query > @large_result_set_threshold do
        ["Avg #{format_num(profile.avg_rows_per_query)} rows per query (large result sets)" | reasons]
      else
        reasons
      end

    reasons =
      if profile.temp_spill_ratio > @high_temp_spill_ratio do
        ["#{format_pct(profile.temp_spill_ratio)} queries use temp files (complex operations)" | reasons]
      else
        reasons
      end

    Enum.reverse(reasons)
  end

  defp batch_reasons(profile) do
    reasons = []

    reasons =
      if profile.write_ratio > @very_high_write_ratio do
        ["#{format_pct(profile.write_ratio)} write operations (bulk loading)" | reasons]
      else
        reasons
      end

    reasons =
      if profile.insert_ratio > @high_insert_ratio do
        ["#{format_pct(profile.insert_ratio)} of writes are INSERTs" | reasons]
      else
        reasons
      end

    reasons =
      if profile.connection_utilization < @low_connection_utilization do
        ["Low connection utilization #{format_pct(profile.connection_utilization)} (batch process)" | reasons]
      else
        reasons
      end

    Enum.reverse(reasons)
  end

  defp high_concurrency_reasons(profile) do
    reasons = []

    reasons =
      if profile.connection_utilization > @high_connection_utilization do
        ["#{format_pct(profile.connection_utilization)} connection utilization" | reasons]
      else
        reasons
      end

    reasons =
      if profile.index_scan_ratio > @high_index_scan_ratio do
        ["#{format_pct(profile.index_scan_ratio)} index scans (point lookups)" | reasons]
      else
        reasons
      end

    reasons =
      if profile.avg_exec_time_ms < @fast_query_threshold_ms do
        ["Avg query time #{format_num(profile.avg_exec_time_ms)}ms (fast transactions)" | reasons]
      else
        reasons
      end

    Enum.reverse(reasons)
  end

  defp write_heavy_reasons(profile) do
    reasons = []

    reasons =
      if profile.write_ratio > @high_write_ratio do
        ["#{format_pct(profile.write_ratio)} write operations" | reasons]
      else
        reasons
      end

    reasons =
      if profile.checkpoint_pressure > @high_checkpoint_pressure do
        ["#{format_pct(profile.checkpoint_pressure)} forced checkpoints (WAL pressure)" | reasons]
      else
        reasons
      end

    Enum.reverse(reasons)
  end

  defp update_heavy_reasons(profile) do
    reasons = []

    reasons =
      if profile.update_ratio > @high_update_ratio do
        ["#{format_pct(profile.update_ratio)} of writes are UPDATEs" | reasons]
      else
        reasons
      end

    reasons =
      if profile.dead_tuple_ratio > @high_dead_tuple_ratio do
        ["#{format_pct(profile.dead_tuple_ratio)} dead tuple ratio (vacuum pressure)" | reasons]
      else
        reasons
      end

    reasons =
      if profile.hot_update_ratio < 0.5 do
        ["Low HOT update ratio #{format_pct(profile.hot_update_ratio)} (fillfactor tuning opportunity)" | reasons]
      else
        reasons
      end

    Enum.reverse(reasons)
  end

  defp read_heavy_reasons(profile) do
    reasons = []

    reasons =
      if profile.read_query_ratio > @high_read_ratio do
        ["#{format_pct(profile.read_query_ratio)} read queries (SELECTs)" | reasons]
      else
        reasons
      end

    reasons =
      if profile.heap_hit_ratio > @high_cache_hit_ratio do
        ["#{format_pct(profile.heap_hit_ratio)} cache hit ratio (good memory utilization)" | reasons]
      else
        reasons
      end

    reasons =
      if profile.index_scan_ratio > @high_seq_scan_ratio do
        ["#{format_pct(profile.index_scan_ratio)} index scans" | reasons]
      else
        reasons
      end

    Enum.reverse(reasons)
  end

  defp format_pct(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_pct(_), do: "0%"

  defp format_num(value) when is_float(value), do: Float.round(value, 1)
  defp format_num(value), do: value
end
