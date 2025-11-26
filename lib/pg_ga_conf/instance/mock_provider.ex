defmodule PgGaConf.Instance.MockProvider do
  @moduledoc """
  Mock instance provider for testing and development.

  This provider simulates instance management without actually creating
  any PostgreSQL instances. Useful for testing the GA engine and
  benchmarking logic without real infrastructure.
  """

  @behaviour PgGaConf.Instance.Provider

  require Logger

  @impl true
  def start_instance(_chromosome) do
    instance_id = "mock-" <> generate_id()

    conn_info = %{
      instance_id: instance_id,
      hostname: "mock-host",
      port: 5432,
      username: "mock-user",
      database: "mock-db",
      password: nil
    }

    Logger.debug("Mock instance started: #{instance_id}")

    {:ok, conn_info}
  end

  @impl true
  def stop_instance(instance_id) do
    Logger.debug("Mock instance stopped: #{instance_id}")
    :ok
  end

  @impl true
  def apply_config(instance_id, %PgGaConf.Core.ConfigChromosome{} = chromosome) do
    Logger.debug(
      "Mock config applied to #{instance_id}: shared_buffers=#{chromosome.shared_buffers}MB"
    )

    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end
end
