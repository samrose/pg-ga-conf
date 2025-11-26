defmodule PgGaConf.Instance.Provider do
  @moduledoc """
  Behaviour for PostgreSQL instance providers.

  Instance providers manage the lifecycle of PostgreSQL instances for benchmarking.
  This includes starting instances, applying configurations, and stopping instances.
  """

  alias PgGaConf.Core.ConfigChromosome

  @type instance_id :: String.t()

  @type connection_info :: %{
          instance_id: instance_id(),
          hostname: String.t(),
          port: integer(),
          username: String.t(),
          database: String.t(),
          password: String.t() | nil
        }

  @doc """
  Start a PostgreSQL instance with the given configuration.

  Returns connection information that can be used to connect to the instance.
  """
  @callback start_instance(ConfigChromosome.t()) :: {:ok, connection_info()} | {:error, term()}

  @doc """
  Stop a running PostgreSQL instance.
  """
  @callback stop_instance(instance_id()) :: :ok | {:error, term()}

  @doc """
  Apply a configuration to an existing instance.

  This may involve restarting the instance or reloading configuration.
  """
  @callback apply_config(instance_id(), ConfigChromosome.t()) :: :ok | {:error, term()}
end
