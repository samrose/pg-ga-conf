defmodule PgGaConf.Strategies.ModerateTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Strategies.Moderate
  alias PgGaConf.Core.ConfigChromosome

  describe "parameter_bounds/0" do
    test "returns bounds for all parameters" do
      bounds = Moderate.parameter_bounds()

      assert is_map(bounds)
      assert Map.has_key?(bounds, :shared_buffers)
      assert Map.has_key?(bounds, :work_mem)
      assert Map.has_key?(bounds, :checkpoint_completion_target)
    end

    test "bounds have min <= max" do
      bounds = Moderate.parameter_bounds()

      Enum.each(bounds, fn {_param, {min, max}} ->
        assert min <= max
      end)
    end
  end

  describe "generate_random_config/0" do
    test "generates valid configuration within bounds" do
      config = Moderate.generate_random_config()

      assert %ConfigChromosome{} = config

      bounds = Moderate.parameter_bounds()

      Enum.each(bounds, fn {param, {min, max}} ->
        value = Map.get(config, param)
        assert value >= min, "#{param} value #{value} below min #{min}"
        assert value <= max, "#{param} value #{value} above max #{max}"
      end)
    end

    test "generates different configs on successive calls" do
      configs = for _ <- 1..5, do: Moderate.generate_random_config()

      # At least some should be different
      unique_shared_buffers = configs |> Enum.map(& &1.shared_buffers) |> Enum.uniq()
      assert length(unique_shared_buffers) > 1
    end
  end

  describe "mutation_rate/0" do
    test "returns reasonable mutation rate" do
      rate = Moderate.mutation_rate()

      assert rate > 0.0
      assert rate < 1.0
    end
  end
end
