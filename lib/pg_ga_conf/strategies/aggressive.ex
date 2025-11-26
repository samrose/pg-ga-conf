defmodule PgGaConf.Strategies.Aggressive do
  @moduledoc """
  Aggressive optimization strategy - all parameters, wider bounds.
  """

  @behaviour PgGaConf.Strategies.Strategy

  alias PgGaConf.Core.ConfigChromosome

  @impl true
  def parameter_bounds do
    %{
      shared_buffers: {512, 16384},
      effective_cache_size: {2048, 65536},
      work_mem: {8, 256},
      maintenance_work_mem: {128, 2048},
      checkpoint_completion_target: {0.5, 0.95},
      checkpoint_timeout: {300, 3600},
      max_wal_size: {2048, 51200},
      wal_buffers: {32, 256},
      default_statistics_target: {100, 500},
      random_page_cost: {1.0, 4.0},
      effective_io_concurrency: {100, 1000},
      max_worker_processes: {16, 64},
      max_parallel_workers_per_gather: {2, 16},
      max_parallel_workers: {16, 64},
      autovacuum_scale_factor: {0.01, 0.2},
      autovacuum_vacuum_cost_limit: {200, 3000}
    }
  end

  @impl true
  def mutation_rate, do: 0.2

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
      max_parallel_workers: random_in_range(bounds.max_parallel_workers),
      autovacuum_scale_factor: random_float_in_range(bounds.autovacuum_scale_factor),
      autovacuum_vacuum_cost_limit: random_in_range(bounds.autovacuum_vacuum_cost_limit)
    })
  end

  defp random_in_range({min, max}) when is_integer(min) and is_integer(max) do
    min + :rand.uniform(max - min + 1) - 1
  end

  defp random_float_in_range({min, max}) do
    min + :rand.uniform() * (max - min)
  end
end
