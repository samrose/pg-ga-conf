defmodule PgGaConf.Optimizer.GATest do
  use ExUnit.Case, async: true

  alias PgGaConf.Optimizer.GA
  alias PgGaConf.Test.Fixtures

  describe "init/2" do
    test "initializes with default options" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = GA.init(knob_space)

      assert state.knob_space == knob_space
      assert state.generation == 0
      assert state.population_size == 20
      assert state.elitism_count == 2
      assert state.mutation_rate == 0.15
      assert state.crossover_strategy == :smart
      assert is_nil(state.best_config)
      assert is_nil(state.best_score)
      assert state.observations == []
    end

    test "initializes with custom population size" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = GA.init(knob_space, population_size: 10)

      assert state.population_size == 10
      assert length(state.population) == 10
    end

    test "initializes with custom elitism count" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = GA.init(knob_space, elitism_count: 4)

      assert state.elitism_count == 4
    end

    test "initializes with custom mutation rate" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = GA.init(knob_space, mutation_rate: 0.3)

      assert state.mutation_rate == 0.3
    end

    test "initializes with custom crossover strategy" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = GA.init(knob_space, crossover_strategy: :uniform)

      assert state.crossover_strategy == :uniform
    end

    test "population has valid configs within bounds" do
      knob_space = Fixtures.minimal_knob_space()
      assert {:ok, state} = GA.init(knob_space, population_size: 5)

      for individual <- state.population do
        assert is_map(individual.config)
        assert is_nil(individual.fitness)

        # Check values within bounds
        {_, min_sb, max_sb} = knob_space[:shared_buffers]
        assert individual.config[:shared_buffers] >= min_sb
        assert individual.config[:shared_buffers] <= max_sb

        {_, min_wm, max_wm} = knob_space[:work_mem]
        assert individual.config[:work_mem] >= min_wm
        assert individual.config[:work_mem] <= max_wm
      end
    end

    test "seed produces deterministic population" do
      knob_space = Fixtures.minimal_knob_space()

      {:ok, state1} = GA.init(knob_space, seed: 42, population_size: 5)
      {:ok, state2} = GA.init(knob_space, seed: 42, population_size: 5)

      configs1 = Enum.map(state1.population, & &1.config)
      configs2 = Enum.map(state2.population, & &1.config)

      assert configs1 == configs2
    end
  end

  describe "suggest/1" do
    test "suggests unevaluated configs from population" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5)

      {:ok, config, _new_state} = GA.suggest(state)

      assert is_map(config)
      assert Map.has_key?(config, :shared_buffers)
      assert Map.has_key?(config, :work_mem)
    end

    test "returns different configs each time before evolution" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5, seed: 42)

      {:ok, config1, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config1, 1.0)

      {:ok, config2, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config2, 0.9)

      {:ok, config3, _state} = GA.suggest(state)

      # Should get different configs (population individuals)
      assert config1 != config2 or config2 != config3
    end
  end

  describe "observe/3" do
    test "records observation and updates best" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5)

      {:ok, config, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config, 1.5)

      assert state.best_config == config
      assert state.best_score == 1.5
      assert length(state.observations) == 1
      assert {^config, 1.5} = hd(state.observations)
    end

    test "tracks better scores" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5)

      {:ok, config1, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config1, 2.0)

      {:ok, config2, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config2, 1.0)

      # Should track the better (lower) score
      assert state.best_score == 1.0
      assert state.best_config == config2
    end

    test "does not replace best with worse score" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5)

      {:ok, config1, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config1, 1.0)

      {:ok, config2, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config2, 2.0)

      # Should keep the better (lower) score
      assert state.best_score == 1.0
      assert state.best_config == config1
    end

    test "updates fitness in population" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5)

      {:ok, config, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config, 1.0)

      evaluated = Enum.find(state.population, &(&1.config == config))
      assert evaluated.fitness != nil
      # Fitness is 1/(score+0.001)
      assert_in_delta evaluated.fitness, 1.0 / 1.001, 0.001
    end
  end

  describe "best/1" do
    test "returns error when no observations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space)

      assert {:error, :no_observations} = GA.best(state)
    end

    test "returns best config and score after observations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5)

      {:ok, config1, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config1, 2.0)

      {:ok, config2, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config2, 1.0)

      assert {:ok, best_config, best_score} = GA.best(state)
      assert best_config == config2
      assert best_score == 1.0
    end
  end

  describe "warm_start/2" do
    test "initializes with prior observations" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 10)

      prior = [
        {%{shared_buffers: 512.0, work_mem: 32.0}, 1.0},
        {%{shared_buffers: 1024.0, work_mem: 64.0}, 0.5}
      ]

      {:ok, state} = GA.warm_start(state, prior)

      assert length(state.observations) == 2
      assert state.best_score == 0.5
      assert state.best_config == %{shared_buffers: 1024.0, work_mem: 64.0}
    end

    test "injects good configs into population" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 10)

      prior = [
        {%{shared_buffers: 512.0, work_mem: 32.0}, 1.0}
      ]

      {:ok, state} = GA.warm_start(state, prior)

      # First individual should be seeded with prior config
      first = hd(state.population)
      assert first.config == %{shared_buffers: 512.0, work_mem: 32.0}
      assert first.fitness != nil
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips state" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5)

      {:ok, config, state} = GA.suggest(state)
      {:ok, state} = GA.observe(state, config, 1.5)

      binary = GA.serialize(state)
      {:ok, restored} = GA.deserialize(binary)

      assert restored.knob_space == state.knob_space
      assert restored.generation == state.generation
      assert restored.best_config == state.best_config
      assert restored.best_score == state.best_score
      assert length(restored.observations) == length(state.observations)
    end

    test "deserialize returns error for invalid binary" do
      assert {:error, :invalid_state} = GA.deserialize("invalid")
    end
  end

  describe "evolution" do
    test "evolves to next generation after all evaluated" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5, seed: 42)

      # Evaluate all individuals in population
      state =
        Enum.reduce(1..5, state, fn _, acc ->
          {:ok, config, acc} = GA.suggest(acc)
          {:ok, acc} = GA.observe(acc, config, :rand.uniform())
          acc
        end)

      assert state.generation == 0

      # Next suggest should trigger evolution
      {:ok, _config, state} = GA.suggest(state)

      assert state.generation == 1
    end

    test "preserves elite individuals" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5, elitism_count: 2, seed: 42)

      # Evaluate all with decreasing scores (so best configs are known)
      scores = [1.0, 2.0, 3.0, 4.0, 5.0]

      {state, _} =
        Enum.reduce(scores, {state, []}, fn score, {acc, configs} ->
          {:ok, config, acc} = GA.suggest(acc)
          {:ok, acc} = GA.observe(acc, config, score)
          {acc, [config | configs]}
        end)

      # Get the best 2 configs (lowest scores = highest fitness)
      sorted_pop = Enum.sort_by(state.population, & &1.fitness, :desc)
      elite_configs = Enum.take(sorted_pop, 2) |> Enum.map(& &1.config)

      # Trigger evolution
      {:ok, _config, new_state} = GA.suggest(state)

      # Elite should be preserved
      new_configs = Enum.map(new_state.population, & &1.config)

      for elite <- elite_configs do
        assert elite in new_configs
      end
    end
  end

  describe "crossover strategies" do
    test "uniform crossover produces valid offspring" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5, crossover_strategy: :uniform, seed: 42)

      # Evaluate and evolve
      state =
        Enum.reduce(1..5, state, fn _, acc ->
          {:ok, config, acc} = GA.suggest(acc)
          {:ok, acc} = GA.observe(acc, config, :rand.uniform())
          acc
        end)

      {:ok, _config, state} = GA.suggest(state)

      # All configs should have valid keys
      for individual <- state.population do
        assert Map.has_key?(individual.config, :shared_buffers)
        assert Map.has_key?(individual.config, :work_mem)
      end
    end

    test "single_point crossover produces valid offspring" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5, crossover_strategy: :single_point, seed: 42)

      state =
        Enum.reduce(1..5, state, fn _, acc ->
          {:ok, config, acc} = GA.suggest(acc)
          {:ok, acc} = GA.observe(acc, config, :rand.uniform())
          acc
        end)

      {:ok, _config, state} = GA.suggest(state)

      for individual <- state.population do
        assert Map.has_key?(individual.config, :shared_buffers)
        assert Map.has_key?(individual.config, :work_mem)
      end
    end

    test "smart crossover produces valid offspring" do
      knob_space = Fixtures.sample_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5, crossover_strategy: :smart, seed: 42)

      state =
        Enum.reduce(1..5, state, fn _, acc ->
          {:ok, config, acc} = GA.suggest(acc)
          {:ok, acc} = GA.observe(acc, config, :rand.uniform())
          acc
        end)

      {:ok, _config, state} = GA.suggest(state)

      for individual <- state.population do
        assert Map.has_key?(individual.config, :shared_buffers)
        assert Map.has_key?(individual.config, :work_mem)
        assert Map.has_key?(individual.config, :max_connections)
        assert Map.has_key?(individual.config, :huge_pages)
      end
    end
  end

  describe "mutation" do
    test "mutated values stay within bounds" do
      knob_space = Fixtures.sample_knob_space()
      {:ok, state} = GA.init(knob_space, population_size: 5, mutation_rate: 1.0, seed: 42)

      # Force evolution with high mutation rate
      state =
        Enum.reduce(1..5, state, fn _, acc ->
          {:ok, config, acc} = GA.suggest(acc)
          {:ok, acc} = GA.observe(acc, config, :rand.uniform())
          acc
        end)

      {:ok, _config, state} = GA.suggest(state)

      # Check all mutated offspring are within bounds
      for individual <- state.population do
        config = individual.config

        {_, sb_min, sb_max} = knob_space[:shared_buffers]
        assert config[:shared_buffers] >= sb_min
        assert config[:shared_buffers] <= sb_max

        {_, wm_min, wm_max} = knob_space[:work_mem]
        assert config[:work_mem] >= wm_min
        assert config[:work_mem] <= wm_max

        {_, mc_min, mc_max} = knob_space[:max_connections]
        assert config[:max_connections] >= mc_min
        assert config[:max_connections] <= mc_max

        {_, hp_choices} = knob_space[:huge_pages]
        assert config[:huge_pages] in hp_choices
      end
    end
  end
end
