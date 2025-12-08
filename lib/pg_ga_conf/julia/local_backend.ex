defmodule PgGaConf.Julia.LocalBackend do
  @moduledoc """
  Local Julia backend using erlexec for process management.
  Communicates via JSON over stdin/stdout.
  """

  use GenServer
  require Logger

  defstruct [:port, :os_pid, :owner, :buffer]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_request(pid, request) do
    GenServer.call(pid, {:send, request})
  end

  def healthy?(pid) do
    GenServer.call(pid, :healthy?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(opts) do
    owner = opts[:owner]
    julia = opts[:julia]
    project = opts[:project]
    script = opts[:script]

    # Build command
    cmd = ~c"#{julia} --project=#{project} #{Path.join(project, script)}"

    exec_opts = [
      :stdin,
      :stdout,
      :stderr,
      :monitor,
      {:cd, project}
    ]

    case :exec.run(cmd, exec_opts) do
      {:ok, pid, os_pid} ->
        Logger.debug("Julia process started with OS PID #{os_pid}")
        {:ok, %__MODULE__{port: pid, os_pid: os_pid, owner: owner, buffer: ""}}

      {:error, reason} ->
        Logger.error("Failed to start Julia: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, request}, _from, state) do
    json = Jason.encode!(request) <> "\n"

    case :exec.send(state.port, json) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:healthy?, _from, state) do
    # Check if the process is running via OS (more reliable than :exec.status)
    case System.cmd("kill", ["-0", to_string(state.os_pid)], stderr_to_stdout: true) do
      {_, 0} -> {:reply, true, state}
      _ -> {:reply, false, state}
    end
  end

  @impl true
  def handle_info({:stdout, _os_pid, data}, state) do
    buffer = state.buffer <> data
    {lines, remaining} = extract_lines(buffer)

    Enum.each(lines, fn line ->
      case Jason.decode(line) do
        {:ok, %{"id" => id} = response} ->
          result = parse_response(response)
          send(state.owner, {:response, id, result})

        {:error, _} ->
          Logger.warning("Invalid JSON from Julia: #{String.slice(line, 0, 100)}")
      end
    end)

    {:noreply, %{state | buffer: remaining}}
  end

  @impl true
  def handle_info({:stderr, _os_pid, data}, state) do
    Logger.debug("Julia stderr: #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _os_pid, :process, _pid, reason}, state) do
    Logger.warning("Julia process exited: #{inspect(reason)}")
    send(state.owner, {:backend_down, reason})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.os_pid do
      :exec.stop(state.os_pid)
    end

    :ok
  end

  defp extract_lines(buffer) do
    case String.split(buffer, "\n") do
      [single] -> {[], single}
      parts ->
        {complete, [remaining]} = Enum.split(parts, -1)
        {complete, remaining}
    end
  end

  defp parse_response(%{"type" => "error", "message" => msg}), do: {:error, msg}
  defp parse_response(%{"data" => data}), do: {:ok, data}
  defp parse_response(other), do: {:ok, other}
end
