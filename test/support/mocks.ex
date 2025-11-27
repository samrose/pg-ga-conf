defmodule PgGaConf.Test.Mocks do
  @moduledoc """
  Mock modules for testing without external dependencies.
  """

  defmodule MockRepo do
    @moduledoc "Mock Ecto repo that stores data in process dictionary"

    def start_link(_opts \\ []), do: {:ok, self()}

    def insert(changeset) do
      data = Ecto.Changeset.apply_changes(changeset)
      id = System.unique_integer([:positive])
      data = Map.put(data, :id, id)
      store_record(data.__struct__, id, data)
      {:ok, data}
    end

    def insert!(changeset) do
      {:ok, result} = insert(changeset)
      result
    end

    def update(changeset) do
      data = Ecto.Changeset.apply_changes(changeset)
      store_record(data.__struct__, data.id, data)
      {:ok, data}
    end

    def get(schema, id) do
      get_record(schema, id)
    end

    def one(query) do
      # Simplified - just return first matching record
      schema = query.from.source |> elem(1)
      get_all_records(schema) |> List.first()
    end

    def all(query) do
      schema = query.from.source |> elem(1)
      get_all_records(schema)
    end

    def query(_sql, _params \\ []) do
      # Return empty result by default - tests can override
      {:ok, %{rows: [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]], columns: default_columns()}}
    end

    defp default_columns do
      ~w(xact_commit xact_rollback blks_read blks_hit tup_returned tup_fetched
         tup_inserted tup_updated tup_deleted conflicts temp_files temp_bytes
         deadlocks blk_read_time blk_write_time)
    end

    defp store_record(schema, id, data) do
      key = {__MODULE__, schema}
      records = Process.get(key, %{})
      Process.put(key, Map.put(records, id, data))
    end

    defp get_record(schema, id) do
      key = {__MODULE__, schema}
      records = Process.get(key, %{})
      Map.get(records, id)
    end

    defp get_all_records(schema) do
      key = {__MODULE__, schema}
      records = Process.get(key, %{})
      Map.values(records)
    end

    def clear_all do
      Process.get_keys()
      |> Enum.filter(fn
        {__MODULE__, _} -> true
        _ -> false
      end)
      |> Enum.each(&Process.delete/1)
    end
  end

  defmodule MockJulia do
    @moduledoc "Mock Julia client for testing Sobol analysis"

    def start_link(_opts \\ []), do: {:ok, self()}

    def generate_sobol_samples(knobs, n_samples) do
      # Generate fake samples
      knob_names = Map.keys(knobs)
      num_knobs = length(knob_names)

      # Create n_samples * (2 * num_knobs + 2) samples for Saltelli method
      total_samples = n_samples * (2 * num_knobs + 2)

      samples = for _ <- 1..total_samples do
        for {_name, spec} <- knobs do
          case spec do
            %{"type" => "float", "low" => low, "high" => high} ->
              low + :rand.uniform() * (high - low)
            %{"type" => "int", "low" => low, "high" => high} ->
              low + :rand.uniform(high - low + 1) - 1
            _ ->
              :rand.uniform()
          end
        end
      end

      {:ok, %{
        "samples" => samples,
        "matrices" => %{
          "A" => Enum.take(samples, n_samples),
          "B" => Enum.slice(samples, n_samples, n_samples)
        }
      }}
    end

    def compute_sensitivity(_results, _matrices, knobs) do
      # Return fake sensitivity indices
      indices = knobs
      |> Map.keys()
      |> Enum.with_index()
      |> Enum.map(fn {name, idx} ->
        # First few knobs are "important"
        s1 = if idx < 3, do: 0.2 - idx * 0.05, else: 0.01
        st = s1 + 0.05
        {name, %{"S1" => s1, "ST" => st}}
      end)
      |> Map.new()

      {:ok, indices}
    end

    def healthy?, do: true
  end

  defmodule MockBenchmark do
    @moduledoc "Mock benchmark for testing without PostgreSQL"

    defstruct [:scores, :current_index, :applied_configs]

    def init(opts \\ []) do
      scores = Keyword.get(opts, :scores, [1.0, 0.9, 0.8, 0.7, 0.6])
      {:ok, %__MODULE__{scores: scores, current_index: 0, applied_configs: []}}
    end

    def run(%__MODULE__{} = state) do
      score = Enum.at(state.scores, state.current_index, List.last(state.scores))
      new_state = %{state | current_index: state.current_index + 1}
      {:ok, score, %{tps: 1.0 / score, latency_avg: score * 10}, new_state}
    end

    def apply_config(%__MODULE__{} = state, config) do
      new_state = %{state | applied_configs: [config | state.applied_configs]}
      {:ok, new_state}
    end

    def cleanup(_state), do: :ok
  end

  defmodule MockPythonx do
    @moduledoc "Mock for Pythonx.eval calls"

    def eval(_code, bindings) do
      # Return a mock pickled study
      study_bytes = :erlang.term_to_binary(%{mock: true, bindings: bindings})
      {study_bytes, %{}}
    end
  end
end
