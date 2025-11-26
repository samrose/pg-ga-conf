defmodule PgGaConf.GA.Selection do
  @moduledoc """
  Selection operators for the genetic algorithm.

  Implements tournament selection for choosing parents from the population.
  """

  alias PgGaConf.GA.Population

  @default_tournament_size 3

  @doc """
  Perform tournament selection on the population.

  Randomly selects `tournament_size` individuals and returns the best one.

  ## Options

    - tournament_size: Number of individuals to compete (default: 3)

  ## Returns

  The individual with the highest fitness from the tournament.
  """
  @spec tournament(Population.t(), keyword()) :: Population.individual()
  def tournament(population, opts \\ []) do
    tournament_size = Keyword.get(opts, :tournament_size, @default_tournament_size)

    # Ensure tournament size is at least 1
    tournament_size = max(1, tournament_size)

    # Randomly select tournament_size individuals
    tournament =
      population
      |> Enum.take_random(min(tournament_size, length(population)))

    # Return the best individual from the tournament
    tournament
    |> Population.sort_by_fitness()
    |> List.first()
  end

  @doc """
  Select multiple parents using tournament selection.

  ## Parameters

    - population: The population to select from
    - count: Number of parents to select
    - opts: Options passed to tournament/2

  ## Returns

  A list of `count` individuals selected via tournament selection.
  """
  @spec select_parents(Population.t(), pos_integer(), keyword()) :: [Population.individual()]
  def select_parents(population, count, opts \\ []) do
    for _ <- 1..count do
      tournament(population, opts)
    end
  end
end
