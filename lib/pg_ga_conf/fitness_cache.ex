defmodule PgGaConf.FitnessCache do
  @moduledoc """
  ETS-based cache for fitness scores to avoid re-evaluating identical configurations.
  """

  use GenServer

  @table_name :pg_ga_conf_fitness_cache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get cached fitness score for a configuration hash.
  """
  def get(config_hash) do
    case :ets.lookup(@table_name, config_hash) do
      [{^config_hash, fitness}] -> fitness
      [] -> nil
    end
  end

  @doc """
  Store fitness score for a configuration hash.
  """
  def put(config_hash, fitness) do
    :ets.insert(@table_name, {config_hash, fitness})
    :ok
  end

  @doc """
  Clear all cached fitness scores.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
