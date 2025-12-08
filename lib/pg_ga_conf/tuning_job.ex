defmodule PgGaConf.TuningJob do
  @moduledoc """
  GenServer for managing a single tuning job with checkpointing and crash recovery.

  Each tuning job runs an optimizer (GA, TPE, or CMA-ES) to find optimal PostgreSQL
  configuration for a given workload. Progress is checkpointed after each iteration
  to enable recovery from crashes.

  ## Features

  - Automatic checkpointing after each iteration
  - Crash recovery from last checkpoint
  - Warm-start from prior observations (transfer learning)
  - Concurrent benchmark execution with backpressure
  - Progress telemetry events

  ## Usage

  ```elixir
  {:ok, job} = PgGaConf.TuningJob.start_link(
    db_id: "my-db",
    db_url: "postgres://...",
    optimizer: :tpe,
    max_iterations: 30
  )

  # Job runs automatically, or control manually:
  PgGaConf.TuningJob.pause(job)
  PgGaConf.TuningJob.resume(job)

  # Get current status
  {:ok, status} = PgGaConf.TuningJob.status(job)
  ```
  """

  use GenServer
  require Logger

  alias PgGaConf.{Optimizer, Benchmark, KnobSpace, Fingerprint, Sobol, ResultStore}
  alias PgGaConf.Schema.Session

  @checkpoint_interval_ms 1_000
  @max_consecutive_errors 5

  defstruct [
    :db_id,
    :db_url,
    :session_id,
    :optimizer_mod,
    :optimizer_state,
    :benchmark_mod,
    :benchmark_state,
    :knob_space,
    :fingerprint,
    :workload_type,
    :max_iterations,
    :current_iteration,
    :status,
    :best_config,
    :best_score,
    :initial_score,
    :history,
    :consecutive_errors,
    :last_error,
    :repo
  ]

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start a tuning job with the given options.

  ## Options

  - `:db_id` - Unique identifier for the database (required)
  - `:db_url` - PostgreSQL connection URL (required)
  - `:optimizer` - Optimizer type: :ga, :tpe, or :cma_es (default: auto-selected)
  - `:benchmark` - Benchmark type: :pgbench or :custom (default: :pgbench)
  - `:max_iterations` - Maximum optimization iterations (default: 30)
  - `:knob_space` - Custom knob space (default: auto from workload)
  - `:warm_start` - Warm-start from prior observations (default: true)
  - `:use_sobol` - Run Sobol analysis for knob selection (default: false)
  - `:repo` - Ecto repo for persistence (default: PgGaConf.Repo)
  """
  def start(opts) do
    DynamicSupervisor.start_child(
      PgGaConf.TuningJobSupervisor,
      {__MODULE__, opts}
    )
  end

  @doc """
  Pause the tuning job.
  """
  def pause(pid) do
    GenServer.call(pid, :pause)
  end

  @doc """
  Resume a paused tuning job.
  """
  def resume(pid) do
    GenServer.call(pid, :resume)
  end

  @doc """
  Get current job status.
  """
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc """
  Stop the tuning job.
  """
  def stop(pid, reason \\ :normal) do
    GenServer.stop(pid, reason)
  end

  @doc """
  Get the best configuration found so far.
  """
  def best(pid) do
    GenServer.call(pid, :best)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    db_id = Keyword.fetch!(opts, :db_id)
    db_url = Keyword.fetch!(opts, :db_url)
    repo = Keyword.get(opts, :repo, PgGaConf.Repo)

    # Check for existing session to recover
    case ResultStore.get_active_session(db_id, repo: repo) do
      {:ok, session} ->
        Logger.info("Recovering tuning job for #{db_id} from iteration #{session.current_iteration}")
        recover_from_session(session, db_url, opts)

      :not_found ->
        Logger.info("Starting new tuning job for #{db_id}")
        start_new_job(db_id, db_url, opts)
    end
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("Pausing tuning job for #{state.db_id}")
    new_state = %{state | status: :paused}
    save_checkpoint(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:resume, _from, %{status: :paused} = state) do
    Logger.info("Resuming tuning job for #{state.db_id}")
    new_state = %{state | status: :running}
    send(self(), :iterate)
    {:reply, :ok, new_state}
  end

  def handle_call(:resume, _from, state) do
    {:reply, {:error, :not_paused}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      db_id: state.db_id,
      status: state.status,
      optimizer: state.optimizer_mod,
      current_iteration: state.current_iteration,
      max_iterations: state.max_iterations,
      best_score: state.best_score,
      initial_score: state.initial_score,
      improvement_pct: compute_improvement(state),
      consecutive_errors: state.consecutive_errors,
      last_error: state.last_error
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:best, _from, state) do
    if state.best_config do
      {:reply, {:ok, state.best_config, state.best_score}, state}
    else
      {:reply, {:error, :no_observations}, state}
    end
  end

  @impl true
  def handle_info(:iterate, %{status: :paused} = state) do
    {:noreply, state}
  end

  def handle_info(:iterate, %{status: :completed} = state) do
    {:noreply, state}
  end

  def handle_info(:iterate, %{current_iteration: i, max_iterations: max} = state) when i >= max do
    Logger.info("Tuning job completed for #{state.db_id}: #{i} iterations")
    new_state = %{state | status: :completed}
    save_checkpoint(new_state)
    emit_telemetry(:completed, new_state)
    {:noreply, new_state}
  end

  def handle_info(:iterate, state) do
    case run_iteration(state) do
      {:ok, new_state} ->
        save_checkpoint(new_state)
        emit_telemetry(:iteration, new_state)

        # Schedule next iteration
        send(self(), :iterate)
        {:noreply, new_state}

      {:error, reason, new_state} ->
        handle_iteration_error(reason, new_state)
    end
  end

  def handle_info({:do_checkpoint, checkpoint_state}, current_state) do
    # Only save if state hasn't changed significantly
    if current_state.current_iteration == checkpoint_state.current_iteration do
      do_save_checkpoint(checkpoint_state)
    end

    {:noreply, current_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("Tuning job terminating: #{inspect(reason)}")
    save_checkpoint(%{state | status: :stopped})

    # Clean up benchmark resources
    if state.benchmark_state do
      state.benchmark_mod.cleanup(state.benchmark_state)
    end

    :ok
  end

  # Private functions - Initialization

  defp start_new_job(db_id, db_url, opts) do
    repo = Keyword.get(opts, :repo, PgGaConf.Repo)
    max_iterations = Keyword.get(opts, :max_iterations, 30)
    benchmark_type = Keyword.get(opts, :benchmark, :pgbench)
    use_sobol = Keyword.get(opts, :use_sobol, false)
    warm_start = Keyword.get(opts, :warm_start, true)

    # Initialize benchmark
    benchmark_mod = Benchmark.get_benchmark(benchmark_type)
    benchmark_opts = Keyword.merge(opts, db_url: db_url)

    with {:ok, benchmark_state} <- benchmark_mod.init(benchmark_opts),
         # Get initial baseline score
         {:ok, initial_score, _metrics} <- benchmark_mod.run(benchmark_state),
         # Extract workload fingerprint
         {:ok, fingerprint} <- Fingerprint.extract(repo),
         # Determine knob space
         {:ok, knob_space} <- determine_knob_space(fingerprint, opts, use_sobol, benchmark_mod, benchmark_state),
         # Select optimizer
         optimizer_type <- select_optimizer(knob_space, opts),
         optimizer_mod <- Optimizer.get_optimizer(optimizer_type),
         # Initialize optimizer
         {:ok, optimizer_state} <- optimizer_mod.init(knob_space, opts),
         # Warm-start from prior observations
         {:ok, optimizer_state} <- maybe_warm_start(optimizer_state, optimizer_mod, fingerprint, warm_start, repo),
         # Create session
         {:ok, session} <- create_session(db_id, optimizer_type, knob_space, initial_score, fingerprint, repo) do
      state = %__MODULE__{
        db_id: db_id,
        db_url: db_url,
        session_id: session.id,
        optimizer_mod: optimizer_mod,
        optimizer_state: optimizer_state,
        benchmark_mod: benchmark_mod,
        benchmark_state: benchmark_state,
        knob_space: knob_space,
        fingerprint: fingerprint,
        workload_type: Fingerprint.classify(fingerprint),
        max_iterations: max_iterations,
        current_iteration: 0,
        status: :running,
        best_config: nil,
        best_score: nil,
        initial_score: initial_score,
        history: [],
        consecutive_errors: 0,
        last_error: nil,
        repo: repo
      }

      emit_telemetry(:started, state)
      send(self(), :iterate)

      {:ok, state}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp recover_from_session(session, db_url, opts) do
    repo = Keyword.get(opts, :repo, PgGaConf.Repo)
    benchmark_type = Keyword.get(opts, :benchmark, :pgbench)

    # Re-initialize benchmark
    benchmark_mod = Benchmark.get_benchmark(benchmark_type)
    benchmark_opts = Keyword.merge(opts, db_url: db_url)

    with {:ok, benchmark_state} <- benchmark_mod.init(benchmark_opts),
         # Deserialize optimizer state
         optimizer_type <- String.to_existing_atom(session.optimizer),
         optimizer_mod <- Optimizer.get_optimizer(optimizer_type),
         {:ok, optimizer_state} <- optimizer_mod.deserialize(session.optimizer_state),
         # Reconstruct knob space
         knob_space <- reconstruct_knob_space(session.knobs_used),
         # Deserialize fingerprint
         {:ok, fingerprint} <- Fingerprint.deserialize(session.fingerprint_vector || <<>>) do
      state = %__MODULE__{
        db_id: session.db_id,
        db_url: db_url,
        session_id: session.id,
        optimizer_mod: optimizer_mod,
        optimizer_state: optimizer_state,
        benchmark_mod: benchmark_mod,
        benchmark_state: benchmark_state,
        knob_space: knob_space,
        fingerprint: fingerprint,
        workload_type: String.to_existing_atom(session.workload_cluster || "mixed"),
        max_iterations: session.max_iterations,
        current_iteration: session.current_iteration,
        status: :running,
        best_config: atomize_keys(session.best_config),
        best_score: session.best_score,
        initial_score: session.initial_score,
        history: session.history || [],
        consecutive_errors: session.consecutive_errors || 0,
        last_error: session.last_error,
        repo: repo
      }

      emit_telemetry(:recovered, state)
      send(self(), :iterate)

      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("Failed to recover session: #{inspect(reason)}")
        # Fall back to new job
        start_new_job(session.db_id, db_url, opts)
    end
  end

  defp determine_knob_space(fingerprint, opts, use_sobol, benchmark_mod, benchmark_state) do
    case Keyword.get(opts, :knob_space) do
      nil ->
        if use_sobol do
          # Run Sobol analysis
          full_space = KnobSpace.all_knobs()

          benchmark_fn = fn config ->
            :ok = benchmark_mod.apply_config(benchmark_state, config)
            benchmark_mod.run(benchmark_state)
          end

          case Sobol.analyze(full_space, benchmark_fn, fingerprint: fingerprint) do
            {:ok, indices} ->
              reduced = Sobol.reduce_knob_space(full_space, indices)
              {:ok, reduced}

            {:error, _reason} ->
              # Fall back to workload-based selection
              workload_type = Fingerprint.classify(fingerprint)
              {:ok, Sobol.quick_reduce(workload_type)}
          end
        else
          # Use workload-based knob selection
          workload_type = Fingerprint.classify(fingerprint)
          {:ok, Sobol.quick_reduce(workload_type)}
        end

      custom_space ->
        {:ok, custom_space}
    end
  end

  defp select_optimizer(knob_space, opts) do
    case Keyword.get(opts, :optimizer) do
      nil ->
        budget = Keyword.get(opts, :max_iterations, 30)
        Optimizer.recommend(knob_space, budget: budget)

      type ->
        type
    end
  end

  defp maybe_warm_start(optimizer_state, _optimizer_mod, _fingerprint, false, _repo) do
    {:ok, optimizer_state}
  end

  defp maybe_warm_start(optimizer_state, optimizer_mod, fingerprint, true, repo) do
    case ResultStore.find_similar_observations(fingerprint, repo: repo, limit: 20) do
      {:ok, []} ->
        {:ok, optimizer_state}

      {:ok, observations} ->
        prior_obs = Enum.map(observations, fn obs -> {atomize_keys(obs.config), obs.score} end)

        case optimizer_mod.warm_start(optimizer_state, prior_obs) do
          {:ok, new_state} ->
            Logger.info("Warm-started optimizer with #{length(prior_obs)} prior observations")
            {:ok, new_state}

          {:error, _} ->
            # Warm-start not supported or failed
            {:ok, optimizer_state}
        end

      {:error, _} ->
        {:ok, optimizer_state}
    end
  end

  defp create_session(db_id, optimizer_type, knob_space, initial_score, fingerprint, repo) do
    knob_names = Map.keys(knob_space) |> Enum.map(&Atom.to_string/1)

    attrs = %{
      db_id: db_id,
      optimizer: Atom.to_string(optimizer_type),
      status: "running",
      knobs_used: knob_names,
      initial_score: initial_score,
      workload_cluster: Atom.to_string(Fingerprint.classify(fingerprint)),
      fingerprint_vector: Fingerprint.serialize(fingerprint)
    }

    %Session{}
    |> Session.changeset(attrs)
    |> repo.insert()
  end

  # Private functions - Iteration

  defp run_iteration(state) do
    # Get next config suggestion
    with {:ok, config, new_optimizer_state} <- state.optimizer_mod.suggest(state.optimizer_state),
         # Apply config
         :ok <- state.benchmark_mod.apply_config(state.benchmark_state, config),
         # Run benchmark
         {:ok, score, metrics} <- state.benchmark_mod.run(state.benchmark_state),
         # Tell optimizer the result
         {:ok, final_optimizer_state} <-
           state.optimizer_mod.observe(new_optimizer_state, config, score) do
      # Update best
      {best_config, best_score} =
        if is_nil(state.best_score) or score < state.best_score do
          {config, score}
        else
          {state.best_config, state.best_score}
        end

      # Record history
      history_entry = %{
        iteration: state.current_iteration + 1,
        config: stringify_keys(config),
        score: score,
        metrics: metrics,
        timestamp: DateTime.utc_now()
      }

      # Save observation for transfer learning
      save_observation(state, config, score, metrics)

      new_state = %{
        state
        | optimizer_state: final_optimizer_state,
          current_iteration: state.current_iteration + 1,
          best_config: best_config,
          best_score: best_score,
          history: [history_entry | state.history],
          consecutive_errors: 0,
          last_error: nil
      }

      {:ok, new_state}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_iteration_error(reason, state) do
    Logger.warning("Iteration error for #{state.db_id}: #{inspect(reason)}")

    new_state = %{
      state
      | consecutive_errors: state.consecutive_errors + 1,
        last_error: inspect(reason)
    }

    if new_state.consecutive_errors >= @max_consecutive_errors do
      Logger.error("Max consecutive errors reached for #{state.db_id}, pausing job")
      save_checkpoint(%{new_state | status: :error})
      emit_telemetry(:error, new_state)
      {:noreply, %{new_state | status: :error}}
    else
      # Retry after delay
      Process.send_after(self(), :iterate, 5_000)
      save_checkpoint(new_state)
      {:noreply, new_state}
    end
  end

  # Private functions - Persistence

  defp save_checkpoint(state) do
    Process.send_after(self(), {:do_checkpoint, state}, @checkpoint_interval_ms)
  end

  defp do_save_checkpoint(state) do
    serialized_optimizer = state.optimizer_mod.serialize(state.optimizer_state)

    attrs = %{
      status: Atom.to_string(state.status),
      optimizer_state: serialized_optimizer,
      current_iteration: state.current_iteration,
      best_config: stringify_keys(state.best_config),
      best_score: state.best_score,
      improvement_pct: compute_improvement(state),
      history: state.history,
      last_error: state.last_error,
      error_count: (state.consecutive_errors > 0 && 1) || 0,
      consecutive_errors: state.consecutive_errors
    }

    ResultStore.update_session(state.session_id, attrs, repo: state.repo)
  rescue
    e ->
      Logger.error("Failed to save checkpoint: #{Exception.message(e)}")
  end

  defp save_observation(state, config, score, metrics) do
    attrs = %{
      db_id: state.db_id,
      config: stringify_keys(config),
      score: score,
      metrics: metrics,
      workload_cluster: Atom.to_string(state.workload_type),
      fingerprint_vector: Fingerprint.serialize(state.fingerprint)
    }

    ResultStore.save_observation(attrs, repo: state.repo)
  rescue
    e ->
      Logger.warning("Failed to save observation: #{Exception.message(e)}")
  end

  # Private functions - Utilities

  defp compute_improvement(%{initial_score: nil}), do: nil
  defp compute_improvement(%{best_score: nil}), do: nil

  defp compute_improvement(%{initial_score: initial, best_score: best}) do
    ((initial - best) / initial) * 100
  end

  defp reconstruct_knob_space(knob_names) when is_list(knob_names) do
    all_knobs = KnobSpace.all_knobs()

    knob_names
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.reduce(%{}, fn name, acc ->
      case Map.get(all_knobs, name) do
        nil -> acc
        def -> Map.put(acc, name, def)
      end
    end)
  end

  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, v}
    end)
  rescue
    _ -> map
  end

  defp stringify_keys(nil), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, v}
    end)
  end

  defp emit_telemetry(event, state) do
    :telemetry.execute(
      [:pg_ga_conf, :tuning_job, event],
      %{
        iteration: state.current_iteration,
        best_score: state.best_score,
        improvement_pct: compute_improvement(state)
      },
      %{
        db_id: state.db_id,
        optimizer: state.optimizer_mod,
        status: state.status
      }
    )
  rescue
    _ -> :ok
  end
end
