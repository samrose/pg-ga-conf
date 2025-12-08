defmodule PgGaConf.Optimizer.TPE do
  @moduledoc """
  Tree-structured Parzen Estimator (TPE) optimizer via Optuna/Pythonx.

  TPE is sample-efficient and works well with small budgets (<30 iterations).
  It models good and bad configurations separately and samples from promising regions.
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
    :n_startup_trials
  ]

  @default_n_startup_trials 5

  @impl true
  def init(knob_space, opts \\ []) do
    n_startup_trials = Keyword.get(opts, :n_startup_trials, @default_n_startup_trials)
    seed = Keyword.get(opts, :seed, 42)

    encoded_space = Utils.encode_knob_space(knob_space)

    python_code = """
import optuna
import pickle

# Suppress Optuna logs
optuna.logging.set_verbosity(optuna.logging.WARNING)

sampler = optuna.samplers.TPESampler(
    n_startup_trials=n_startup,
    multivariate=True,
    seed=seed
)

study = optuna.create_study(
    direction="minimize",
    sampler=sampler
)

# Decode bytes in knob_space for storage
def decode_knob_space(ks):
    result = {}
    for k, v in ks.items():
        key = k.decode() if isinstance(k, bytes) else k
        if isinstance(v, dict):
            result[key] = {(kk.decode() if isinstance(kk, bytes) else kk): (vv.decode() if isinstance(vv, bytes) else vv) for kk, vv in v.items()}
        else:
            result[key] = v
    return result

study.set_user_attr("knob_space", decode_knob_space(knob_space))

pickle.dumps(study)
"""

    case Pythonx.eval(python_code, %{
           "n_startup" => n_startup_trials,
           "seed" => seed,
           "knob_space" => encoded_space
         }) do
      {result, _globals} ->
        study_bytes = Pythonx.decode(result)

        state = %__MODULE__{
          study_bytes: study_bytes,
          knob_space: knob_space,
          knob_defs: knob_space,
          iteration: 0,
          best_config: nil,
          best_score: nil,
          n_startup_trials: n_startup_trials
        }

        {:ok, state}

      error ->
        {:error, {:pythonx_error, error}}
    end
  end

  @impl true
  def suggest(%__MODULE__{} = state) do
    encoded_space = Utils.encode_knob_space(state.knob_space)

    python_code = """
import pickle
import optuna

study = pickle.loads(study_bytes)
trial = study.ask()

# Helper to get value from dict with bytes or string keys
def get_val(d, key):
    return d.get(key) or d.get(key.encode())

config = {}
for name, spec in knob_space.items():
    name_str = name.decode() if isinstance(name, bytes) else name
    spec_type = get_val(spec, "type")
    if isinstance(spec_type, bytes):
        spec_type = spec_type.decode()

    if spec_type == "float":
        config[name_str] = trial.suggest_float(name_str, get_val(spec, "low"), get_val(spec, "high"))
    elif spec_type == "int":
        config[name_str] = trial.suggest_int(name_str, int(get_val(spec, "low")), int(get_val(spec, "high")))
    elif spec_type == "categorical":
        choices = get_val(spec, "choices")
        choices = [c.decode() if isinstance(c, bytes) else c for c in choices]
        config[name_str] = trial.suggest_categorical(name_str, choices)

new_bytes = pickle.dumps(study)
(config, new_bytes)
"""

    case Pythonx.eval(python_code, %{
           "study_bytes" => state.study_bytes,
           "knob_space" => encoded_space
         }) do
      {result, _globals} ->
        {config, new_bytes} = Pythonx.decode(result)
        decoded_config = Utils.decode_config(config)
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

    # Convert observations to Python format
    encoded_obs =
      Enum.map(prior_observations, fn {config, score} ->
        {Utils.encode_config(config), score}
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
        elif spec_type == "categorical":
            choices = get_val(spec, "choices")
            choices = [c.decode() if isinstance(c, bytes) else c for c in choices]
            distributions[name_str] = optuna.distributions.CategoricalDistribution(choices)

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
