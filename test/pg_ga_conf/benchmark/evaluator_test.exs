defmodule PgGaConf.Benchmark.EvaluatorTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias PgGaConf.Benchmark.Evaluator
  alias PgGaConf.Core.{ConfigChromosome, Metrics}
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

  describe "evaluate/3" do
    test "evaluates configuration and returns metrics", %{conn: conn} do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      # Simple workload function
      workload = fn _conn -> :ok end

      metrics = Evaluator.evaluate(chromosome, conn, workload)

      assert %Metrics{} = metrics
      assert is_float(metrics.cache_hit_ratio)
    end

    test "runs workload during evaluation", %{conn: conn} do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      # Track if workload was called
      test_pid = self()
      workload = fn _conn ->
        send(test_pid, :workload_executed)
        :ok
      end

      Evaluator.evaluate(chromosome, conn, workload)

      assert_received :workload_executed
    end

    test "collects metrics after workload", %{conn: conn} do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      # Workload that generates some activity
      workload = fn conn ->
        for _ <- 1..5 do
          Postgrex.query!(conn, "SELECT 1", [])
        end
        :ok
      end

      metrics = Evaluator.evaluate(chromosome, conn, workload, duration_seconds: 1)

      assert metrics.duration_seconds == 1
      assert is_float(metrics.cache_hit_ratio)
    end
  end
end
