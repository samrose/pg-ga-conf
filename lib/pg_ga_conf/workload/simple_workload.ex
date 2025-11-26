defmodule PgGaConf.Workload.SimpleWorkload do
  @moduledoc """
  Simple workload generator for basic benchmarking.

  Executes simple SELECT queries to generate database load.
  Useful for testing cache hit ratios and basic throughput.
  """

  @behaviour PgGaConf.Workload.Generator

  require Logger

  @default_duration_seconds 10

  @impl true
  def run(conn, opts \\ []) do
    duration_seconds = Keyword.get(opts, :duration_seconds, @default_duration_seconds)
    # Use milliseconds for better precision
    end_time = System.monotonic_time(:millisecond) + round(duration_seconds * 1000)

    Logger.debug("Starting simple workload for #{duration_seconds}s")

    run_loop(conn, end_time)

    Logger.debug("Simple workload complete")
    :ok
  end

  # Private functions

  defp run_loop(conn, end_time) do
    if System.monotonic_time(:millisecond) < end_time do
      # Execute a variety of simple queries
      Postgrex.query!(conn, "SELECT 1", [])
      Postgrex.query!(conn, "SELECT 2 + 2", [])
      Postgrex.query!(conn, "SELECT now()", [])
      Postgrex.query!(conn, "SELECT version()", [])
      Postgrex.query!(conn, "SELECT current_database()", [])

      # Recurse to continue workload
      run_loop(conn, end_time)
    end
  end
end
