defmodule PgGaConf.Julia do
  @moduledoc """
  Resilient Julia client for Sobol sensitivity analysis.

  Supports two modes:
  - :local - Uses erlexec to manage Julia process (development)
  - :tcp - Connects to Julia server via TCP (production/K8s)
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 1_000
  @max_reconnect_delay_ms 30_000
  @request_timeout_ms 300_000
  @health_check_interval_ms 30_000

  defstruct [
    :backend,
    :backend_pid,
    :mode,
    :config,
    :reconnect_attempts,
    :pending_requests,
    :request_counter
  ]

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate Sobol samples for sensitivity analysis.

  Returns {:ok, %{samples: [...], cache_id: id}} or {:error, reason}
  """
  def sobol_sample(knobs, n_samples \\ 128) do
    encoded_knobs = encode_knobs(knobs)
    request("sobol_sample", %{knobs: encoded_knobs, n: n_samples})
  end

  @doc """
  Generate Sobol samples with matrices for computing sensitivity indices.

  Returns {:ok, %{"samples" => [[...], ...], "matrices" => %{...}}} or {:error, reason}
  """
  def generate_sobol_samples(knobs, n_samples \\ 128) do
    encoded_knobs = encode_knobs(knobs)
    request("generate_sobol", %{knobs: encoded_knobs, n: n_samples})
  end

  @doc """
  Compute sensitivity indices from benchmark results using Saltelli method.

  Returns {:ok, %{"knob_name" => %{"S1" => ..., "ST" => ...}, ...}} or {:error, reason}
  """
  def compute_sensitivity(results, matrices, knobs) do
    encoded_knobs = encode_knobs(knobs)

    request("compute_sensitivity", %{
      results: results,
      matrices: matrices,
      knobs: encoded_knobs
    })
  end

  @doc """
  Compute sensitivity indices from benchmark results.

  Returns {:ok, %{ranking: [...], top_knobs: [...]}} or {:error, reason}
  """
  def analyze(results, cache_id, opts \\ []) do
    top_n = Keyword.get(opts, :top_n, 12)
    request("analyze", %{results: results, cache_id: cache_id, top_n: top_n})
  end

  @doc """
  Check if Julia service is healthy.
  """
  def healthy? do
    case request("ping", %{}, timeout: 5_000) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Wait until Julia service is ready, with retries.

  ## Options
    * `:max_attempts` - Maximum number of attempts (default: 30)
    * `:delay_ms` - Delay between attempts in ms (default: 1000)

  Returns `:ok` when ready, `{:error, :timeout}` if not ready after max attempts.
  """
  def wait_until_ready(opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 30)
    delay_ms = Keyword.get(opts, :delay_ms, 1_000)

    do_wait_until_ready(max_attempts, delay_ms)
  end

  defp do_wait_until_ready(0, _delay_ms) do
    {:error, :timeout}
  end

  defp do_wait_until_ready(attempts_left, delay_ms) do
    if healthy?() do
      :ok
    else
      Process.sleep(delay_ms)
      do_wait_until_ready(attempts_left - 1, delay_ms)
    end
  end

  @doc """
  Send a request to Julia service.
  """
  def request(type, payload, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @request_timeout_ms)
    GenServer.call(__MODULE__, {:request, type, payload}, timeout + 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    mode = opts[:mode] || detect_mode()
    config = build_config(mode, opts)

    state = %__MODULE__{
      mode: mode,
      config: config,
      reconnect_attempts: 0,
      pending_requests: %{},
      request_counter: 0
    }

    send(self(), :connect)
    schedule_health_check()

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case safe_connect(state) do
      {:ok, new_state} ->
        Logger.info("Julia client connected (#{state.mode} mode)")
        {:noreply, %{new_state | reconnect_attempts: 0}}

      {:error, reason} ->
        Logger.warning("Julia connection failed: #{inspect(reason)}")
        new_state = schedule_reconnect(state)
        {:noreply, %{new_state | backend_pid: nil}}
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state =
      cond do
        # Skip health check if there are pending requests (Julia is busy working)
        map_size(state.pending_requests) > 0 ->
          Logger.debug("Julia health check skipped - #{map_size(state.pending_requests)} pending requests")
          state

        # No backend connected, nothing to check
        is_nil(state.backend_pid) ->
          state

        # Backend connected and no pending requests, check health
        !backend_healthy?(state) ->
          Logger.warning("Julia health check failed, reconnecting")
          safe_disconnect(state)
          send(self(), :connect)
          %{state | backend_pid: nil}

        # Healthy
        true ->
          state
      end

    schedule_health_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:backend_down, reason}, state) do
    Logger.warning("Julia backend down: #{inspect(reason)}")

    # Fail pending requests
    Enum.each(state.pending_requests, fn {_id, from} ->
      GenServer.reply(from, {:error, :backend_down})
    end)

    new_state = schedule_reconnect(state)
    {:noreply, %{new_state | backend_pid: nil, pending_requests: %{}}}
  end

  @impl true
  def handle_info({:response, id, result}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        Logger.warning("Received response for unknown request #{id}")
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  @impl true
  def handle_call({:request, type, payload}, from, state) do
    if state.backend_pid do
      id = state.request_counter + 1
      request = %{id: id, type: type, payload: payload}

      case send_to_backend(state, request) do
        :ok ->
          pending = Map.put(state.pending_requests, id, from)
          {:noreply, %{state | pending_requests: pending, request_counter: id}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  # Private functions

  defp detect_mode do
    case Application.get_env(:pg_ga_conf, :julia_mode, :auto) do
      :auto ->
        if System.get_env("JULIA_SERVICE_HOST"), do: :tcp, else: :local

      mode ->
        mode
    end
  end

  defp build_config(:local, opts) do
    %{
      julia_executable: opts[:julia_executable] || System.find_executable("julia") || "julia",
      project_path: opts[:project_path] || Path.join(:code.priv_dir(:pg_ga_conf), "julia"),
      script: opts[:script] || "server.jl"
    }
  end

  defp build_config(:tcp, opts) do
    %{
      host: opts[:host] || Application.get_env(:pg_ga_conf, :julia_host, "localhost"),
      port: opts[:port] || Application.get_env(:pg_ga_conf, :julia_port, 9999)
    }
  end

  defp build_config(:mock, _opts) do
    %{}
  end

  defp safe_connect(state) do
    try do
      do_connect(state)
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, inspect(reason)}
    end
  end

  defp do_connect(%{mode: :local} = state) do
    {:ok, pid} =
      PgGaConf.Julia.LocalBackend.start_link(
        julia: state.config.julia_executable,
        project: state.config.project_path,
        script: state.config.script,
        owner: self()
      )

    {:ok, %{state | backend_pid: pid, backend: PgGaConf.Julia.LocalBackend}}
  end

  defp do_connect(%{mode: :tcp} = state) do
    {:ok, pid} =
      PgGaConf.Julia.TcpBackend.start_link(
        host: state.config.host,
        port: state.config.port,
        owner: self()
      )

    {:ok, %{state | backend_pid: pid, backend: PgGaConf.Julia.TcpBackend}}
  end

  defp do_connect(%{mode: :mock} = state) do
    {:ok, pid} = PgGaConf.Julia.MockBackend.start_link(owner: self())
    {:ok, %{state | backend_pid: pid, backend: PgGaConf.Julia.MockBackend}}
  end

  defp safe_disconnect(%{backend_pid: nil}), do: :ok

  defp safe_disconnect(%{backend_pid: pid}) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end
  end

  defp send_to_backend(%{backend: backend, backend_pid: pid}, request) do
    backend.send_request(pid, request)
  end

  defp backend_healthy?(%{backend: backend, backend_pid: pid}) do
    backend.healthy?(pid)
  end

  defp schedule_reconnect(state) do
    delay =
      min(
        @reconnect_delay_ms * :math.pow(2, state.reconnect_attempts),
        @max_reconnect_delay_ms
      )
      |> round()

    Logger.info("Scheduling Julia reconnect in #{delay}ms (attempt #{state.reconnect_attempts + 1})")
    Process.send_after(self(), :reconnect, delay)

    %{state | reconnect_attempts: state.reconnect_attempts + 1}
  end

  defp schedule_health_check do
    interval = Application.get_env(:pg_ga_conf, :julia_health_check_interval, @health_check_interval_ms)
    Process.send_after(self(), :health_check, interval)
  end

  defp encode_knobs(knobs) when is_map(knobs) do
    Map.new(knobs, fn {name, def} ->
      {to_string(name), encode_knob_def(def)}
    end)
  end

  defp encode_knob_def({:continuous, min, max}), do: [min, max]
  defp encode_knob_def({:integer, min, max}), do: [min, max]
  defp encode_knob_def({:categorical, choices}), do: [0, length(choices) - 1]
  defp encode_knob_def({min, max}), do: [min, max]
  # Handle map format from Sobol.encode_knob_space_for_julia
  defp encode_knob_def(%{"type" => "continuous", "min" => min, "max" => max}), do: [min, max]
  defp encode_knob_def(%{"type" => "integer", "min" => min, "max" => max}), do: [min, max]
  defp encode_knob_def(%{"min" => min, "max" => max}), do: [min, max]
end
