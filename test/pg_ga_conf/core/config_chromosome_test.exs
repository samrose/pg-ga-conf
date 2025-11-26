defmodule PgGaConf.Core.ConfigChromosomeTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Core.ConfigChromosome

  describe "new/1" do
    test "creates chromosome with default values" do
      chromosome = ConfigChromosome.new()

      assert chromosome.shared_buffers > 0
      assert chromosome.effective_cache_size > 0
      assert chromosome.work_mem > 0
      assert chromosome.fitness == nil
      assert chromosome.generation == 0
    end

    test "creates chromosome with custom values" do
      chromosome = ConfigChromosome.new(%{
        shared_buffers: 1024,
        work_mem: 64,
        generation: 5
      })

      assert chromosome.shared_buffers == 1024
      assert chromosome.work_mem == 64
      assert chromosome.generation == 5
    end
  end

  describe "to_postgresql_conf/1" do
    test "converts chromosome to PostgreSQL config map" do
      chromosome = ConfigChromosome.new(%{
        shared_buffers: 1024,
        work_mem: 64
      })

      config = ConfigChromosome.to_postgresql_conf(chromosome)

      assert config["shared_buffers"] == "1024MB"
      assert config["work_mem"] == "64MB"
      assert is_map(config)
    end
  end

  describe "validate/1" do
    test "validates effective_cache_size >= shared_buffers" do
      valid = ConfigChromosome.new(%{
        shared_buffers: 1024,
        effective_cache_size: 2048
      })

      invalid = ConfigChromosome.new(%{
        shared_buffers: 2048,
        effective_cache_size: 1024
      })

      assert ConfigChromosome.validate(valid) == :ok
      assert {:error, _} = ConfigChromosome.validate(invalid)
    end
  end
end
