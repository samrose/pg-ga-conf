defmodule PgGaConf.GA.Population do
  @moduledoc """
  Population management for the genetic algorithm.

  Handles initialization, sorting, and statistics for a population of individuals.
  Each individual is a map with %{chromosome: ConfigChromosome.t(), fitness: float() | nil}.
  """

  alias PgGaConf.Core.ConfigChromosome

  @type individual :: %{
          chromosome: ConfigChromosome.t(),
          fitness: float() | nil
        }

  @type t :: [individual()]

  @doc """
  Initialize a new population of the given size using the strategy.

  ## Parameters

    - size: Number of individuals to generate
    - strategy: A strategy module implementing the Strategy behaviour

  ## Returns

  A list of individuals with nil fitness values.
  """
  @spec initialize(pos_integer(), module()) :: t()
  def initialize(size, strategy) do
    for _ <- 1..size do
      %{
        chromosome: strategy.generate_random_config(),
        fitness: nil
      }
    end
  end

  @doc """
  Sort population by fitness in descending order (best first).

  Individuals with nil fitness are placed at the end.
  """
  @spec sort_by_fitness(t()) :: t()
  def sort_by_fitness(population) do
    Enum.sort_by(
      population,
      fn individual ->
        case individual.fitness do
          nil -> {1, 0}
          fitness -> {0, fitness}
        end
      end,
      fn a, b ->
        case {a, b} do
          {{1, _}, {0, _}} -> false
          {{0, _}, {1, _}} -> true
          {{0, f1}, {0, f2}} -> f1 >= f2
          {{1, _}, {1, _}} -> true
        end
      end
    )
  end

  @doc """
  Get the best individual from the population.

  Returns nil if population is empty.
  """
  @spec best_individual(t()) :: individual() | nil
  def best_individual([]), do: nil

  def best_individual(population) do
    population
    |> sort_by_fitness()
    |> List.first()
  end

  @doc """
  Calculate average fitness of the population.

  Ignores individuals with nil fitness. Returns 0.0 for empty population.
  """
  @spec average_fitness(t()) :: float()
  def average_fitness([]), do: 0.0

  def average_fitness(population) do
    individuals_with_fitness =
      population
      |> Enum.filter(fn individual -> individual.fitness != nil end)

    case individuals_with_fitness do
      [] ->
        0.0

      individuals ->
        total = Enum.sum(Enum.map(individuals, & &1.fitness))
        total / length(individuals)
    end
  end
end
