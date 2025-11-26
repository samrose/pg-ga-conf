defmodule PgGaConf.GA.PopulationTest do
  use ExUnit.Case, async: true

  alias PgGaConf.GA.Population
  alias PgGaConf.Core.ConfigChromosome
  alias PgGaConf.Strategies.Moderate

  describe "initialize/2" do
    test "creates population of requested size" do
      population = Population.initialize(10, Moderate)

      assert length(population) == 10
      assert Enum.all?(population, fn individual ->
        match?(%ConfigChromosome{}, individual.chromosome)
      end)
    end

    test "each individual has nil fitness initially" do
      population = Population.initialize(5, Moderate)

      assert Enum.all?(population, fn individual ->
        individual.fitness == nil
      end)
    end

    test "generates diverse initial population" do
      population = Population.initialize(10, Moderate)

      shared_buffers_values = Enum.map(population, & &1.chromosome.shared_buffers)
      unique_values = Enum.uniq(shared_buffers_values)

      # Should have at least some diversity
      assert length(unique_values) > 1
    end
  end

  describe "sort_by_fitness/1" do
    test "sorts population by fitness descending" do
      population = [
        %{chromosome: %ConfigChromosome{}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{}, fitness: 100.0},
        %{chromosome: %ConfigChromosome{}, fitness: 75.0}
      ]

      sorted = Population.sort_by_fitness(population)

      assert Enum.map(sorted, & &1.fitness) == [100.0, 75.0, 50.0]
    end

    test "handles nil fitness values by placing them at end" do
      population = [
        %{chromosome: %ConfigChromosome{}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{}, fitness: nil},
        %{chromosome: %ConfigChromosome{}, fitness: 100.0}
      ]

      sorted = Population.sort_by_fitness(population)

      assert Enum.map(sorted, & &1.fitness) == [100.0, 50.0, nil]
    end
  end

  describe "best_individual/1" do
    test "returns individual with highest fitness" do
      population = [
        %{chromosome: %ConfigChromosome{shared_buffers: 100}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 200}, fitness: 100.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 300}, fitness: 75.0}
      ]

      best = Population.best_individual(population)

      assert best.fitness == 100.0
      assert best.chromosome.shared_buffers == 200
    end

    test "returns nil for empty population" do
      assert Population.best_individual([]) == nil
    end
  end

  describe "average_fitness/1" do
    test "calculates average of non-nil fitness values" do
      population = [
        %{chromosome: %ConfigChromosome{}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{}, fitness: 100.0},
        %{chromosome: %ConfigChromosome{}, fitness: 75.0}
      ]

      assert Population.average_fitness(population) == 75.0
    end

    test "ignores nil fitness values" do
      population = [
        %{chromosome: %ConfigChromosome{}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{}, fitness: nil},
        %{chromosome: %ConfigChromosome{}, fitness: 100.0}
      ]

      assert Population.average_fitness(population) == 75.0
    end

    test "returns 0.0 for empty population" do
      assert Population.average_fitness([]) == 0.0
    end
  end
end
