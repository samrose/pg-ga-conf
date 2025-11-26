defmodule PgGaConf.Strategies.Moderate do
  @moduledoc """
  Moderate optimization strategy - balanced approach (default).
  """

  @behaviour PgGaConf.Strategies.Strategy

  alias PgGaConf.Core.ConfigChromosome

  @impl true
  def parameter_bounds do
    %{
      shared_buffers: {256, 8192},
      effective_cache_size: {1024, 32768},
      work_mem: {4, 128},
      maintenance_work_mem: {64, 1024},
      checkpoint_completion_target: {0.5, 0.9},
      checkpoint_timeout: {300, 1800},
      max_wal_size: {1024, 8192},
      wal_buffers: {16, 128},
      default_statistics_target: {100, 300},
      random_page_cost: {1.0, 4.0},
      effective_io_concurrency: {1, 200},
      max_worker_processes: {8, 32},
      max_parallel_workers_per_gather: {0, 8},
      max_parallel_workers: {8, 32}
    }
  end

  @impl true
  def mutation_rate, do: 0.15

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
      checkpoint_completion_target: random_float_in_range(bounds.checkpoint_completion_target),
      checkpoint_timeout: random_in_range(bounds.checkpoint_timeout),
      max_wal_size: random_in_range(bounds.max_wal_size),
      wal_buffers: random_in_range(bounds.wal_buffers),
      default_statistics_target: random_in_range(bounds.default_statistics_target),
      random_page_cost: random_float_in_range(bounds.random_page_cost),
      effective_io_concurrency: random_in_range(bounds.effective_io_concurrency),
      max_worker_processes: random_in_range(bounds.max_worker_processes),
      max_parallel_workers_per_gather: random_in_range(bounds.max_parallel_workers_per_gather),
      max_parallel_workers: random_in_range(bounds.max_parallel_workers)
    })
  end

  defp random_in_range({min, max}) when is_integer(min) and is_integer(max) do
    min + :rand.uniform(max - min + 1) - 1
  end

  defp random_float_in_range({min, max}) do
    min + :rand.uniform() * (max - min)
  end
end
