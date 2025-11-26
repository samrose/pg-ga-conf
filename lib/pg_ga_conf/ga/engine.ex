defmodule PgGaConf.GA.Engine do
  @moduledoc """
  Main genetic algorithm engine for PostgreSQL configuration optimization.

  Orchestrates the evolution loop: initialization → evaluation → selection → crossover → mutation.
  """

  require Logger

  alias PgGaConf.GA.{Population, Selection, Evolution, Fitness}

  @default_population_size 20
  @default_generations 30
  @default_elitism_count 2
  @default_early_stop_generations 10

  @doc """
  Run genetic algorithm evolution.

  ## Options

    - `:strategy` - Strategy module (required)
    - `:population_size` - Number of individuals (default: #{@default_population_size})
    - `:generations` - Number of generations to evolve (default: #{@default_generations})
    - `:elitism_count` - Number of best individuals to preserve (default: #{@default_elitism_count})
    - `:early_stop_generations` - Stop if no improvement for N generations (default: #{@default_early_stop_generations})
    - `:fitness_evaluator` - Function (chromosome -> metrics) for fitness evaluation (required)

  ## Returns

  `{:ok, %{best_chromosome, best_fitness, generation, history}}` on success.
  """
  @spec evolve(keyword()) :: {:ok, map()} | {:error, term()}
  def evolve(opts) do
    strategy = Keyword.fetch!(opts, :strategy)
    fitness_evaluator = Keyword.fetch!(opts, :fitness_evaluator)

    population_size = Keyword.get(opts, :population_size, @default_population_size)
    max_generations = Keyword.get(opts, :generations, @default_generations)
    elitism_count = Keyword.get(opts, :elitism_count, @default_elitism_count)
    early_stop_gens = Keyword.get(opts, :early_stop_generations, @default_early_stop_generations)

    Logger.info("Starting GA evolution: #{max_generations} generations, population #{population_size}")

    # Initialize population
    initial_population = Population.initialize(population_size, strategy)

    # Evolution parameters
    params = %{
      bounds: strategy.parameter_bounds(),
      mutation_rate: strategy.mutation_rate(),
      crossover_strategy: strategy.crossover_strategy(),
      elitism_count: elitism_count
    }

    # Evaluate initial population
    population = evaluate_population(initial_population, fitness_evaluator)

    # Evolution loop
    result =
      evolution_loop(population, params, fitness_evaluator, %{
        generation: 1,
        max_generations: max_generations,
        early_stop_generations: early_stop_gens,
        history: [],
        no_improvement_count: 0,
        best_fitness_ever: 0.0
      })

    {:ok, result}
  end

  @doc """
  Evolve a single generation from current population.

  Creates next generation through selection, crossover, mutation, and elitism.
  """
  @spec evolve_generation(Population.t(), map()) :: Population.t()
  def evolve_generation(population, params) do
    elitism_count = Map.get(params, :elitism_count, @default_elitism_count)
    population_size = length(population)

    # Sort by fitness to identify elite individuals
    sorted_population = Population.sort_by_fitness(population)

    # Preserve elite individuals
    elite = Enum.take(sorted_population, elitism_count)

    # Generate offspring for remaining slots
    offspring_count = population_size - elitism_count

    offspring =
      for _ <- 1..div(offspring_count, 2) do
        # Select two parents
        parent1 = Selection.tournament(population)
        parent2 = Selection.tournament(population)

        # Crossover
        {child1_chromosome, child2_chromosome} =
          Evolution.crossover(
            parent1.chromosome,
            parent2.chromosome,
            params.crossover_strategy
          )

        # Mutate
        mutated1 = Evolution.mutate(child1_chromosome, params.mutation_rate, params.bounds)
        mutated2 = Evolution.mutate(child2_chromosome, params.mutation_rate, params.bounds)

        [
          %{chromosome: mutated1, fitness: nil},
          %{chromosome: mutated2, fitness: nil}
        ]
      end
      |> List.flatten()
      |> Enum.take(offspring_count)

    # Combine elite and offspring
    elite ++ offspring
  end

  # Private functions

  defp evolution_loop(population, params, evaluator, state) do
    %{
      generation: gen,
      max_generations: max_gen,
      early_stop_generations: early_stop,
      history: history,
      no_improvement_count: no_improve,
      best_fitness_ever: best_ever
    } = state

    # Get generation statistics
    best = Population.best_individual(population)
    avg_fitness = Population.average_fitness(population)

    gen_stats = %{
      generation: gen,
      best_fitness: best.fitness,
      avg_fitness: avg_fitness,
      best_chromosome: best.chromosome
    }

    Logger.info(
      "Generation #{gen}: best=#{Float.round(best.fitness, 2)}, avg=#{Float.round(avg_fitness, 2)}"
    )

    history = [gen_stats | history]

    # Check stopping conditions
    cond do
      # Reached max generations
      gen >= max_gen ->
        Logger.info("Evolution complete: reached max generations (#{max_gen})")

        %{
          best_chromosome: best.chromosome,
          best_fitness: best.fitness,
          generation: gen,
          history: Enum.reverse(history)
        }

      # Early stopping: no improvement
      no_improve >= early_stop ->
        Logger.info(
          "Evolution stopped early: no improvement for #{early_stop} generations at generation #{gen}"
        )

        %{
          best_chromosome: best.chromosome,
          best_fitness: best.fitness,
          generation: gen,
          history: Enum.reverse(history)
        }

      # Continue evolution
      true ->
        # Check if we improved
        {new_best_ever, new_no_improve} =
          if best.fitness > best_ever do
            {best.fitness, 0}
          else
            {best_ever, no_improve + 1}
          end

        # Create next generation
        next_population = evolve_generation(population, params)

        # Evaluate fitness for new individuals
        evaluated_population = evaluate_population(next_population, evaluator)

        # Recurse
        evolution_loop(evaluated_population, params, evaluator, %{
          state
          | generation: gen + 1,
            history: history,
            no_improvement_count: new_no_improve,
            best_fitness_ever: new_best_ever
        })
    end
  end

  defp evaluate_population(population, evaluator) do
    Enum.map(population, fn individual ->
      if individual.fitness == nil do
        # Evaluate fitness
        metrics = evaluator.(individual.chromosome)
        fitness = Fitness.calculate(individual.chromosome, metrics)
        %{individual | fitness: fitness}
      else
        # Already evaluated (elite individuals)
        individual
      end
    end)
  end
end
