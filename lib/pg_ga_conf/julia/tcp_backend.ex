defmodule PgGaConf.Julia.TcpBackend do
  @moduledoc """
  TCP backend for Julia connectivity in production/K8s.
  Communicates via JSON over TCP socket.
  """

  use GenServer
  require Logger

  defstruct [:socket, :owner, :buffer]

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
    host = to_charlist(opts[:host])
    port = opts[:port]

    tcp_opts = [:binary, packet: :line, active: true]

    case :gen_tcp.connect(host, port, tcp_opts, 10_000) do
      {:ok, socket} ->
        Logger.debug("Connected to Julia server at #{opts[:host]}:#{port}")
        {:ok, %__MODULE__{socket: socket, owner: owner, buffer: ""}}

      {:error, reason} ->
        Logger.error("Failed to connect to Julia server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, request}, _from, state) do
    json = Jason.encode!(request) <> "\n"

    case :gen_tcp.send(state.socket, json) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:healthy?, _from, state) do
    case :inet.peername(state.socket) do
      {:ok, _} -> {:reply, true, state}
      {:error, _} -> {:reply, false, state}
    end
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    case Jason.decode(data) do
      {:ok, %{"id" => id} = response} ->
        result = parse_response(response)
        send(state.owner, {:response, id, result})

      {:error, _} ->
        Logger.warning("Invalid JSON from Julia: #{String.slice(data, 0, 100)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("Julia TCP connection closed")
    send(state.owner, {:backend_down, :tcp_closed})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("Julia TCP error: #{inspect(reason)}")
    send(state.owner, {:backend_down, reason})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  defp parse_response(%{"type" => "error", "message" => msg}), do: {:error, msg}
  defp parse_response(%{"data" => data}), do: {:ok, data}
  defp parse_response(other), do: {:ok, other}
end
