defmodule PgGaConf.GA.SelectionTest do
  use ExUnit.Case, async: true

  alias PgGaConf.GA.Selection
  alias PgGaConf.Core.ConfigChromosome

  describe "tournament/2" do
    test "selects individual from tournament" do
      population = [
        %{chromosome: %ConfigChromosome{shared_buffers: 100}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 200}, fitness: 100.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 300}, fitness: 75.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 400}, fitness: 90.0}
      ]

      selected = Selection.tournament(population, tournament_size: 2)

      assert %{chromosome: %ConfigChromosome{}, fitness: fitness} = selected
      assert fitness != nil
    end

    test "tournament size of 1 returns random individual" do
      population = [
        %{chromosome: %ConfigChromosome{shared_buffers: 100}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 200}, fitness: 100.0}
      ]

      selected = Selection.tournament(population, tournament_size: 1)

      assert selected in population
    end

    test "larger tournament size favors better fitness" do
      population = [
        %{chromosome: %ConfigChromosome{shared_buffers: 100}, fitness: 10.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 200}, fitness: 100.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 300}, fitness: 20.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 400}, fitness: 30.0}
      ]

      # Run tournament many times, best should be selected frequently
      selections = for _ <- 1..100, do: Selection.tournament(population, tournament_size: 4)
      best_selections = Enum.count(selections, fn ind -> ind.fitness == 100.0 end)

      # With tournament size = population size, best should be selected almost always
      assert best_selections > 80
    end

    test "handles empty tournament size gracefully" do
      population = [
        %{chromosome: %ConfigChromosome{shared_buffers: 100}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 200}, fitness: 100.0}
      ]

      selected = Selection.tournament(population, tournament_size: 0)

      # Should default to tournament size of 1
      assert selected in population
    end
  end

  describe "select_parents/2" do
    test "selects requested number of parents" do
      population = [
        %{chromosome: %ConfigChromosome{shared_buffers: 100}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 200}, fitness: 100.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 300}, fitness: 75.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 400}, fitness: 90.0}
      ]

      parents = Selection.select_parents(population, 10)

      assert length(parents) == 10
      assert Enum.all?(parents, fn parent ->
        match?(%{chromosome: %ConfigChromosome{}, fitness: _}, parent)
      end)
    end

    test "allows selecting more parents than population size" do
      population = [
        %{chromosome: %ConfigChromosome{shared_buffers: 100}, fitness: 50.0},
        %{chromosome: %ConfigChromosome{shared_buffers: 200}, fitness: 100.0}
      ]

      parents = Selection.select_parents(population, 10)

      assert length(parents) == 10
    end
  end
end
