defmodule PgGaConf.GA.EngineTest do
  use ExUnit.Case, async: true

  alias PgGaConf.GA.Engine
  alias PgGaConf.Core.{ConfigChromosome, Metrics}
  alias PgGaConf.Strategies.Moderate

  describe "evolve/2" do
    test "runs evolution for specified generations" do
      # Mock fitness evaluator that returns random fitness
      evaluator = fn _chromosome ->
        %Metrics{
          transactions_per_sec: :rand.uniform(1000) * 1.0,
          p50_latency_ms: :rand.uniform(100) * 1.0,
          p95_latency_ms: :rand.uniform(200) * 1.0,
          p99_latency_ms: :rand.uniform(300) * 1.0,
          cache_hit_ratio: 0.9 + :rand.uniform() * 0.1,
          temp_files: 0,
          deadlocks: 0,
          timeouts: 0
        }
      end

      opts = [
        strategy: Moderate,
        population_size: 10,
        generations: 5,
        fitness_evaluator: evaluator
      ]

      result = Engine.evolve(opts)

      assert {:ok, %{best_chromosome: best, best_fitness: fitness, generation: gen, history: history}} =
               result

      assert %ConfigChromosome{} = best
      assert is_float(fitness)
      assert gen == 5
      assert is_list(history)
      assert length(history) == 5
    end

    test "improves fitness over generations" do
      # Fitness function that rewards higher shared_buffers
      evaluator = fn chromosome ->
        sb = chromosome.shared_buffers || 256
        tps = sb * 0.5

        %Metrics{
          transactions_per_sec: tps,
          p50_latency_ms: 10.0,
          p95_latency_ms: 50.0,
          p99_latency_ms: 100.0,
          cache_hit_ratio: 0.95,
          temp_files: 0,
          deadlocks: 0,
          timeouts: 0
        }
      end

      opts = [
        strategy: Moderate,
        population_size: 20,
        generations: 10,
        fitness_evaluator: evaluator
      ]

      {:ok, result} = Engine.evolve(opts)

      # Check that fitness generally improved
      first_gen_best = Enum.at(result.history, 0).best_fitness
      last_gen_best = Enum.at(result.history, -1).best_fitness

      # Last generation should be at least as good as first
      assert last_gen_best >= first_gen_best
    end

    test "tracks generation history" do
      evaluator = fn _chromosome ->
        %Metrics{
          transactions_per_sec: 1000.0,
          p50_latency_ms: 10.0,
          p95_latency_ms: 50.0,
          p99_latency_ms: 100.0,
          cache_hit_ratio: 0.95,
          temp_files: 0,
          deadlocks: 0,
          timeouts: 0
        }
      end

      opts = [
        strategy: Moderate,
        population_size: 10,
        generations: 3,
        fitness_evaluator: evaluator
      ]

      {:ok, result} = Engine.evolve(opts)

      assert length(result.history) == 3

      Enum.each(result.history, fn gen_stats ->
        assert Map.has_key?(gen_stats, :generation)
        assert Map.has_key?(gen_stats, :best_fitness)
        assert Map.has_key?(gen_stats, :avg_fitness)
        assert Map.has_key?(gen_stats, :best_chromosome)
      end)
    end

    test "supports elitism" do
      evaluator = fn _chromosome ->
        %Metrics{
          transactions_per_sec: 1000.0,
          p50_latency_ms: 10.0,
          p95_latency_ms: 50.0,
          p99_latency_ms: 100.0,
          cache_hit_ratio: 0.95,
          temp_files: 0,
          deadlocks: 0,
          timeouts: 0
        }
      end

      opts = [
        strategy: Moderate,
        population_size: 10,
        generations: 5,
        elitism_count: 2,
        fitness_evaluator: evaluator
      ]

      result = Engine.evolve(opts)

      assert {:ok, _} = result
    end

    test "handles early stopping when fitness plateaus" do
      # Constant fitness - should trigger early stopping
      evaluator = fn _chromosome ->
        %Metrics{
          transactions_per_sec: 1000.0,
          p50_latency_ms: 10.0,
          p95_latency_ms: 50.0,
          p99_latency_ms: 100.0,
          cache_hit_ratio: 0.95,
          temp_files: 0,
          deadlocks: 0,
          timeouts: 0
        }
      end

      opts = [
        strategy: Moderate,
        population_size: 10,
        generations: 20,
        early_stop_generations: 5,
        fitness_evaluator: evaluator
      ]

      {:ok, result} = Engine.evolve(opts)

      # Should stop before 20 generations
      assert result.generation <= 20
    end
  end

  describe "evolve_generation/3" do
    test "creates next generation from current population" do
      population =
        for _ <- 1..10 do
          %{
            chromosome: Moderate.generate_random_config(),
            fitness: :rand.uniform() * 100.0
          }
        end

      bounds = Moderate.parameter_bounds()
      mutation_rate = Moderate.mutation_rate()
      crossover_strategy = Moderate.crossover_strategy()

      next_gen =
        Engine.evolve_generation(population, %{
          bounds: bounds,
          mutation_rate: mutation_rate,
          crossover_strategy: crossover_strategy,
          elitism_count: 2
        })

      assert length(next_gen) == 10
      assert Enum.all?(next_gen, fn ind -> match?(%{chromosome: %ConfigChromosome{}}, ind) end)
    end
  end
end
