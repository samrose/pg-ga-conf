defmodule PgGaConf.Strategies.Conservative do
  @moduledoc """
  Conservative optimization strategy - only safe parameters.
  """

  @behaviour PgGaConf.Strategies.Strategy

  alias PgGaConf.Core.ConfigChromosome

  @impl true
  def parameter_bounds do
    %{
      shared_buffers: {128, 4096},
      effective_cache_size: {512, 16384},
      work_mem: {4, 64},
      maintenance_work_mem: {64, 512},
      default_statistics_target: {100, 200},
      random_page_cost: {1.0, 4.0}
    }
  end

  @impl true
  def mutation_rate, do: 0.1

  @impl true
  def crossover_strategy, do: :smart

  @impl true
  def generate_random_config do
    bounds = parameter_bounds()

    ConfigChromosome.new(%{
      shared_buffers: random_in_range(bounds.shared_buffers),
      effective_cache_size: random_in_range(bounds.effective_cache_size),
      work_mem: random_in_range(bounds.work_mem),
      maintenance_work_mem: random_in_range(bounds.maintenance_work_mem),
      default_statistics_target: random_in_range(bounds.default_statistics_target),
      random_page_cost: random_float_in_range(bounds.random_page_cost)
    })
  end

  defp random_in_range({min, max}) when is_integer(min) and is_integer(max) do
    min + :rand.uniform(max - min + 1) - 1
  end

  defp random_float_in_range({min, max}) when is_float(min) and is_float(max) do
    min + :rand.uniform() * (max - min)
  end

  defp random_float_in_range({min, max}) when is_number(min) and is_number(max) do
    min + :rand.uniform() * (max - min)
  end
end
