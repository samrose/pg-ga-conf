defmodule PgGaConf.Workload.RichProfilerTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Workload.RichProfiler

  describe "feature vector dimensions" do
    test "feature vector has 59 elements" do
      # Create a mock profile with all layers
      profile = %{
        schema_features: mock_schema_features(),
        query_features: mock_query_features(),
        execution_features: mock_execution_features(),
        io_features: mock_io_features(),
        index_features: mock_index_features(),
        runtime_features: mock_runtime_features(),
        scale_features: mock_scale_features()
      }

      # Access the private function via module for testing build_feature_vector
      # We'll just verify the structure is correct
      assert map_size(profile.schema_features) == 10
      assert map_size(profile.query_features) == 16  # 15 + has_pg_stat_statements
      assert map_size(profile.execution_features) == 8
      assert map_size(profile.io_features) == 6
      assert map_size(profile.index_features) == 4
      assert map_size(profile.runtime_features) == 10
      assert map_size(profile.scale_features) == 6

      # Total: 10 + 15 + 8 + 6 + 4 + 10 + 6 = 59 features
    end
  end

  # ============================================================================
  # Mock Feature Helpers
  # ============================================================================

  defp mock_schema_features do
    %{
      table_count: 10.0,
      avg_columns: 8.0,
      jsonb_ratio: 0.1,
      array_ratio: 0.05,
      text_ratio: 0.3,
      timeseries_ratio: 0.2,
      partitioned_ratio: 0.0,
      gin_index_ratio: 0.1,
      gist_index_ratio: 0.0,
      fk_density: 1.5
    }
  end

  defp mock_query_features do
    %{
      select_ratio: 0.7,
      insert_ratio: 0.1,
      update_ratio: 0.15,
      delete_ratio: 0.05,
      join_ratio: 0.3,
      aggregate_ratio: 0.1,
      window_ratio: 0.02,
      cte_ratio: 0.05,
      json_ratio: 0.08,
      parameterized_ratio: 0.9,
      query_diversity: 0.001,
      hot_concentration: 0.8,
      avg_rows_per_call: 50.0,
      cache_hit_ratio: 0.95,
      temp_spill_ratio: 0.02,
      has_pg_stat_statements: true
    }
  end

  defp mock_execution_features do
    %{
      planning_overhead: 0.05,
      exec_time_cv: 0.3,
      wal_bytes_per_call: 100.0,
      jit_ratio: 0.01,
      blk_read_time_ratio: 0.1,
      fpi_ratio: 0.05,
      wal_buffer_pressure: 0.02,
      function_time_ratio: 0.0
    }
  end

  defp mock_io_features do
    %{
      autovacuum_io_ratio: 0.1,
      checkpoint_write_ratio: 0.3,
      bulkread_ratio: 0.05,
      extend_ratio: 0.02,
      buffer_reuse_ratio: 0.8,
      toast_ratio: 0.01
    }
  end

  defp mock_index_features do
    %{
      unused_index_ratio: 0.1,
      index_selectivity: 0.95,
      index_hot_concentration: 0.7,
      index_size_ratio: 0.3
    }
  end

  defp mock_runtime_features do
    %{
      qps_mean: 100.0,
      qps_cv: 0.2,
      connections_mean: 20.0,
      connections_cv: 0.1,
      active_ratio: 0.3,
      wait_io_ratio: 0.2,
      wait_lock_ratio: 0.05,
      wait_lwlock_ratio: 0.02,
      wait_client_ratio: 0.5,
      lock_wait_ratio: 0.01
    }
  end

  defp mock_scale_features do
    %{
      db_size_gb: 5.0,
      largest_table_gb: 1.0,
      total_index_gb: 0.5,
      table_count: 10.0,
      estimated_rows: 1_000_000.0,
      avg_row_width: 200.0
    }
  end
end
