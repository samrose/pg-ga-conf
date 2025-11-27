defmodule PgGaConf.KnobSpaceTest do
  use ExUnit.Case, async: true

  alias PgGaConf.KnobSpace

  describe "all/0 and all_knobs/0" do
    test "returns full knob space map" do
      knobs = KnobSpace.all()
      assert is_map(knobs)
      assert map_size(knobs) > 20
      assert Map.has_key?(knobs, :shared_buffers)
      assert Map.has_key?(knobs, :work_mem)
      assert Map.has_key?(knobs, :max_connections)
    end

    test "all_knobs/0 is alias for all/0" do
      assert KnobSpace.all() == KnobSpace.all_knobs()
    end
  end

  describe "workload-specific knob sets" do
    test "oltp_knobs/0 returns subset for OLTP" do
      knobs = KnobSpace.oltp_knobs()
      assert is_map(knobs)
      assert map_size(knobs) > 0
      assert map_size(knobs) < map_size(KnobSpace.all())
      # OLTP should include key OLTP knobs
      assert Map.has_key?(knobs, :shared_buffers)
      assert Map.has_key?(knobs, :random_page_cost)
    end

    test "olap_knobs/0 returns subset for OLAP" do
      knobs = KnobSpace.olap_knobs()
      assert is_map(knobs)
      assert map_size(knobs) > 0
      # OLAP should include parallelism knobs
      assert Map.has_key?(knobs, :max_parallel_workers_per_gather)
    end

    test "mixed_knobs/0 returns subset for mixed workloads" do
      knobs = KnobSpace.mixed_knobs()
      assert is_map(knobs)
      assert map_size(knobs) > 0
    end

    test "all workload sets are subsets of full space" do
      all = KnobSpace.all()
      for knobs <- [KnobSpace.oltp_knobs(), KnobSpace.olap_knobs(), KnobSpace.mixed_knobs()] do
        for {name, _def} <- knobs do
          assert Map.has_key?(all, name), "#{name} should be in full knob space"
        end
      end
    end
  end

  describe "get/1 and get!/1" do
    test "get/1 returns knob definition" do
      assert {:continuous, 128.0, 16384.0} = KnobSpace.get(:shared_buffers)
      assert {:integer, 20, 500} = KnobSpace.get(:max_connections)
      assert {:categorical, ["off", "on", "try"]} = KnobSpace.get(:huge_pages)
    end

    test "get/1 returns nil for unknown knob" do
      assert nil == KnobSpace.get(:unknown_knob)
    end

    test "get!/1 returns knob definition" do
      assert {:continuous, _, _} = KnobSpace.get!(:shared_buffers)
    end

    test "get!/1 raises for unknown knob" do
      assert_raise KeyError, fn ->
        KnobSpace.get!(:unknown_knob)
      end
    end
  end

  describe "subset/1" do
    test "filters knobs by name list" do
      subset = KnobSpace.subset([:shared_buffers, :work_mem])
      assert map_size(subset) == 2
      assert Map.has_key?(subset, :shared_buffers)
      assert Map.has_key?(subset, :work_mem)
    end

    test "ignores unknown knob names" do
      subset = KnobSpace.subset([:shared_buffers, :unknown_knob])
      assert map_size(subset) == 1
      assert Map.has_key?(subset, :shared_buffers)
    end
  end

  describe "type/1" do
    test "returns :continuous for float knobs" do
      assert :continuous == KnobSpace.type(:shared_buffers)
      assert :continuous == KnobSpace.type(:work_mem)
    end

    test "returns :integer for integer knobs" do
      assert :integer == KnobSpace.type(:max_connections)
      assert :integer == KnobSpace.type(:wal_buffers)
    end

    test "returns :categorical for categorical knobs" do
      assert :categorical == KnobSpace.type(:huge_pages)
    end

    test "returns nil for unknown knob" do
      assert nil == KnobSpace.type(:unknown_knob)
    end
  end

  describe "bounds/1" do
    test "returns {min, max} for continuous knobs" do
      assert {128.0, 16384.0} = KnobSpace.bounds(:shared_buffers)
    end

    test "returns {min, max} for integer knobs" do
      assert {20, 500} = KnobSpace.bounds(:max_connections)
    end

    test "returns {0, num_choices - 1} for categorical knobs" do
      assert {0, 2} = KnobSpace.bounds(:huge_pages)
    end

    test "returns nil for unknown knob" do
      assert nil == KnobSpace.bounds(:unknown_knob)
    end
  end

  describe "choices/1" do
    test "returns choices for categorical knobs" do
      assert ["off", "on", "try"] = KnobSpace.choices(:huge_pages)
    end

    test "returns nil for non-categorical knobs" do
      assert nil == KnobSpace.choices(:shared_buffers)
      assert nil == KnobSpace.choices(:max_connections)
    end
  end

  describe "categorical?/1" do
    test "returns true for categorical knobs" do
      assert KnobSpace.categorical?(:huge_pages)
    end

    test "returns false for non-categorical knobs" do
      refute KnobSpace.categorical?(:shared_buffers)
      refute KnobSpace.categorical?(:max_connections)
    end
  end

  describe "categorical_knobs/1 and numeric_knobs/1" do
    test "categorical_knobs/1 filters to categorical only" do
      knobs = [:shared_buffers, :huge_pages, :max_connections]
      categorical = KnobSpace.categorical_knobs(knobs)
      assert categorical == [:huge_pages]
    end

    test "numeric_knobs/1 filters to non-categorical" do
      knobs = [:shared_buffers, :huge_pages, :max_connections]
      numeric = KnobSpace.numeric_knobs(knobs)
      assert :shared_buffers in numeric
      assert :max_connections in numeric
      refute :huge_pages in numeric
    end
  end

  describe "format_value/2" do
    test "formats memory params with MB suffix" do
      assert "4096MB" = KnobSpace.format_value(:shared_buffers, 4096.0)
      assert "64MB" = KnobSpace.format_value(:work_mem, 64.0)
      assert "256MB" = KnobSpace.format_value(:maintenance_work_mem, 256)
    end

    test "formats time params with ms suffix" do
      assert "200ms" = KnobSpace.format_value(:bgwriter_delay, 200)
    end

    test "formats floats as strings" do
      result = KnobSpace.format_value(:random_page_cost, 1.5)
      assert is_binary(result)
      assert String.contains?(result, "1.5")
    end

    test "formats integers as strings" do
      assert "100" = KnobSpace.format_value(:max_connections, 100)
    end

    test "passes through strings unchanged" do
      assert "off" = KnobSpace.format_value(:huge_pages, "off")
    end
  end

  describe "validate_config/1" do
    test "accepts valid config" do
      config = %{
        shared_buffers: 4096.0,
        work_mem: 64.0,
        max_connections: 100,
        huge_pages: "off"
      }
      assert :ok = KnobSpace.validate_config(config)
    end

    test "rejects out-of-range continuous value" do
      config = %{shared_buffers: 99999999.0}
      assert {:error, errors} = KnobSpace.validate_config(config)
      assert length(errors) == 1
      assert hd(errors) =~ "shared_buffers"
    end

    test "rejects out-of-range integer value" do
      config = %{max_connections: 10000}
      assert {:error, errors} = KnobSpace.validate_config(config)
      assert length(errors) == 1
    end

    test "rejects invalid categorical value" do
      config = %{huge_pages: "invalid"}
      assert {:error, errors} = KnobSpace.validate_config(config)
      assert length(errors) == 1
    end

    test "rejects unknown knob" do
      config = %{unknown_knob: 123}
      assert {:error, errors} = KnobSpace.validate_config(config)
      assert hd(errors) =~ "Unknown knob"
    end

    test "collects multiple errors" do
      config = %{
        shared_buffers: 99999999.0,
        max_connections: 10000,
        unknown_knob: 123
      }
      assert {:error, errors} = KnobSpace.validate_config(config)
      assert length(errors) == 3
    end
  end
end
