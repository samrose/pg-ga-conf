defmodule PgGaConf.GA.FitnessTest do
  use ExUnit.Case, async: true

  alias PgGaConf.GA.Fitness
  alias PgGaConf.Core.{ConfigChromosome, Metrics}

  describe "calculate/2" do
    test "calculates fitness from metrics" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 0,
        timeouts: 0
      }

      fitness = Fitness.calculate(chromosome, metrics)

      assert is_float(fitness)
      assert fitness > 0.0
    end

    test "higher throughput increases fitness" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      low_tps_metrics = %Metrics{
        transactions_per_sec: 100.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 0,
        timeouts: 0
      }

      high_tps_metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 0,
        timeouts: 0
      }

      fitness_low = Fitness.calculate(chromosome, low_tps_metrics)
      fitness_high = Fitness.calculate(chromosome, high_tps_metrics)

      assert fitness_high > fitness_low
    end

    test "lower latency increases fitness" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      high_latency_metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 100.0,
        p95_latency_ms: 500.0,
        p99_latency_ms: 1000.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 0,
        timeouts: 0
      }

      low_latency_metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 0,
        timeouts: 0
      }

      fitness_high_lat = Fitness.calculate(chromosome, high_latency_metrics)
      fitness_low_lat = Fitness.calculate(chromosome, low_latency_metrics)

      assert fitness_low_lat > fitness_high_lat
    end

    test "applies penalty for constraint violations" do
      # Invalid: effective_cache_size < shared_buffers
      invalid_chromosome = ConfigChromosome.new(%{
        shared_buffers: 8000,
        effective_cache_size: 4000
      })

      valid_chromosome = ConfigChromosome.new(%{
        shared_buffers: 4000,
        effective_cache_size: 8000
      })

      metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 0,
        timeouts: 0
      }

      fitness_invalid = Fitness.calculate(invalid_chromosome, metrics)
      fitness_valid = Fitness.calculate(valid_chromosome, metrics)

      # Invalid config should have lower fitness
      assert fitness_invalid < fitness_valid
    end

    test "applies penalty for temp files" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      no_temp_metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 0,
        timeouts: 0
      }

      with_temp_metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 100,
        deadlocks: 0,
        timeouts: 0
      }

      fitness_no_temp = Fitness.calculate(chromosome, no_temp_metrics)
      fitness_with_temp = Fitness.calculate(chromosome, with_temp_metrics)

      # Temp files should reduce fitness
      assert fitness_with_temp < fitness_no_temp
    end

    test "applies penalty for deadlocks" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      no_deadlock_metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 0,
        timeouts: 0
      }

      with_deadlock_metrics = %Metrics{
        transactions_per_sec: 1000.0,
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0,
        cache_hit_ratio: 0.95,
        temp_files: 0,
        deadlocks: 10,
        timeouts: 0
      }

      fitness_no_deadlock = Fitness.calculate(chromosome, no_deadlock_metrics)
      fitness_with_deadlock = Fitness.calculate(chromosome, with_deadlock_metrics)

      # Deadlocks should reduce fitness
      assert fitness_with_deadlock < fitness_no_deadlock
    end
  end

  describe "throughput_score/1" do
    test "calculates score from transactions per second" do
      metrics = %Metrics{transactions_per_sec: 1000.0}

      score = Fitness.throughput_score(metrics)

      assert is_float(score)
      assert score > 0.0
    end

    test "higher TPS yields higher score" do
      low_metrics = %Metrics{transactions_per_sec: 100.0}
      high_metrics = %Metrics{transactions_per_sec: 1000.0}

      assert Fitness.throughput_score(high_metrics) > Fitness.throughput_score(low_metrics)
    end
  end

  describe "latency_score/1" do
    test "calculates score from latency percentiles" do
      metrics = %Metrics{
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0
      }

      score = Fitness.latency_score(metrics)

      assert is_float(score)
      assert score > 0.0
    end

    test "lower latency yields higher score" do
      high_latency = %Metrics{
        p50_latency_ms: 100.0,
        p95_latency_ms: 500.0,
        p99_latency_ms: 1000.0
      }

      low_latency = %Metrics{
        p50_latency_ms: 10.0,
        p95_latency_ms: 50.0,
        p99_latency_ms: 100.0
      }

      assert Fitness.latency_score(low_latency) > Fitness.latency_score(high_latency)
    end
  end
end
