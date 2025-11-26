defmodule PgGaConf.Workload.Generator do
  @moduledoc """
  Behaviour for workload generators.

  Workload generators create database load for benchmarking PostgreSQL configurations.
  Different workload types can stress different aspects of the database.
  """

  @doc """
  Run a workload against a PostgreSQL connection.

  ## Options

    - `:duration_seconds` - How long to run the workload (default: 10)

  ## Returns

  `:ok` when the workload completes.
  """
  @callback run(Postgrex.conn(), keyword()) :: :ok
end
