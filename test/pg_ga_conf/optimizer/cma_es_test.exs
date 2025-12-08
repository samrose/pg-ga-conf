defmodule PgGaConf.Optimizer.CmaEsTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias PgGaConf.Optimizer.CmaEs
  alias PgGaConf.Test.Fixtures

  describe "init/2" do
    test "initializes CMA-ES with knob space" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = CmaEs.init(knob_space)

      assert state.iteration == 0
      assert state.sigma0 == 0.5
      assert state.n_startup_trials == 10
      assert is_nil(state.best_config)
      assert is_nil(state.best_score)
    end

    test "initializes with custom sigma0" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = CmaEs.init(knob_space, sigma0: 0.3)

      assert state.sigma0 == 0.3
    end

    test "initializes with custom restart_strategy" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, _state} = CmaEs.init(knob_space, restart_strategy: "bipop")
    end

    test "initializes with seed" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, _state} = CmaEs.init(knob_space, seed: 123)
    end

    test "converts categorical knobs to integers" do
      knob_space = Fixtures.sample_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      # The internal knob_space should have converted categorical to integer
      assert state.knob_space[:huge_pages] == {:integer, 0, 2}
      # Original defs are preserved
      assert state.knob_defs[:huge_pages] == {:categorical, ["off", "on", "try"]}
    end
  end

  describe "suggest/1" do
    test "suggests configs within bounds" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      {:ok, config, _state} = CmaEs.suggest(state)

      assert is_map(config)
      assert Map.has_key?(config, :shared_buffers)
      assert Map.has_key?(config, :work_mem)

      {_, sb_min, sb_max} = knob_space[:shared_buffers]
      assert config[:shared_buffers] >= sb_min
      assert config[:shared_buffers] <= sb_max
    end

    test "decodes categorical values" do
      knob_space = Fixtures.sample_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      {:ok, config, _state} = CmaEs.suggest(state)

      # Categorical should be decoded back to string value
      assert config[:huge_pages] in ["off", "on", "try"]
    end

    test "increments iteration" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      {:ok, _config, new_state} = CmaEs.suggest(state)

      assert new_state.iteration == 1
    end
  end

  describe "observe/3" do
    test "records observation and updates best" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      {:ok, config, state} = CmaEs.suggest(state)
      {:ok, state} = CmaEs.observe(state, config, 1.5)

      assert state.best_config == config
      assert state.best_score == 1.5
    end

    test "keeps better score" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      {:ok, config1, state} = CmaEs.suggest(state)
      {:ok, state} = CmaEs.observe(state, config1, 2.0)

      {:ok, config2, state} = CmaEs.suggest(state)
      {:ok, state} = CmaEs.observe(state, config2, 1.0)

      assert state.best_score == 1.0
      assert state.best_config == config2
    end
  end

  describe "best/1" do
    test "returns error when no observations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      assert {:error, :no_observations} = CmaEs.best(state)
    end

    test "returns best config and score" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      {:ok, config, state} = CmaEs.suggest(state)
      {:ok, state} = CmaEs.observe(state, config, 1.5)

      assert {:ok, ^config, 1.5} = CmaEs.best(state)
    end
  end

  describe "warm_start/2" do
    test "initializes with prior observations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      prior = [
        {%{shared_buffers: 512.0, work_mem: 32.0}, 1.0},
        {%{shared_buffers: 1024.0, work_mem: 64.0}, 0.5}
      ]

      {:ok, state} = CmaEs.warm_start(state, prior)

      assert state.best_score == 0.5
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips state" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space)

      {:ok, config, state} = CmaEs.suggest(state)
      {:ok, state} = CmaEs.observe(state, config, 1.5)

      binary = CmaEs.serialize(state)
      {:ok, restored} = CmaEs.deserialize(binary)

      assert restored.best_score == state.best_score
      assert restored.iteration == state.iteration
    end
  end

  describe "optimization with correlated parameters" do
    test "learns correlations over iterations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = CmaEs.init(knob_space, n_startup_trials: 5)

      # Objective with correlated optimum: shared_buffers and work_mem should be similar
      objective = fn config ->
        # Optimal around shared_buffers=500, work_mem=50
        # With correlation: when shared_buffers is high, work_mem should be proportionally higher
        sb = config[:shared_buffers]
        wm = config[:work_mem]

        # Reward correlation
        ratio_err = abs(sb / 10 - wm) / 10
        target_err = abs(sb - 500) / 100 + abs(wm - 50) / 10

        ratio_err + target_err
      end

      # Run several iterations
      state =
        Enum.reduce(1..15, state, fn _, acc ->
          {:ok, config, acc} = CmaEs.suggest(acc)
          score = objective.(config)
          {:ok, acc} = CmaEs.observe(acc, config, score)
          acc
        end)

      {:ok, _best_config, best_score} = CmaEs.best(state)

      # Should have found a reasonable solution
      assert best_score < 50
    end
  end
end
