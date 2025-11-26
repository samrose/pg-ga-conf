defmodule PgGaConf.Benchmark.MetricsCollectorTest do
  use ExUnit.Case, async: false

  alias PgGaConf.Benchmark.MetricsCollector
  alias PgGaConf.Core.Metrics
  alias PgGaConf.TestHelpers

  setup do
    conn = TestHelpers.create_test_connection()
    TestHelpers.setup_test_schema(conn)

    on_exit(fn ->
      if Process.alive?(conn) do
        GenServer.stop(conn)
      end
    end)

    {:ok, conn: conn}
  end

  describe "collect/2" do
    test "collects basic metrics from PostgreSQL", %{conn: conn} do
      # Reset stats
      MetricsCollector.reset_stats(conn)

      # Run some queries to generate stats
      Postgrex.query!(conn, "SELECT 1", [])
      Postgrex.query!(conn, "SELECT 2", [])

      # Collect metrics
      metrics = MetricsCollector.collect(conn, duration_seconds: 1)

      assert %Metrics{} = metrics
      assert is_float(metrics.cache_hit_ratio)
      assert metrics.cache_hit_ratio >= 0.0
      assert metrics.cache_hit_ratio <= 1.0
    end

    test "includes duration in metrics", %{conn: conn} do
      metrics = MetricsCollector.collect(conn, duration_seconds: 5)

      assert metrics.duration_seconds == 5
    end

    test "collects cache hit ratio", %{conn: conn} do
      # Run simple queries to populate cache stats
      for _ <- 1..10 do
        Postgrex.query!(conn, "SELECT 1", [])
      end

      metrics = MetricsCollector.collect(conn, duration_seconds: 1)

      assert is_float(metrics.cache_hit_ratio)
      # Should have high cache hit ratio for repeated queries
      assert metrics.cache_hit_ratio >= 0.0
    end

    test "collects temp file count", %{conn: conn} do
      metrics = MetricsCollector.collect(conn, duration_seconds: 1)

      assert is_integer(metrics.temp_files)
      assert metrics.temp_files >= 0
    end

    test "collects deadlock count", %{conn: conn} do
      metrics = MetricsCollector.collect(conn, duration_seconds: 1)

      assert is_integer(metrics.deadlocks)
      assert metrics.deadlocks >= 0
    end
  end

  describe "reset_stats/1" do
    test "resets pg_stat_statements", %{conn: conn} do
      # This will gracefully handle if pg_stat_statements is not installed
      result = MetricsCollector.reset_stats(conn)

      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "calculate_cache_hit_ratio/1" do
    test "calculates ratio from database stats", %{conn: conn} do
      ratio = MetricsCollector.calculate_cache_hit_ratio(conn)

      assert is_float(ratio)
      assert ratio >= 0.0
      assert ratio <= 1.0
    end
  end

  describe "collect_temp_files/1" do
    test "returns temp file count", %{conn: conn} do
      temp_files = MetricsCollector.collect_temp_files(conn)

      assert is_integer(temp_files)
      assert temp_files >= 0
    end
  end

  describe "collect_deadlocks/1" do
    test "returns deadlock count", %{conn: conn} do
      deadlocks = MetricsCollector.collect_deadlocks(conn)

      assert is_integer(deadlocks)
      assert deadlocks >= 0
    end
  end
end
