defmodule PgGaConf.Strategies.Strategy do
  @moduledoc """
  Behaviour for GA optimization strategies.
  """

  alias PgGaConf.Core.ConfigChromosome

  @doc """
  Returns parameter bounds as %{parameter: {min, max}}.
  """
  @callback parameter_bounds() :: %{atom() => {number(), number()}}

  @doc """
  Returns mutation rate (0.0 - 1.0).
  """
  @callback mutation_rate() :: float()

  @doc """
  Returns crossover strategy (:uniform, :single_point, :smart).
  """
  @callback crossover_strategy() :: atom()

  @doc """
  Generates a random configuration within strategy bounds.
  """
  @callback generate_random_config() :: ConfigChromosome.t()
end
