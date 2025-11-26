defmodule PgGaConf.Workload.SimpleWorkloadTest do
  use ExUnit.Case, async: false

  alias PgGaConf.Workload.SimpleWorkload
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

  describe "run/2" do
    test "executes simple SELECT queries", %{conn: conn} do
      # Run for a very short duration
      assert :ok = SimpleWorkload.run(conn, duration_seconds: 0.1)
    end

    test "runs workload for specified duration", %{conn: conn} do
      start_time = System.monotonic_time(:millisecond)
      SimpleWorkload.run(conn, duration_seconds: 0.2)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should run for approximately 200ms
      # Allow some tolerance (100ms - 400ms)
      assert elapsed >= 100
      assert elapsed <= 400
    end

    test "generates database activity", %{conn: conn} do
      # Run workload
      SimpleWorkload.run(conn, duration_seconds: 0.1)

      # Verify connection is still alive after workload
      assert Process.alive?(conn)

      # Verify we can still query the database
      {:ok, result} = Postgrex.query(conn, "SELECT 1", [])
      assert result.num_rows == 1
    end
  end
end
