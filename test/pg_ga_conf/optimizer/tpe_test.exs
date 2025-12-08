defmodule PgGaConf.Optimizer.TPETest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias PgGaConf.Optimizer.TPE
  alias PgGaConf.Test.Fixtures

  describe "init/2" do
    test "initializes TPE with knob space" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = TPE.init(knob_space)

      assert state.knob_space == knob_space
      assert state.iteration == 0
      assert state.n_startup_trials == 5
      assert is_nil(state.best_config)
      assert is_nil(state.best_score)
    end

    test "initializes with custom n_startup_trials" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = TPE.init(knob_space, n_startup_trials: 10)

      assert state.n_startup_trials == 10
    end

    test "initializes with seed" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, _state} = TPE.init(knob_space, seed: 123)
    end
  end

  describe "suggest/1" do
    test "suggests configs within bounds" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      {:ok, config, _state} = TPE.suggest(state)

      assert is_map(config)
      assert Map.has_key?(config, :shared_buffers)
      assert Map.has_key?(config, :work_mem)

      {_, sb_min, sb_max} = knob_space[:shared_buffers]
      assert config[:shared_buffers] >= sb_min
      assert config[:shared_buffers] <= sb_max
    end

    test "increments iteration" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      {:ok, _config, new_state} = TPE.suggest(state)

      assert new_state.iteration == 1
    end
  end

  describe "observe/3" do
    test "records observation and updates best" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      {:ok, config, state} = TPE.suggest(state)
      {:ok, state} = TPE.observe(state, config, 1.5)

      assert state.best_config == config
      assert state.best_score == 1.5
    end

    test "keeps better score" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      {:ok, config1, state} = TPE.suggest(state)
      {:ok, state} = TPE.observe(state, config1, 2.0)

      {:ok, config2, state} = TPE.suggest(state)
      {:ok, state} = TPE.observe(state, config2, 1.0)

      assert state.best_score == 1.0
      assert state.best_config == config2
    end
  end

  describe "best/1" do
    test "returns error when no observations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      assert {:error, :no_observations} = TPE.best(state)
    end

    test "returns best config and score" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      {:ok, config, state} = TPE.suggest(state)
      {:ok, state} = TPE.observe(state, config, 1.5)

      assert {:ok, ^config, 1.5} = TPE.best(state)
    end
  end

  describe "warm_start/2" do
    test "initializes with prior observations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      prior = [
        {%{shared_buffers: 512.0, work_mem: 32.0}, 1.0},
        {%{shared_buffers: 1024.0, work_mem: 64.0}, 0.5}
      ]

      {:ok, state} = TPE.warm_start(state, prior)

      assert state.best_score == 0.5
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips state" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      {:ok, config, state} = TPE.suggest(state)
      {:ok, state} = TPE.observe(state, config, 1.5)

      binary = TPE.serialize(state)
      {:ok, restored} = TPE.deserialize(binary)

      assert restored.best_score == state.best_score
      assert restored.iteration == state.iteration
    end
  end

  describe "optimization loop" do
    test "improves over multiple iterations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = TPE.init(knob_space)

      # Simple objective: minimize (shared_buffers - 500)^2 + (work_mem - 30)^2
      objective = fn config ->
        sb_err = (config[:shared_buffers] - 500) / 100
        wm_err = (config[:work_mem] - 30) / 10
        sb_err * sb_err + wm_err * wm_err
      end

      # Run several iterations
      state =
        Enum.reduce(1..10, state, fn _, acc ->
          {:ok, config, acc} = TPE.suggest(acc)
          score = objective.(config)
          {:ok, acc} = TPE.observe(acc, config, score)
          acc
        end)

      {:ok, _best_config, best_score} = TPE.best(state)

      # Should have found a reasonably good solution
      assert best_score < 100
    end
  end
end
