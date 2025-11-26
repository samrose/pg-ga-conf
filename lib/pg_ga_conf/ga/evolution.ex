defmodule PgGaConf.GA.Evolution do
  @moduledoc """
  Evolution operators: crossover and mutation for genetic algorithm.

  Implements uniform, single-point, and smart crossover strategies,
  plus Gaussian mutation for evolving PostgreSQL configurations.
  """

  alias PgGaConf.Core.ConfigChromosome

  # Related parameter groups for smart crossover
  @memory_params [:shared_buffers, :effective_cache_size]
  @work_mem_params [:work_mem, :maintenance_work_mem]
  @checkpoint_params [:checkpoint_completion_target, :checkpoint_timeout, :max_wal_size]
  @parallel_params [:max_worker_processes, :max_parallel_workers_per_gather, :max_parallel_workers]
  @io_params [:effective_io_concurrency, :random_page_cost]
  @autovacuum_params [:autovacuum_scale_factor, :autovacuum_vacuum_cost_limit]

  @all_params [
    :shared_buffers,
    :effective_cache_size,
    :work_mem,
    :maintenance_work_mem,
    :checkpoint_completion_target,
    :checkpoint_timeout,
    :max_wal_size,
    :wal_buffers,
    :default_statistics_target,
    :random_page_cost,
    :effective_io_concurrency,
    :max_worker_processes,
    :max_parallel_workers_per_gather,
    :max_parallel_workers,
    :autovacuum_scale_factor,
    :autovacuum_vacuum_cost_limit
  ]

  @doc """
  Perform crossover between two parent chromosomes.

  ## Strategies

    - `:uniform` - Each parameter randomly chosen from either parent
    - `:single_point` - Parameters split at random point
    - `:smart` - Groups related parameters together

  ## Returns

  A tuple of two offspring chromosomes.
  """
  @spec crossover(ConfigChromosome.t(), ConfigChromosome.t(), atom()) ::
          {ConfigChromosome.t(), ConfigChromosome.t()}
  def crossover(parent1, parent2, :uniform) do
    uniform_crossover(parent1, parent2)
  end

  def crossover(parent1, parent2, :single_point) do
    single_point_crossover(parent1, parent2)
  end

  def crossover(parent1, parent2, :smart) do
    smart_crossover(parent1, parent2)
  end

  @doc """
  Mutate a chromosome using Gaussian perturbation.

  ## Parameters

    - chromosome: The chromosome to mutate
    - mutation_rate: Probability (0.0-1.0) that each parameter mutates
    - bounds: Parameter bounds map from strategy

  ## Returns

  A new mutated chromosome.
  """
  @spec mutate(ConfigChromosome.t(), float(), map()) :: ConfigChromosome.t()
  def mutate(chromosome, mutation_rate, bounds) do
    mutated_params =
      @all_params
      |> Enum.map(fn param ->
        current_value = Map.get(chromosome, param)

        new_value =
          if current_value != nil and Map.has_key?(bounds, param) and :rand.uniform() < mutation_rate do
            param_bounds = Map.get(bounds, param)
            value_type = if is_float(current_value), do: :float, else: :integer
            gaussian_mutate_value(current_value, param_bounds, value_type)
          else
            current_value
          end

        {param, new_value}
      end)
      |> Enum.into(%{})

    struct(ConfigChromosome, mutated_params)
  end

  @doc """
  Apply Gaussian mutation to a single value.

  Adds Gaussian noise scaled to the parameter range, then clamps to bounds.
  """
  @spec gaussian_mutate_value(number(), {number(), number()}, :integer | :float) :: number()
  def gaussian_mutate_value(value, {min, max}, value_type) do
    # Gaussian noise with mean=0, stddev=range/6 (so ~99% of mutations within range)
    range = max - min
    stddev = range / 6.0
    noise = gaussian_random() * stddev

    mutated =
      case value_type do
        :float ->
          value + noise

        :integer ->
          round(value + noise)
      end

    # Clamp to bounds
    mutated
    |> max(min)
    |> min(max)
  end

  # Private functions

  defp uniform_crossover(parent1, parent2) do
    {params1, params2} =
      @all_params
      |> Enum.map(fn param ->
        val1 = Map.get(parent1, param)
        val2 = Map.get(parent2, param)

        if :rand.uniform() < 0.5 do
          {{param, val1}, {param, val2}}
        else
          {{param, val2}, {param, val1}}
        end
      end)
      |> Enum.unzip()

    child1 = struct(ConfigChromosome, Enum.into(params1, %{}))
    child2 = struct(ConfigChromosome, Enum.into(params2, %{}))

    {child1, child2}
  end

  defp single_point_crossover(parent1, parent2) do
    # Random crossover point
    point = :rand.uniform(length(@all_params))

    {before, after_point} = Enum.split(@all_params, point)

    params1 =
      Enum.map(before, fn p -> {p, Map.get(parent1, p)} end) ++
        Enum.map(after_point, fn p -> {p, Map.get(parent2, p)} end)

    params2 =
      Enum.map(before, fn p -> {p, Map.get(parent2, p)} end) ++
        Enum.map(after_point, fn p -> {p, Map.get(parent1, p)} end)

    child1 = struct(ConfigChromosome, Enum.into(params1, %{}))
    child2 = struct(ConfigChromosome, Enum.into(params2, %{}))

    {child1, child2}
  end

  defp smart_crossover(parent1, parent2) do
    # Group related parameters and randomly inherit entire groups
    param_groups = [
      @memory_params,
      @work_mem_params,
      @checkpoint_params,
      @parallel_params,
      @io_params,
      @autovacuum_params,
      # Individual params not in groups
      [:wal_buffers],
      [:default_statistics_target]
    ]

    {params1, params2} =
      param_groups
      |> Enum.flat_map(fn group ->
        if :rand.uniform() < 0.5 do
          # Child1 inherits from parent1, child2 from parent2
          Enum.map(group, fn p ->
            {{p, Map.get(parent1, p)}, {p, Map.get(parent2, p)}}
          end)
        else
          # Child1 inherits from parent2, child2 from parent1
          Enum.map(group, fn p ->
            {{p, Map.get(parent2, p)}, {p, Map.get(parent1, p)}}
          end)
        end
      end)
      |> Enum.unzip()

    child1 = struct(ConfigChromosome, Enum.into(params1, %{}))
    child2 = struct(ConfigChromosome, Enum.into(params2, %{}))

    {child1, child2}
  end

  # Box-Muller transform to generate Gaussian random numbers
  defp gaussian_random do
    u1 = :rand.uniform()
    u2 = :rand.uniform()

    :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
  end
end
