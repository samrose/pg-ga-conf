defmodule PgGaConf.Benchmark.Evaluator do
  @moduledoc """
  Evaluates PostgreSQL configurations by running workloads and collecting metrics.

  This module coordinates the benchmark process: applying configuration,
  running workload, and collecting performance metrics.
  """

  require Logger

  alias PgGaConf.Benchmark.MetricsCollector
  alias PgGaConf.Core.{ConfigChromosome, Metrics}

  @default_duration_seconds 10

  @doc """
  Evaluate a configuration by running a workload and collecting metrics.

  ## Parameters

    - chromosome: Configuration to evaluate
    - conn: PostgreSQL connection
    - workload: Function (conn -> :ok) that generates database load
    - opts: Options
      - `:duration_seconds` - How long to run the workload (default: 10)

  ## Returns

  A `Metrics` struct with performance data.
  """
  @spec evaluate(ConfigChromosome.t(), Postgrex.conn(), function(), keyword()) :: Metrics.t()
  def evaluate(chromosome, conn, workload, opts \\ []) do
    duration_seconds = Keyword.get(opts, :duration_seconds, @default_duration_seconds)

    Logger.info("Evaluating configuration: shared_buffers=#{chromosome.shared_buffers}MB")

    # Note: In a real implementation, we would:
    # 1. Apply the configuration to PostgreSQL (requires restart or reload)
    # 2. Wait for the instance to be ready
    # For now, we simulate by just running the workload

    # Reset statistics before benchmark
    MetricsCollector.reset_stats(conn)

    # Run the workload
    task =
      Task.async(fn ->
        workload.(conn)
      end)

    # Wait for duration or task completion
    case Task.yield(task, round(duration_seconds * 1000)) || Task.shutdown(task) do
      {:ok, _result} ->
        Logger.debug("Workload completed successfully")

      {:exit, reason} ->
        Logger.warning("Workload exited: #{inspect(reason)}")

      nil ->
        Logger.debug("Workload timed out after #{duration_seconds}s")
    end

    # Collect metrics
    # Use the requested duration_seconds for metrics context
    # This represents the benchmark window, even if workload completes early
    metrics = MetricsCollector.collect(conn, duration_seconds: duration_seconds)

    Logger.info("Evaluation complete: TPS=#{Float.round(metrics.transactions_per_sec, 2)}, cache_hit=#{Float.round(metrics.cache_hit_ratio * 100, 1)}%")

    metrics
  end
end
