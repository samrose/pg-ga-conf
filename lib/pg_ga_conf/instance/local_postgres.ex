defmodule PgGaConf.Instance.LocalPostgres do
  @moduledoc """
  Instance provider for local PostgreSQL instances.

  This provider assumes a PostgreSQL instance is already running locally
  and returns connection information to it. It does not actually start/stop
  instances, as that typically requires system-level privileges.

  Configuration changes are logged but not actually applied, as that would
  require restarting PostgreSQL.
  """

  @behaviour PgGaConf.Instance.Provider

  require Logger

  @impl true
  def start_instance(_chromosome) do
    # For local PostgreSQL, we assume it's already running
    # Return connection info for the local instance
    instance_id = "local-" <> generate_id()

    conn_info = %{
      instance_id: instance_id,
      hostname: "localhost",
      port: 5432,
      username: "postgres",
      database: "pgga_test",
      password: nil
    }

    Logger.info("Using local PostgreSQL instance: #{instance_id}")

    {:ok, conn_info}
  end

  @impl true
  def stop_instance(instance_id) do
    # For local PostgreSQL, we don't actually stop the instance
    Logger.info("Stop requested for local instance #{instance_id} (no-op)")
    :ok
  end

  @impl true
  def apply_config(instance_id, %PgGaConf.Core.ConfigChromosome{} = chromosome) do
    # For local PostgreSQL, we can't easily apply config without restart
    # Log the configuration that would be applied
    Logger.info("Config application requested for #{instance_id}:")
    Logger.info("  shared_buffers: #{chromosome.shared_buffers}MB")
    Logger.info("  effective_cache_size: #{chromosome.effective_cache_size}MB")
    Logger.info("  work_mem: #{chromosome.work_mem}MB")
    Logger.info("  maintenance_work_mem: #{chromosome.maintenance_work_mem}MB")
    Logger.info("  (Configuration not actually applied - requires PostgreSQL restart)")

    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end
end
