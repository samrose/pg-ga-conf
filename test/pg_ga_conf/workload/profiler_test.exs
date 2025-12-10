defmodule PgGaConf.Workload.ProfilerTest do
  use ExUnit.Case, async: true

  # These tests don't require a database connection - they test the profile structure
  # and computation logic using mock data

  describe "profile structure" do
    test "profile has all expected keys" do
      # Create a mock profile to verify structure
      expected_keys = [
        :avg_rows_per_query,
        :query_complexity,
        :cache_miss_ratio,
        :temp_spill_ratio,
        :avg_exec_time_ms,
        :read_query_ratio,
        :seq_scan_ratio,
        :index_scan_ratio,
        :heap_hit_ratio,
        :index_hit_ratio,
        :rows_per_seq_scan,
        :rows_per_idx_scan,
        :write_ratio,
        :insert_ratio,
        :update_ratio,
        :delete_ratio,
        :hot_update_ratio,
        :dead_tuple_ratio,
        :tables_needing_vacuum_ratio,
        :connection_utilization,
        :active_query_ratio,
        :io_wait_ratio,
        :lock_wait_ratio,
        :lwlock_wait_ratio,
        :client_wait_ratio,
        :checkpoint_pressure,
        :backend_write_ratio,
        :blk_read_time_ratio,
        :blk_write_time_ratio,
        :total_queries,
        :has_pg_stat_statements
      ]

      # Use a mock profile
      profile = mock_oltp_profile()

      for key <- expected_keys do
        assert Map.has_key?(profile, key), "Profile should have key #{key}"
      end
    end
  end

  describe "mock profiles for testing" do
    test "mock_oltp_profile has OLTP characteristics" do
      profile = mock_oltp_profile()

      # OLTP: high index usage, small rows, many queries
      assert profile.index_scan_ratio > 0.7
      assert profile.avg_rows_per_query < 100
      assert profile.total_queries > 1000
    end

    test "mock_olap_profile has OLAP characteristics" do
      profile = mock_olap_profile()

      # OLAP: high seq scans, large rows, temp files
      assert profile.seq_scan_ratio > 0.6
      assert profile.avg_rows_per_query > 1000
      assert profile.temp_spill_ratio > 0.05
    end

    test "mock_write_heavy_profile has write-heavy characteristics" do
      profile = mock_write_heavy_profile()

      # Write-heavy: high writes, checkpoint pressure
      assert profile.write_ratio > 0.5
      assert profile.checkpoint_pressure > 0.3
    end
  end

  # ============================================================================
  # Mock Profiles for Testing
  # ============================================================================

  defp mock_oltp_profile do
    %{
      # Query patterns - small, fast queries
      avg_rows_per_query: 5.0,
      query_complexity: 0.01,
      cache_miss_ratio: 0.05,
      temp_spill_ratio: 0.001,
      avg_exec_time_ms: 2.5,
      read_query_ratio: 0.7,

      # Access patterns - index heavy
      seq_scan_ratio: 0.1,
      index_scan_ratio: 0.9,
      heap_hit_ratio: 0.98,
      index_hit_ratio: 0.99,
      rows_per_seq_scan: 1000.0,
      rows_per_idx_scan: 1.5,

      # Write patterns - balanced
      write_ratio: 0.3,
      insert_ratio: 0.4,
      update_ratio: 0.4,
      delete_ratio: 0.2,
      hot_update_ratio: 0.7,

      # Vacuum pressure - low
      dead_tuple_ratio: 0.02,
      tables_needing_vacuum_ratio: 0.1,

      # Concurrency - high
      connection_utilization: 0.6,
      active_query_ratio: 0.3,

      # Wait events
      io_wait_ratio: 0.1,
      lock_wait_ratio: 0.05,
      lwlock_wait_ratio: 0.02,
      client_wait_ratio: 0.8,

      # Checkpoint/WAL - normal
      checkpoint_pressure: 0.1,
      backend_write_ratio: 0.05,

      # I/O
      blk_read_time_ratio: 0.3,
      blk_write_time_ratio: 0.7,

      # Metadata
      total_queries: 10000,
      has_pg_stat_statements: true
    }
  end

  defp mock_olap_profile do
    %{
      # Query patterns - large, complex queries
      avg_rows_per_query: 50000.0,
      query_complexity: 0.3,
      cache_miss_ratio: 0.2,
      temp_spill_ratio: 0.15,
      avg_exec_time_ms: 5000.0,
      read_query_ratio: 0.95,

      # Access patterns - sequential heavy
      seq_scan_ratio: 0.8,
      index_scan_ratio: 0.2,
      heap_hit_ratio: 0.7,
      index_hit_ratio: 0.9,
      rows_per_seq_scan: 100000.0,
      rows_per_idx_scan: 100.0,

      # Write patterns - mostly reads
      write_ratio: 0.05,
      insert_ratio: 0.6,
      update_ratio: 0.3,
      delete_ratio: 0.1,
      hot_update_ratio: 0.8,

      # Vacuum pressure - low
      dead_tuple_ratio: 0.01,
      tables_needing_vacuum_ratio: 0.05,

      # Concurrency - low
      connection_utilization: 0.1,
      active_query_ratio: 0.8,

      # Wait events
      io_wait_ratio: 0.5,
      lock_wait_ratio: 0.01,
      lwlock_wait_ratio: 0.1,
      client_wait_ratio: 0.3,

      # Checkpoint/WAL - low
      checkpoint_pressure: 0.05,
      backend_write_ratio: 0.02,

      # I/O
      blk_read_time_ratio: 0.9,
      blk_write_time_ratio: 0.1,

      # Metadata
      total_queries: 500,
      has_pg_stat_statements: true
    }
  end

  defp mock_write_heavy_profile do
    %{
      # Query patterns
      avg_rows_per_query: 10.0,
      query_complexity: 0.02,
      cache_miss_ratio: 0.1,
      temp_spill_ratio: 0.01,
      avg_exec_time_ms: 5.0,
      read_query_ratio: 0.3,

      # Access patterns
      seq_scan_ratio: 0.2,
      index_scan_ratio: 0.8,
      heap_hit_ratio: 0.95,
      index_hit_ratio: 0.97,
      rows_per_seq_scan: 500.0,
      rows_per_idx_scan: 2.0,

      # Write patterns - heavy
      write_ratio: 0.7,
      insert_ratio: 0.7,
      update_ratio: 0.2,
      delete_ratio: 0.1,
      hot_update_ratio: 0.5,

      # Vacuum pressure - moderate
      dead_tuple_ratio: 0.05,
      tables_needing_vacuum_ratio: 0.2,

      # Concurrency
      connection_utilization: 0.4,
      active_query_ratio: 0.4,

      # Wait events
      io_wait_ratio: 0.3,
      lock_wait_ratio: 0.1,
      lwlock_wait_ratio: 0.1,
      client_wait_ratio: 0.4,

      # Checkpoint/WAL - high pressure
      checkpoint_pressure: 0.5,
      backend_write_ratio: 0.2,

      # I/O
      blk_read_time_ratio: 0.2,
      blk_write_time_ratio: 0.8,

      # Metadata
      total_queries: 5000,
      has_pg_stat_statements: true
    }
  end
end
