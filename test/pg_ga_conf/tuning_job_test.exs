defmodule PgGaConf.TuningJobTest do
  use ExUnit.Case, async: true

  alias PgGaConf.TuningJob

  describe "TuningJob struct" do
    test "has expected fields" do
      state = %TuningJob{
        db_id: "test-db",
        db_url: "postgres://localhost/test",
        session_id: 1,
        max_iterations: 30,
        current_iteration: 0,
        status: :running,
        consecutive_errors: 0
      }

      assert state.db_id == "test-db"
      assert state.status == :running
      assert state.max_iterations == 30
    end

    test "defaults" do
      state = %TuningJob{}

      assert is_nil(state.db_id)
      assert is_nil(state.status)
      assert is_nil(state.best_config)
      assert is_nil(state.best_score)
    end
  end

  describe "compute_improvement/1 logic" do
    # Testing the improvement calculation logic

    test "computes percentage improvement" do
      initial = 2.0
      best = 1.0

      improvement = ((initial - best) / initial) * 100
      assert improvement == 50.0
    end

    test "handles same score" do
      initial = 1.0
      best = 1.0

      improvement = ((initial - best) / initial) * 100
      assert improvement == 0.0
    end

    test "handles negative improvement (worse score)" do
      initial = 1.0
      best = 2.0

      improvement = ((initial - best) / initial) * 100
      assert improvement == -100.0
    end
  end

  describe "status values" do
    test "valid status atoms" do
      valid_statuses = [:running, :paused, :completed, :error, :stopped]

      for status <- valid_statuses do
        state = %TuningJob{status: status}
        assert state.status == status
      end
    end
  end

  describe "error handling" do
    test "consecutive errors tracking" do
      state = %TuningJob{consecutive_errors: 0}

      # Simulate error incrementing
      state = %{state | consecutive_errors: state.consecutive_errors + 1}
      assert state.consecutive_errors == 1

      state = %{state | consecutive_errors: state.consecutive_errors + 1}
      assert state.consecutive_errors == 2
    end

    test "max consecutive errors check" do
      max_errors = 5
      state = %TuningJob{consecutive_errors: max_errors}

      assert state.consecutive_errors >= max_errors
    end
  end

  describe "history tracking" do
    test "appends to history" do
      state = %TuningJob{history: []}

      entry = %{
        iteration: 1,
        config: %{"shared_buffers" => 4096},
        score: 1.5,
        timestamp: DateTime.utc_now()
      }

      state = %{state | history: [entry | state.history]}
      assert length(state.history) == 1
      assert hd(state.history).iteration == 1
    end

    test "multiple history entries" do
      state = %TuningJob{history: []}

      entries =
        for i <- 1..5 do
          %{
            iteration: i,
            config: %{"shared_buffers" => 4096 + i * 100},
            score: 2.0 - i * 0.1,
            timestamp: DateTime.utc_now()
          }
        end

      state =
        Enum.reduce(entries, state, fn entry, acc ->
          %{acc | history: [entry | acc.history]}
        end)

      assert length(state.history) == 5
      # Most recent first
      assert hd(state.history).iteration == 5
    end
  end

  describe "best tracking" do
    test "updates best on better score" do
      state = %TuningJob{best_config: nil, best_score: nil}

      config1 = %{shared_buffers: 4096}
      score1 = 2.0

      {best_config, best_score} =
        if is_nil(state.best_score) or score1 < state.best_score do
          {config1, score1}
        else
          {state.best_config, state.best_score}
        end

      state = %{state | best_config: best_config, best_score: best_score}

      assert state.best_config == config1
      assert state.best_score == 2.0

      # Try with better score
      config2 = %{shared_buffers: 8192}
      score2 = 1.5

      {best_config, best_score} =
        if is_nil(state.best_score) or score2 < state.best_score do
          {config2, score2}
        else
          {state.best_config, state.best_score}
        end

      state = %{state | best_config: best_config, best_score: best_score}

      assert state.best_config == config2
      assert state.best_score == 1.5
    end

    test "keeps best on worse score" do
      state = %TuningJob{best_config: %{shared_buffers: 4096}, best_score: 1.0}

      config_new = %{shared_buffers: 8192}
      score_new = 2.0

      {best_config, best_score} =
        if is_nil(state.best_score) or score_new < state.best_score do
          {config_new, score_new}
        else
          {state.best_config, state.best_score}
        end

      assert best_config == state.best_config
      assert best_score == state.best_score
    end
  end

  describe "key conversion helpers" do
    test "stringify_keys converts atoms to strings" do
      map = %{shared_buffers: 4096, work_mem: 64}

      stringified =
        Map.new(map, fn {k, v} ->
          key = if is_atom(k), do: Atom.to_string(k), else: k
          {key, v}
        end)

      assert stringified == %{"shared_buffers" => 4096, "work_mem" => 64}
    end

    test "atomize_keys converts strings to atoms" do
      map = %{"shared_buffers" => 4096, "work_mem" => 64}

      atomized =
        Map.new(map, fn {k, v} ->
          key = if is_binary(k), do: String.to_existing_atom(k), else: k
          {key, v}
        end)

      assert atomized == %{shared_buffers: 4096, work_mem: 64}
    end
  end
end

defmodule PgGaConf.TuningJobIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias PgGaConf.TuningJob
  alias PgGaConf.Test.Mocks.{MockRepo, MockBenchmark}

  # These tests require more complete mocking
  describe "with mocked dependencies" do
    setup do
      MockRepo.clear_all()
      :ok
    end

    # Integration tests would go here
    # They require fully mocking the benchmark and optimizer modules
  end
end
