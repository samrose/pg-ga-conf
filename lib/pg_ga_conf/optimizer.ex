defmodule PgGaConf.Optimizer do
  @moduledoc """
  Behaviour for optimization strategies.

  All optimizers (GA, TPE, CMA-ES) implement this interface for:
  - Suggesting configurations to evaluate
  - Learning from benchmark results
  - Serialization for checkpointing
  """

  @type config :: %{atom() => number() | String.t()}
  @type score :: float()
  @type state :: term()
  @type knob_space :: %{atom() => PgGaConf.KnobSpace.knob_def()}

  @doc """
  Initialize optimizer with knob space and options.

  ## Options

  Common options:
  - `:seed` - Random seed for reproducibility

  GA-specific:
  - `:population_size` - Number of individuals (default: 20)
  - `:elitism_count` - Elite individuals to preserve (default: 2)

  TPE-specific:
  - `:n_startup_trials` - Random trials before TPE kicks in (default: 5)

  CMA-ES-specific:
  - `:sigma0` - Initial step size (default: 0.5)
  - `:n_startup_trials` - Random trials before CMA-ES (default: 10)
  """
  @callback init(knob_space(), keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Suggest next configuration to evaluate.
  """
  @callback suggest(state()) :: {:ok, config(), state()} | {:error, term()}

  @doc """
  Report benchmark result (lower score is better).
  """
  @callback observe(state(), config(), score()) :: {:ok, state()}

  @doc """
  Get best configuration found so far.
  """
  @callback best(state()) :: {:ok, config(), score()} | {:error, :no_observations}

  @doc """
  Serialize optimizer state for checkpointing.
  """
  @callback serialize(state()) :: binary()

  @doc """
  Deserialize optimizer state from checkpoint.
  """
  @callback deserialize(binary()) :: {:ok, state()} | {:error, term()}

  @doc """
  Warm-start optimizer with prior observations.
  """
  @callback warm_start(state(), observations :: [{config(), score()}]) :: {:ok, state()}

  @optional_callbacks [warm_start: 2]

  @doc """
  Get the optimizer module for a given type.
  """
  @spec get_optimizer(:ga | :tpe | :cma_es) :: module()
  def get_optimizer(:ga), do: PgGaConf.Optimizer.GA
  def get_optimizer(:tpe), do: PgGaConf.Optimizer.TPE
  def get_optimizer(:cma_es), do: PgGaConf.Optimizer.CmaEs

  @doc """
  Recommend which optimizer to use based on knob space and budget.
  """
  @spec recommend(knob_space :: map(), keyword()) :: :ga | :tpe | :cma_es
  def recommend(knob_space, opts \\ []) do
    budget = Keyword.get(opts, :budget, 30)
    knob_names = Map.keys(knob_space)
    categorical_count = length(PgGaConf.KnobSpace.categorical_knobs(knob_names))
    total_knobs = length(knob_names)
    categorical_ratio = categorical_count / max(total_knobs, 1)

    cond do
      # Low budget - TPE is most sample efficient
      budget < 20 -> :tpe

      # Many categoricals - GA handles them natively
      categorical_ratio > 0.3 -> :ga

      # Continuous parameters, medium+ budget - CMA-ES learns correlations
      categorical_ratio < 0.1 and budget >= 30 -> :cma_es

      # Default to TPE as good general-purpose choice
      true -> :tpe
    end
  end
end
