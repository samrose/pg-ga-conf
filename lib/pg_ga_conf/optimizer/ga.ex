defmodule PgGaConf.Optimizer.GA do
  @moduledoc """
  Genetic Algorithm optimizer implementing the Optimizer behaviour.

  Wraps the existing GA engine to provide a unified interface
  compatible with TPE and CMA-ES optimizers.
  """

  @behaviour PgGaConf.Optimizer

  alias PgGaConf.Optimizer.Utils

  defstruct [
    :knob_space,
    :population,
    :generation,
    :population_size,
    :elitism_count,
    :mutation_rate,
    :crossover_strategy,
    :best_config,
    :best_score,
    :observations
  ]

  @default_population_size 20
  @default_elitism_count 2
  @default_mutation_rate 0.15

  @impl true
  def init(knob_space, opts \\ []) do
    population_size = Keyword.get(opts, :population_size, @default_population_size)
    elitism_count = Keyword.get(opts, :elitism_count, @default_elitism_count)
    mutation_rate = Keyword.get(opts, :mutation_rate, @default_mutation_rate)
    crossover_strategy = Keyword.get(opts, :crossover_strategy, :smart)
    seed = Keyword.get(opts, :seed)

    if seed, do: :rand.seed(:exsss, {seed, seed, seed})

    # Initialize population with random configs
    population =
      for _ <- 1..population_size do
        %{config: Utils.random_config(knob_space), fitness: nil}
      end

    state = %__MODULE__{
      knob_space: knob_space,
      population: population,
      generation: 0,
      population_size: population_size,
      elitism_count: elitism_count,
      mutation_rate: mutation_rate,
      crossover_strategy: crossover_strategy,
      best_config: nil,
      best_score: nil,
      observations: []
    }

    {:ok, state}
  end

  @impl true
  def suggest(%__MODULE__{} = state) do
    # Find an unevaluated individual in the population
    case Enum.find_index(state.population, &is_nil(&1.fitness)) do
      nil ->
        # All evaluated - evolve to next generation
        new_population = evolve_generation(state)
        new_state = %{state | population: new_population, generation: state.generation + 1}

        # Get first unevaluated from new generation
        case Enum.find(new_state.population, &is_nil(&1.fitness)) do
          nil ->
            # Shouldn't happen, but return best if it does
            {:ok, state.best_config || hd(state.population).config, new_state}

          individual ->
            {:ok, individual.config, new_state}
        end

      _idx ->
        # Return next unevaluated individual
        individual = Enum.find(state.population, &is_nil(&1.fitness))
        {:ok, individual.config, state}
    end
  end

  @impl true
  def observe(%__MODULE__{} = state, config, score) do
    # Convert score to fitness (GA maximizes, we minimize score)
    # Use inverse so lower score = higher fitness
    fitness = 1.0 / (score + 0.001)

    # Update population
    population =
      Enum.map(state.population, fn individual ->
        if individual.config == config and is_nil(individual.fitness) do
          %{individual | fitness: fitness}
        else
          individual
        end
      end)

    # Update best if improved
    {best_config, best_score} =
      if is_nil(state.best_score) or score < state.best_score do
        {config, score}
      else
        {state.best_config, state.best_score}
      end

    # Track observation
    observations = [{config, score} | state.observations]

    new_state = %{state |
      population: population,
      best_config: best_config,
      best_score: best_score,
      observations: observations
    }

    {:ok, new_state}
  end

  @impl true
  def best(%__MODULE__{best_config: nil}), do: {:error, :no_observations}

  def best(%__MODULE__{} = state) do
    {:ok, state.best_config, state.best_score}
  end

  @impl true
  def warm_start(%__MODULE__{} = state, prior_observations) do
    # Add prior observations and seed population with good configs
    Enum.reduce(prior_observations, {:ok, state}, fn {config, score}, {:ok, acc} ->
      # Add to observations
      observations = [{config, score} | acc.observations]

      # Update best
      {best_config, best_score} =
        if is_nil(acc.best_score) or score < acc.best_score do
          {config, score}
        else
          {acc.best_config, acc.best_score}
        end

      # Inject good configs into initial population
      population =
        if length(acc.observations) < acc.population_size do
          fitness = 1.0 / (score + 0.001)
          List.replace_at(acc.population, length(acc.observations), %{config: config, fitness: fitness})
        else
          acc.population
        end

      {:ok, %{acc |
        observations: observations,
        best_config: best_config,
        best_score: best_score,
        population: population
      }}
    end)
  end

  @impl true
  def serialize(%__MODULE__{} = state) do
    :erlang.term_to_binary(state)
  end

  @impl true
  def deserialize(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    _ -> {:error, :invalid_state}
  end

  # Private functions

  defp evolve_generation(state) do
    population = state.population
    population_size = state.population_size
    elitism_count = state.elitism_count

    # Sort by fitness (highest first)
    sorted = Enum.sort_by(population, & &1.fitness, :desc)

    # Preserve elite
    elite = Enum.take(sorted, elitism_count)

    # Generate offspring
    offspring_count = population_size - elitism_count

    offspring =
      for _ <- 1..div(offspring_count, 2) do
        parent1 = tournament_select(sorted)
        parent2 = tournament_select(sorted)

        {child1, child2} = crossover(parent1.config, parent2.config, state.crossover_strategy)

        child1 = mutate(child1, state.mutation_rate, state.knob_space)
        child2 = mutate(child2, state.mutation_rate, state.knob_space)

        [%{config: child1, fitness: nil}, %{config: child2, fitness: nil}]
      end
      |> List.flatten()
      |> Enum.take(offspring_count)

    elite ++ offspring
  end

  defp tournament_select(population, tournament_size \\ 3) do
    population
    |> Enum.take_random(tournament_size)
    |> Enum.max_by(& &1.fitness)
  end

  defp crossover(parent1, parent2, :uniform) do
    keys = Map.keys(parent1)

    {child1, child2} =
      Enum.reduce(keys, {%{}, %{}}, fn key, {c1, c2} ->
        if :rand.uniform() < 0.5 do
          {Map.put(c1, key, parent1[key]), Map.put(c2, key, parent2[key])}
        else
          {Map.put(c1, key, parent2[key]), Map.put(c2, key, parent1[key])}
        end
      end)

    {child1, child2}
  end

  defp crossover(parent1, parent2, :single_point) do
    keys = Map.keys(parent1) |> Enum.sort()
    point = :rand.uniform(length(keys))

    {keys1, keys2} = Enum.split(keys, point)

    child1 = Map.merge(Map.take(parent1, keys1), Map.take(parent2, keys2))
    child2 = Map.merge(Map.take(parent2, keys1), Map.take(parent1, keys2))

    {child1, child2}
  end

  defp crossover(parent1, parent2, :smart) do
    # Smart crossover: keep related parameters together
    # Memory params, WAL params, parallelism params, etc.
    memory_keys = [:shared_buffers, :work_mem, :maintenance_work_mem, :effective_cache_size]
    wal_keys = [:wal_buffers, :checkpoint_completion_target, :max_wal_size, :min_wal_size]
    parallel_keys = [:max_parallel_workers, :max_parallel_workers_per_gather, :parallel_tuple_cost]

    groups = [memory_keys, wal_keys, parallel_keys]
    all_keys = Map.keys(parent1)
    other_keys = all_keys -- List.flatten(groups)

    {child1, child2} =
      Enum.reduce(groups ++ [other_keys], {%{}, %{}}, fn group_keys, {c1, c2} ->
        relevant_keys = Enum.filter(group_keys, &(&1 in all_keys))

        if :rand.uniform() < 0.5 do
          {
            Map.merge(c1, Map.take(parent1, relevant_keys)),
            Map.merge(c2, Map.take(parent2, relevant_keys))
          }
        else
          {
            Map.merge(c1, Map.take(parent2, relevant_keys)),
            Map.merge(c2, Map.take(parent1, relevant_keys))
          }
        end
      end)

    {child1, child2}
  end

  defp mutate(config, mutation_rate, knob_space) do
    Map.new(config, fn {key, value} ->
      if :rand.uniform() < mutation_rate do
        {key, mutate_value(key, value, knob_space)}
      else
        {key, value}
      end
    end)
  end

  defp mutate_value(key, current_value, knob_space) do
    case Map.get(knob_space, key) do
      {:continuous, min, max} ->
        # Gaussian mutation
        range = max - min
        new_val = :rand.normal() * range * 0.1 + current_value
        max(min, min(max, new_val))

      {:integer, min, max} ->
        # Uniform random within range
        min + :rand.uniform(max - min + 1) - 1

      {:categorical, choices} ->
        # Random choice
        Enum.random(choices)

      nil ->
        current_value
    end
  end
end
