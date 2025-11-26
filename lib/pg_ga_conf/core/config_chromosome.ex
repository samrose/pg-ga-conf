defmodule PgGaConf.Core.ConfigChromosome do
  @moduledoc """
  Represents a PostgreSQL configuration as a chromosome for genetic algorithm.
  """

  defstruct [
    # Memory settings (in MB)
    :shared_buffers,
    :effective_cache_size,
    :work_mem,
    :maintenance_work_mem,

    # Checkpointing & WAL
    :checkpoint_completion_target,
    :checkpoint_timeout,
    :max_wal_size,
    :wal_buffers,

    # Query planning
    :default_statistics_target,
    :random_page_cost,
    :effective_io_concurrency,

    # Parallelism
    :max_worker_processes,
    :max_parallel_workers_per_gather,
    :max_parallel_workers,

    # Autovacuum (optional, aggressive only)
    :autovacuum_scale_factor,
    :autovacuum_vacuum_cost_limit,

    # Metadata
    :fitness,
    :generation,
    :metrics
  ]

  @type t :: %__MODULE__{
    shared_buffers: non_neg_integer(),
    effective_cache_size: non_neg_integer(),
    work_mem: non_neg_integer(),
    maintenance_work_mem: non_neg_integer(),
    checkpoint_completion_target: float(),
    checkpoint_timeout: non_neg_integer(),
    max_wal_size: non_neg_integer(),
    wal_buffers: non_neg_integer(),
    default_statistics_target: non_neg_integer(),
    random_page_cost: float(),
    effective_io_concurrency: non_neg_integer(),
    max_worker_processes: non_neg_integer(),
    max_parallel_workers_per_gather: non_neg_integer(),
    max_parallel_workers: non_neg_integer(),
    autovacuum_scale_factor: float() | nil,
    autovacuum_vacuum_cost_limit: non_neg_integer() | nil,
    fitness: float() | nil,
    generation: non_neg_integer(),
    metrics: map() | nil
  }

  @doc """
  Creates a new chromosome with default or custom values.
  """
  def new(params \\ %{}) do
    defaults = %{
      shared_buffers: 256,
      effective_cache_size: 1024,
      work_mem: 4,
      maintenance_work_mem: 64,
      checkpoint_completion_target: 0.9,
      checkpoint_timeout: 300,
      max_wal_size: 1024,
      wal_buffers: 16,
      default_statistics_target: 100,
      random_page_cost: 4.0,
      effective_io_concurrency: 1,
      max_worker_processes: 8,
      max_parallel_workers_per_gather: 2,
      max_parallel_workers: 8,
      autovacuum_scale_factor: nil,
      autovacuum_vacuum_cost_limit: nil,
      fitness: nil,
      generation: 0,
      metrics: nil
    }

    struct(__MODULE__, Map.merge(defaults, params))
  end

  @doc """
  Converts chromosome to PostgreSQL configuration format.
  """
  def to_postgresql_conf(%__MODULE__{} = chromosome) do
    base_config = %{
      "shared_buffers" => "#{chromosome.shared_buffers}MB",
      "effective_cache_size" => "#{chromosome.effective_cache_size}MB",
      "work_mem" => "#{chromosome.work_mem}MB",
      "maintenance_work_mem" => "#{chromosome.maintenance_work_mem}MB",
      "checkpoint_completion_target" => Float.to_string(chromosome.checkpoint_completion_target),
      "checkpoint_timeout" => "#{chromosome.checkpoint_timeout}s",
      "max_wal_size" => "#{chromosome.max_wal_size}MB",
      "wal_buffers" => "#{chromosome.wal_buffers}MB",
      "default_statistics_target" => Integer.to_string(chromosome.default_statistics_target),
      "random_page_cost" => Float.to_string(chromosome.random_page_cost),
      "effective_io_concurrency" => Integer.to_string(chromosome.effective_io_concurrency),
      "max_worker_processes" => Integer.to_string(chromosome.max_worker_processes),
      "max_parallel_workers_per_gather" => Integer.to_string(chromosome.max_parallel_workers_per_gather),
      "max_parallel_workers" => Integer.to_string(chromosome.max_parallel_workers)
    }

    # Add autovacuum settings if present
    if chromosome.autovacuum_scale_factor do
      Map.merge(base_config, %{
        "autovacuum_scale_factor" => Float.to_string(chromosome.autovacuum_scale_factor),
        "autovacuum_vacuum_cost_limit" => Integer.to_string(chromosome.autovacuum_vacuum_cost_limit)
      })
    else
      base_config
    end
  end

  @doc """
  Validates chromosome constraints.
  """
  def validate(%__MODULE__{} = chromosome) do
    cond do
      chromosome.effective_cache_size < chromosome.shared_buffers ->
        {:error, "effective_cache_size must be >= shared_buffers"}

      chromosome.checkpoint_completion_target < 0 or chromosome.checkpoint_completion_target > 1 ->
        {:error, "checkpoint_completion_target must be between 0 and 1"}

      chromosome.max_parallel_workers < chromosome.max_parallel_workers_per_gather ->
        {:error, "max_parallel_workers must be >= max_parallel_workers_per_gather"}

      true ->
        :ok
    end
  end
end
