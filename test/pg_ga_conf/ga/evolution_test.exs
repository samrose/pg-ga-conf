defmodule PgGaConf.GA.EvolutionTest do
  use ExUnit.Case, async: true

  alias PgGaConf.GA.Evolution
  alias PgGaConf.Core.ConfigChromosome
  alias PgGaConf.Strategies.Moderate

  describe "crossover/3" do
    test "uniform crossover produces valid offspring" do
      parent1 = ConfigChromosome.new(%{shared_buffers: 1000, work_mem: 50})
      parent2 = ConfigChromosome.new(%{shared_buffers: 2000, work_mem: 100})

      {child1, child2} = Evolution.crossover(parent1, parent2, :uniform)

      assert %ConfigChromosome{} = child1
      assert %ConfigChromosome{} = child2

      # Children should have values from parents
      assert child1.shared_buffers in [1000, 2000]
      assert child2.shared_buffers in [1000, 2000]
      assert child1.work_mem in [50, 100]
      assert child2.work_mem in [50, 100]
    end

    test "single_point crossover produces valid offspring" do
      parent1 = ConfigChromosome.new(%{shared_buffers: 1000, work_mem: 50})
      parent2 = ConfigChromosome.new(%{shared_buffers: 2000, work_mem: 100})

      {child1, child2} = Evolution.crossover(parent1, parent2, :single_point)

      assert %ConfigChromosome{} = child1
      assert %ConfigChromosome{} = child2
    end

    test "smart crossover preserves related parameters" do
      parent1 = ConfigChromosome.new(%{
        shared_buffers: 1000,
        effective_cache_size: 4000,
        work_mem: 50
      })

      parent2 = ConfigChromosome.new(%{
        shared_buffers: 2000,
        effective_cache_size: 8000,
        work_mem: 100
      })

      {child1, child2} = Evolution.crossover(parent1, parent2, :smart)

      assert %ConfigChromosome{} = child1
      assert %ConfigChromosome{} = child2

      # Smart crossover should maintain relationships
      # effective_cache_size should typically be 4x shared_buffers
      if child1.shared_buffers == 1000 do
        assert child1.effective_cache_size == 4000
      else
        assert child1.effective_cache_size == 8000
      end
    end
  end

  describe "mutate/3" do
    test "mutates chromosome within strategy bounds" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000, work_mem: 50})
      bounds = Moderate.parameter_bounds()

      mutated = Evolution.mutate(chromosome, 1.0, bounds)

      assert %ConfigChromosome{} = mutated
      assert mutated.shared_buffers >= bounds.shared_buffers |> elem(0)
      assert mutated.shared_buffers <= bounds.shared_buffers |> elem(1)
    end

    test "mutation rate of 0.0 produces no changes" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000, work_mem: 50})
      bounds = Moderate.parameter_bounds()

      mutated = Evolution.mutate(chromosome, 0.0, bounds)

      assert mutated.shared_buffers == 1000
      assert mutated.work_mem == 50
    end

    test "mutation rate of 1.0 produces many changes" do
      chromosome = ConfigChromosome.new(%{
        shared_buffers: 1000,
        work_mem: 50,
        checkpoint_completion_target: 0.7
      })

      bounds = Moderate.parameter_bounds()

      # Run multiple times and check that at least some parameters changed
      mutated_list =
        for _ <- 1..10 do
          Evolution.mutate(chromosome, 1.0, bounds)
        end

      # At least some mutations should have different shared_buffers
      different_sb = Enum.any?(mutated_list, fn m -> m.shared_buffers != 1000 end)
      assert different_sb
    end

    test "only mutates parameters in bounds map" do
      # Test that parameters not in bounds are unchanged
      chromosome = ConfigChromosome.new(%{
        shared_buffers: 1000,
        checkpoint_completion_target: 0.75
      })

      bounds = %{shared_buffers: {256, 8192}}

      # Multiple mutations to ensure shared_buffers changes
      mutated_list =
        for _ <- 1..10 do
          Evolution.mutate(chromosome, 1.0, bounds)
        end

      # shared_buffers should change (it's in bounds with mutation_rate=1.0)
      assert Enum.any?(mutated_list, fn m -> m.shared_buffers != 1000 end)

      # checkpoint_completion_target should never change (not in bounds)
      assert Enum.all?(mutated_list, fn m -> m.checkpoint_completion_target == 0.75 end)
    end
  end

  describe "gaussian_mutate_value/3" do
    test "mutates integer value within bounds" do
      bounds = {100, 1000}

      mutated = Evolution.gaussian_mutate_value(500, bounds, :integer)

      assert is_integer(mutated)
      assert mutated >= 100
      assert mutated <= 1000
    end

    test "mutates float value within bounds" do
      bounds = {0.5, 0.9}

      mutated = Evolution.gaussian_mutate_value(0.7, bounds, :float)

      assert is_float(mutated)
      assert mutated >= 0.5
      assert mutated <= 0.9
    end

    test "produces variety in mutations" do
      bounds = {100, 1000}

      mutations =
        for _ <- 1..20 do
          Evolution.gaussian_mutate_value(500, bounds, :integer)
        end

      unique_values = Enum.uniq(mutations)

      # Should produce at least some variety
      assert length(unique_values) > 1
    end
  end
end
