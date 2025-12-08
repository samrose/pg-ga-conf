defmodule PgGaConf.Optimizer.CmaEs do
  @moduledoc """
  CMA-ES (Covariance Matrix Adaptation Evolution Strategy) optimizer via Optuna/Pythonx.

  CMA-ES learns correlations between parameters during optimization, making it
  effective for PostgreSQL tuning where many knobs are correlated:
  - shared_buffers ↔ effective_cache_size
  - work_mem ↔ max_parallel_workers_per_gather
  - checkpoint_completion_target ↔ max_wal_size

  Categorical parameters are encoded as integers for CMA-ES.
  """

  @behaviour PgGaConf.Optimizer

  alias PgGaConf.Optimizer.Utils

  defstruct [
    :study_bytes,
    :knob_space,
    :knob_defs,
    :iteration,
    :best_config,
    :best_score,
    :sigma0,
    :n_startup_trials
  ]

  @default_sigma0 0.5
  @default_n_startup_trials 10

  @impl true
  def init(knob_space, opts \\ []) do
    sigma0 = Keyword.get(opts, :sigma0, @default_sigma0)
    n_startup_trials = Keyword.get(opts, :n_startup_trials, @default_n_startup_trials)
    restart_strategy = Keyword.get(opts, :restart_strategy, nil)  # deprecated in Optuna 4.4
    seed = Keyword.get(opts, :seed, 42)

    # Convert knob space for CMA-ES (categoricals become integers)
    cma_knob_space = Utils.knob_space_for_cma(knob_space)
    # Use JSON to avoid bytes encoding issues
    knob_space_json = cma_knob_space |> Utils.encode_knob_space() |> Jason.encode!()

    python_code = """
import optuna
import pickle
import json

# Suppress Optuna logs
optuna.logging.set_verbosity(optuna.logging.WARNING)

# Parse knob_space from JSON string to ensure string keys
knob_space_str = knob_space_json.decode() if isinstance(knob_space_json, bytes) else knob_space_json
decoded_knob_space = json.loads(knob_space_str)

# Decode restart_strategy if it's bytes
restart_str = restart_strategy.decode() if isinstance(restart_strategy, bytes) else restart_strategy

sampler = optuna.samplers.CmaEsSampler(
    sigma0=sigma0,
    n_startup_trials=n_startup,
    seed=seed
)

study = optuna.create_study(
    direction="minimize",
    sampler=sampler
)

# Store decoded knob_space as JSON string to avoid bytes issues
study.set_user_attr("knob_space_json", json.dumps(decoded_knob_space))

pickle.dumps(study)
"""

    case Pythonx.eval(python_code, %{
           "sigma0" => sigma0,
           "n_startup" => n_startup_trials,
           "restart_strategy" => restart_strategy,
           "seed" => seed,
           "knob_space_json" => knob_space_json
         }) do
      {result, _globals} ->
        study_bytes = Pythonx.decode(result)

        state = %__MODULE__{
          study_bytes: study_bytes,
          knob_space: cma_knob_space,
          knob_defs: knob_space,
          iteration: 0,
          best_config: nil,
          best_score: nil,
          sigma0: sigma0,
          n_startup_trials: n_startup_trials
        }

        {:ok, state}

      error ->
        {:error, {:pythonx_error, error}}
    end
  end

  @impl true
  def suggest(%__MODULE__{} = state) do
    # Use JSON string to avoid Pythonx bytes encoding issues
    knob_space_json = state.knob_space
      |> Utils.encode_knob_space()
      |> Jason.encode!()

    python_code = """
import pickle
import optuna
import json

study = pickle.loads(study_bytes)

# Parse knob_space from JSON string to ensure string keys
knob_space_str = knob_space_json.decode() if isinstance(knob_space_json, bytes) else knob_space_json
decoded_space = json.loads(knob_space_str)

trial = study.ask()

config = {}
for name, spec in decoded_space.items():
    spec_type = spec.get("type")

    if spec_type == "float":
        config[name] = trial.suggest_float(name, spec["low"], spec["high"])
    elif spec_type == "int":
        config[name] = trial.suggest_int(name, int(spec["low"]), int(spec["high"]))

new_bytes = pickle.dumps(study)
(config, new_bytes)
"""

    case Pythonx.eval(python_code, %{
           "study_bytes" => state.study_bytes,
           "knob_space_json" => knob_space_json
         }) do
      {result, _globals} ->
        {config, new_bytes} = Pythonx.decode(result)
        # Decode config, converting integer-encoded categoricals back
        decoded_config = Utils.decode_config_from_cma(config, state.knob_defs)
        new_state = %{state | study_bytes: new_bytes, iteration: state.iteration + 1}
        {:ok, decoded_config, new_state}

      error ->
        {:error, {:pythonx_error, error}}
    end
  end

  @impl true
  def observe(%__MODULE__{} = state, config, score) do
    python_code = """
import pickle
import optuna

study = pickle.loads(study_bytes)

# Tell the study the result of the last trial
if len(study.trials) > 0:
    last_trial = study.trials[-1]
    if last_trial.state == optuna.trial.TrialState.RUNNING:
        study.tell(last_trial.number, score)

pickle.dumps(study)
"""

    case Pythonx.eval(python_code, %{
           "study_bytes" => state.study_bytes,
           "score" => score
         }) do
      {result, _globals} ->
        new_bytes = Pythonx.decode(result)

        # Update best
        {best_config, best_score} =
          if is_nil(state.best_score) or score < state.best_score do
            {config, score}
          else
            {state.best_config, state.best_score}
          end

        new_state = %{state |
          study_bytes: new_bytes,
          best_config: best_config,
          best_score: best_score
        }

        {:ok, new_state}

      error ->
        {:error, {:pythonx_error, error}}
    end
  end

  @impl true
  def best(%__MODULE__{best_config: nil}), do: {:error, :no_observations}

  def best(%__MODULE__{} = state) do
    {:ok, state.best_config, state.best_score}
  end

  @impl true
  def warm_start(%__MODULE__{} = state, prior_observations) do
    encoded_space = Utils.encode_knob_space(state.knob_space)

    # Convert observations to CMA-ES format (encode categoricals)
    encoded_obs =
      Enum.map(prior_observations, fn {config, score} ->
        encoded_config =
          config
          |> Utils.encode_config_for_cma(Map.keys(state.knob_defs))
          |> Utils.encode_config()

        {encoded_config, score}
      end)

    python_code = """
import pickle
import optuna

# Helper to get value from dict with bytes or string keys
def get_val(d, key):
    return d.get(key) or d.get(key.encode())

def decode_key(k):
    return k.decode() if isinstance(k, bytes) else k

study = pickle.loads(study_bytes)

for config, score in observations:
    # Decode config keys
    decoded_config = {decode_key(k): v for k, v in config.items()}

    # Create distributions for this trial
    distributions = {}
    for name, spec in knob_space.items():
        name_str = decode_key(name)
        spec_type = get_val(spec, "type")
        if isinstance(spec_type, bytes):
            spec_type = spec_type.decode()

        if spec_type == "float":
            distributions[name_str] = optuna.distributions.FloatDistribution(get_val(spec, "low"), get_val(spec, "high"))
        elif spec_type == "int":
            distributions[name_str] = optuna.distributions.IntDistribution(int(get_val(spec, "low")), int(get_val(spec, "high")))

    # Create and add completed trial
    trial = optuna.trial.create_trial(
        params=decoded_config,
        distributions=distributions,
        values=[score]
    )
    study.add_trial(trial)

pickle.dumps(study)
"""

    case Pythonx.eval(python_code, %{
           "study_bytes" => state.study_bytes,
           "observations" => encoded_obs,
           "knob_space" => encoded_space
         }) do
      {result, _globals} ->
        new_bytes = Pythonx.decode(result)

        # Find best from prior observations
        {best_config, best_score} =
          prior_observations
          |> Enum.min_by(fn {_, score} -> score end, fn -> {nil, nil} end)

        # Merge with existing best
        {best_config, best_score} =
          cond do
            is_nil(state.best_score) -> {best_config, best_score}
            is_nil(best_score) -> {state.best_config, state.best_score}
            best_score < state.best_score -> {best_config, best_score}
            true -> {state.best_config, state.best_score}
          end

        new_state = %{state |
          study_bytes: new_bytes,
          best_config: best_config,
          best_score: best_score
        }

        {:ok, new_state}

      error ->
        {:error, {:pythonx_error, error}}
    end
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
end
