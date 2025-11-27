defmodule PgGaConf.Julia.MockBackend do
  @moduledoc """
  Mock Julia backend for testing.
  Returns synthetic Sobol samples and sensitivity results.
  """

  use GenServer
  require Logger

  defstruct [:owner, :samples_cache]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_request(pid, request) do
    GenServer.call(pid, {:send, request})
  end

  def healthy?(_pid), do: true

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{owner: opts[:owner], samples_cache: %{}}}
  end

  @impl true
  def handle_call({:send, request}, _from, state) do
    # Process request and send async response
    Task.start(fn ->
      Process.sleep(10)  # Simulate network delay
      response = process_mock_request(request, state)
      send(state.owner, {:response, request.id, response})
    end)

    {:reply, :ok, state}
  end

  defp process_mock_request(%{type: "ping"}, _state) do
    {:ok, %{"status" => "ok"}}
  end

  defp process_mock_request(%{type: "sobol_sample", payload: payload}, _state) do
    knobs = payload.knobs
    n = Map.get(payload, :n, 128)
    n_dims = map_size(knobs)

    # Generate mock samples
    total_samples = n * (n_dims + 2)

    samples =
      for _i <- 1..total_samples do
        Map.new(knobs, fn {name, [min, max]} ->
          {name, min + :rand.uniform() * (max - min)}
        end)
      end

    {:ok, %{
      "samples" => samples,
      "total_samples" => total_samples,
      "cache_id" => :rand.uniform(1_000_000)
    }}
  end

  defp process_mock_request(%{type: "analyze", payload: payload}, _state) do
    # Extract knob names from cache_id context or generate mock ranking
    top_n = Map.get(payload, :top_n, 12)

    # Mock knob ranking (most common important knobs)
    mock_ranking = [
      %{"knob" => "shared_buffers", "total_order" => 0.35, "first_order" => 0.28},
      %{"knob" => "work_mem", "total_order" => 0.22, "first_order" => 0.18},
      %{"knob" => "effective_cache_size", "total_order" => 0.18, "first_order" => 0.15},
      %{"knob" => "random_page_cost", "total_order" => 0.12, "first_order" => 0.10},
      %{"knob" => "checkpoint_completion_target", "total_order" => 0.08, "first_order" => 0.06},
      %{"knob" => "max_wal_size", "total_order" => 0.05, "first_order" => 0.04},
      %{"knob" => "max_parallel_workers_per_gather", "total_order" => 0.04, "first_order" => 0.03},
      %{"knob" => "default_statistics_target", "total_order" => 0.03, "first_order" => 0.02},
      %{"knob" => "autovacuum_vacuum_cost_limit", "total_order" => 0.02, "first_order" => 0.015},
      %{"knob" => "bgwriter_lru_maxpages", "total_order" => 0.015, "first_order" => 0.01},
      %{"knob" => "maintenance_work_mem", "total_order" => 0.01, "first_order" => 0.008},
      %{"knob" => "wal_buffers", "total_order" => 0.008, "first_order" => 0.005}
    ]

    first_order = Map.new(mock_ranking, fn r -> {r["knob"], r["first_order"]} end)
    total_order = Map.new(mock_ranking, fn r -> {r["knob"], r["total_order"]} end)
    top_knobs = mock_ranking |> Enum.take(top_n) |> Enum.map(& &1["knob"])

    {:ok, %{
      "first_order" => first_order,
      "total_order" => total_order,
      "ranking" => mock_ranking,
      "top_knobs" => top_knobs,
      "variance" => 125.5
    }}
  end

  defp process_mock_request(%{type: type}, _state) do
    {:error, "Unknown request type: #{type}"}
  end
end
