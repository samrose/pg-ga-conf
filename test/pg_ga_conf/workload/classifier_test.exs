defmodule PgGaConf.Workload.ClassifierTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Workload.Classifier

  describe "classify/1" do
    test "classifies idle workload with insufficient data" do
      profile = mock_profile(total_queries: 50)

      result = Classifier.classify(profile)

      assert result.archetype == :idle_or_unknown
      assert result.confidence == 1.0
      assert "Fewer than 100 queries observed" in result.reasons
    end

    test "classifies analytical workload" do
      profile = mock_profile(
        total_queries: 1000,
        seq_scan_ratio: 0.8,
        avg_rows_per_query: 50000.0,
        temp_spill_ratio: 0.15,
        read_query_ratio: 0.95
      )

      result = Classifier.classify(profile)

      assert result.archetype == :analytical
      assert result.confidence > 0.5
      assert Enum.any?(result.reasons, &String.contains?(&1, "sequential scans"))
    end

    test "classifies batch/ETL workload" do
      profile = mock_profile(
        total_queries: 1000,
        write_ratio: 0.8,
        insert_ratio: 0.9,
        connection_utilization: 0.1
      )

      result = Classifier.classify(profile)

      assert result.archetype == :batch_etl
      assert result.confidence > 0.5
      assert Enum.any?(result.reasons, &String.contains?(&1, "write operations"))
    end

    test "classifies high-concurrency OLTP" do
      profile = mock_profile(
        total_queries: 10000,
        connection_utilization: 0.7,
        index_scan_ratio: 0.9,
        avg_rows_per_query: 5.0,
        avg_exec_time_ms: 10.0
      )

      result = Classifier.classify(profile)

      assert result.archetype == :high_concurrency_oltp
      assert result.confidence > 0.5
      assert Enum.any?(result.reasons, &String.contains?(&1, "connection utilization"))
    end

    test "classifies write-heavy OLTP" do
      # write_heavy_oltp requires (from classifier.ex):
      # - write_ratio > 0.4 (@high_write_ratio)
      # - checkpoint_pressure > 0.3 (@high_checkpoint_pressure)
      # - insert_ratio > 0.4 (@high_insert_ratio is 0.6, but predicate uses > 0.4)
      # Wait, let me check the actual predicate...
      # Actually, write_heavy_oltp? checks insert_ratio > @high_insert_ratio (0.6)
      # So we need insert_ratio > 0.6
      profile = mock_profile(
        total_queries: 5000,
        write_ratio: 0.55,
        checkpoint_pressure: 0.45,
        insert_ratio: 0.65,  # Must be > 0.6
        # Avoid triggering high_concurrency_oltp
        index_scan_ratio: 0.5,
        connection_utilization: 0.35,
        avg_rows_per_query: 150.0,
        avg_exec_time_ms: 100.0,
        # Avoid triggering batch_etl (needs write_ratio > 0.7 AND insert_ratio > 0.6 AND connection < 0.2)
        # We're at write_ratio=0.55 and connection=0.35, so should be fine
        # Avoid triggering analytical
        seq_scan_ratio: 0.3,
        temp_spill_ratio: 0.01
      )

      result = Classifier.classify(profile)

      assert result.archetype == :write_heavy_oltp
      assert result.confidence > 0.3
      assert Enum.any?(result.reasons, &String.contains?(&1, "write"))
    end

    test "classifies update-heavy OLTP" do
      profile = mock_profile(
        total_queries: 5000,
        update_ratio: 0.7,
        dead_tuple_ratio: 0.2,
        write_ratio: 0.35,
        # Avoid triggering write_heavy by having low checkpoint pressure
        checkpoint_pressure: 0.1,
        insert_ratio: 0.15
      )

      result = Classifier.classify(profile)

      assert result.archetype == :update_heavy_oltp
      assert result.confidence > 0.3
      assert Enum.any?(result.reasons, &String.contains?(&1, "UPDATE"))
    end

    test "classifies read-heavy OLTP" do
      profile = mock_profile(
        total_queries: 5000,
        read_query_ratio: 0.95,
        index_scan_ratio: 0.85,
        heap_hit_ratio: 0.98
      )

      result = Classifier.classify(profile)

      assert result.archetype == :read_heavy_oltp
      assert result.confidence > 0.5
      assert Enum.any?(result.reasons, &String.contains?(&1, "read queries"))
    end

    test "classifies mixed HTAP workload" do
      profile = mock_profile(
        total_queries: 5000,
        # Neither clearly OLTP nor OLAP
        seq_scan_ratio: 0.4,
        write_ratio: 0.3,
        connection_utilization: 0.3
      )

      result = Classifier.classify(profile)

      assert result.archetype == :mixed_htap
      assert Enum.any?(result.reasons, &String.contains?(&1, "pattern"))
    end
  end

  describe "archetype/1" do
    test "returns just the archetype atom" do
      profile = mock_profile(total_queries: 50)

      archetype = Classifier.archetype(profile)

      assert archetype == :idle_or_unknown
    end
  end

  describe "describe/1" do
    test "returns description for each archetype" do
      archetypes = [
        :high_concurrency_oltp,
        :read_heavy_oltp,
        :write_heavy_oltp,
        :update_heavy_oltp,
        :analytical,
        :mixed_htap,
        :batch_etl,
        :idle_or_unknown
      ]

      for archetype <- archetypes do
        description = Classifier.describe(archetype)
        assert is_binary(description)
        assert String.length(description) > 20
      end
    end
  end

  describe "confidence scores" do
    test "confidence is between 0 and 1" do
      profiles = [
        mock_profile(total_queries: 1000, seq_scan_ratio: 0.8, avg_rows_per_query: 50000.0, temp_spill_ratio: 0.15),
        mock_profile(total_queries: 1000, connection_utilization: 0.7, index_scan_ratio: 0.9, avg_rows_per_query: 5.0, avg_exec_time_ms: 10.0),
        mock_profile(total_queries: 1000, write_ratio: 0.8, insert_ratio: 0.9, connection_utilization: 0.1)
      ]

      for profile <- profiles do
        result = Classifier.classify(profile)
        assert result.confidence >= 0.0
        assert result.confidence <= 1.0
      end
    end
  end

  # ============================================================================
  # Mock Profile Helper
  # ============================================================================

  defp mock_profile(overrides) do
    defaults = %{
      avg_rows_per_query: 100.0,
      query_complexity: 0.05,
      cache_miss_ratio: 0.1,
      temp_spill_ratio: 0.02,
      avg_exec_time_ms: 50.0,
      read_query_ratio: 0.6,
      seq_scan_ratio: 0.3,
      index_scan_ratio: 0.7,
      heap_hit_ratio: 0.9,
      index_hit_ratio: 0.95,
      rows_per_seq_scan: 1000.0,
      rows_per_idx_scan: 10.0,
      write_ratio: 0.2,
      insert_ratio: 0.4,
      update_ratio: 0.4,
      delete_ratio: 0.2,
      hot_update_ratio: 0.6,
      dead_tuple_ratio: 0.05,
      tables_needing_vacuum_ratio: 0.1,
      connection_utilization: 0.3,
      active_query_ratio: 0.2,
      io_wait_ratio: 0.2,
      lock_wait_ratio: 0.05,
      lwlock_wait_ratio: 0.05,
      client_wait_ratio: 0.5,
      checkpoint_pressure: 0.1,
      backend_write_ratio: 0.05,
      blk_read_time_ratio: 0.5,
      blk_write_time_ratio: 0.5,
      total_queries: 1000,
      has_pg_stat_statements: true
    }

    Map.merge(defaults, Map.new(overrides))
  end
end
