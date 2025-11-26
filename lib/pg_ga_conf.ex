defmodule PgGaConf do
  @moduledoc """
  PostgreSQL Genetic Algorithm Configuration Optimizer.

  Public API for optimizing PostgreSQL configurations based on
  production database profiling and genetic algorithm evolution.
  """

  alias PgGaConf.Orchestrator

  @doc """
  Optimize PostgreSQL configuration for a given database.

  ## Options

    * `:strategy` - Optimization strategy: :conservative, :moderate, :aggressive (default: :moderate)
    * `:instance_provider` - Instance provider module (default: from config)
    * `:scale_factor` - Data scale factor (default: 0.1)
    * `:generations` - Number of GA generations (default: 30)
    * `:population_size` - Population size (default: 20)
    * `:parallel_instances` - Number of parallel test instances (default: 5)
    * `:workload` - Workload generator module (default: WorkloadReplicator)

  ## Examples

      iex> PgGaConf.optimize(
      ...>   %{host: "localhost", database: "mydb", username: "postgres", password: "secret"},
      ...>   strategy: :moderate,
      ...>   generations: 30
      ...> )
      {:ok, %{optimized_config: %{}, improvements: %{}, scan_summary: %{}}}
  """
  def optimize(connection_config, opts \\ []) do
    Orchestrator.optimize(connection_config, opts)
  end

  @doc """
  Scan a database and return profiling information.
  """
  def scan(connection_config) do
    Orchestrator.scan(connection_config)
  end

  @doc """
  Generate synthetic data based on a scan result.
  """
  def generate(scan_result, target_connection_config, opts \\ []) do
    Orchestrator.generate(scan_result, target_connection_config, opts)
  end
end
