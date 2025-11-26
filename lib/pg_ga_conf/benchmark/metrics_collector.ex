defmodule PgGaConf.Benchmark.MetricsCollector do
  @moduledoc """
  Collects performance metrics from PostgreSQL.

  Gathers metrics from pg_stat_database, pg_stat_statements (if available),
  and other system views to evaluate configuration performance.
  """

  require Logger

  alias PgGaConf.Core.Metrics

  @doc """
  Collect performance metrics from a PostgreSQL connection.

  ## Options

    - `:duration_seconds` - Duration of the benchmark run (for context)

  ## Returns

  A `Metrics` struct with collected data.
  """
  @spec collect(Postgrex.conn(), keyword()) :: Metrics.t()
  def collect(conn, opts \\ []) do
    duration_seconds = Keyword.get(opts, :duration_seconds, 0)

    %Metrics{
      transactions_per_sec: calculate_tps(conn, duration_seconds),
      p50_latency_ms: 0.0,
      p95_latency_ms: 0.0,
      p99_latency_ms: 0.0,
      cache_hit_ratio: calculate_cache_hit_ratio(conn),
      temp_files: collect_temp_files(conn),
      deadlocks: collect_deadlocks(conn),
      timeouts: 0,
      duration_seconds: duration_seconds
    }
  end

  @doc """
  Reset pg_stat_statements to clear query statistics.

  Returns :ok on success, {:error, reason} if pg_stat_statements is not available.
  """
  @spec reset_stats(Postgrex.conn()) :: :ok | {:error, term()}
  def reset_stats(conn) do
    case Postgrex.query(conn, "SELECT pg_stat_statements_reset()", []) do
      {:ok, _} ->
        Logger.info("Reset pg_stat_statements")
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_function}}} ->
        Logger.info("pg_stat_statements not available, skipping reset")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to reset pg_stat_statements: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Calculate cache hit ratio from pg_stat_database.

  Returns a float between 0.0 and 1.0.
  """
  @spec calculate_cache_hit_ratio(Postgrex.conn()) :: float()
  def calculate_cache_hit_ratio(conn) do
    query = """
    SELECT
      CASE
        WHEN blks_read + blks_hit = 0 THEN 1.0
        ELSE blks_hit::float / (blks_read + blks_hit)
      END AS cache_hit_ratio
    FROM pg_stat_database
    WHERE datname = current_database()
    """

    case Postgrex.query(conn, query, []) do
      {:ok, %Postgrex.Result{rows: [[ratio]]}} when is_float(ratio) or is_integer(ratio) ->
        ratio * 1.0

      {:ok, %Postgrex.Result{rows: []}} ->
        # No stats yet
        1.0

      {:error, reason} ->
        Logger.warning("Failed to calculate cache hit ratio: #{inspect(reason)}")
        0.0
    end
  end

  @doc """
  Collect count of temp files written.
  """
  @spec collect_temp_files(Postgrex.conn()) :: integer()
  def collect_temp_files(conn) do
    query = """
    SELECT COALESCE(temp_files, 0) AS temp_files
    FROM pg_stat_database
    WHERE datname = current_database()
    """

    case Postgrex.query(conn, query, []) do
      {:ok, %Postgrex.Result{rows: [[temp_files]]}} when is_integer(temp_files) ->
        temp_files

      {:ok, %Postgrex.Result{rows: []}} ->
        0

      {:error, reason} ->
        Logger.warning("Failed to collect temp files: #{inspect(reason)}")
        0
    end
  end

  @doc """
  Collect count of deadlocks.
  """
  @spec collect_deadlocks(Postgrex.conn()) :: integer()
  def collect_deadlocks(conn) do
    query = """
    SELECT COALESCE(deadlocks, 0) AS deadlocks
    FROM pg_stat_database
    WHERE datname = current_database()
    """

    case Postgrex.query(conn, query, []) do
      {:ok, %Postgrex.Result{rows: [[deadlocks]]}} when is_integer(deadlocks) ->
        deadlocks

      {:ok, %Postgrex.Result{rows: []}} ->
        0

      {:error, reason} ->
        Logger.warning("Failed to collect deadlocks: #{inspect(reason)}")
        0
    end
  end

  # Private functions

  defp calculate_tps(conn, duration_seconds) when duration_seconds > 0 do
    # Get transaction count from pg_stat_database
    query = """
    SELECT xact_commit + xact_rollback AS total_xacts
    FROM pg_stat_database
    WHERE datname = current_database()
    """

    case Postgrex.query(conn, query, []) do
      {:ok, %Postgrex.Result{rows: [[total_xacts]]}} when is_integer(total_xacts) ->
        total_xacts / duration_seconds * 1.0

      {:ok, %Postgrex.Result{rows: []}} ->
        0.0

      {:error, reason} ->
        Logger.warning("Failed to calculate TPS: #{inspect(reason)}")
        0.0
    end
  end

  defp calculate_tps(_conn, _duration_seconds), do: 0.0
end
