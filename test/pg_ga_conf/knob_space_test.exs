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

  # ============================================================================
  # Archetype-based knob selection tests
  # ============================================================================

  describe "archetypes/0" do
    test "returns all archetype names" do
      archetypes = KnobSpace.archetypes()

      assert is_list(archetypes)
      assert :high_concurrency_oltp in archetypes
      assert :read_heavy_oltp in archetypes
      assert :write_heavy_oltp in archetypes
      assert :update_heavy_oltp in archetypes
      assert :analytical in archetypes
      assert :mixed_htap in archetypes
      assert :batch_etl in archetypes
      assert :idle_or_unknown in archetypes
    end
  end

  describe "for_archetype/1" do
    test "returns knob list for each archetype" do
      for archetype <- KnobSpace.archetypes() do
        knobs = KnobSpace.for_archetype(archetype)
        assert is_list(knobs), "#{archetype} should return a list"
        assert length(knobs) > 0, "#{archetype} should have at least one knob"
        assert Enum.all?(knobs, &is_atom/1), "#{archetype} knobs should be atoms"
      end
    end

    test "analytical archetype has parallelism knobs" do
      knobs = KnobSpace.for_archetype(:analytical)

      assert :max_parallel_workers_per_gather in knobs
      assert :max_parallel_workers in knobs
      assert :work_mem in knobs
      assert :jit in knobs
    end

    test "write_heavy_oltp has WAL knobs" do
      knobs = KnobSpace.for_archetype(:write_heavy_oltp)

      assert :wal_buffers in knobs
      assert :max_wal_size in knobs
      assert :checkpoint_completion_target in knobs
      assert :synchronous_commit in knobs
    end

    test "update_heavy_oltp has autovacuum knobs" do
      knobs = KnobSpace.for_archetype(:update_heavy_oltp)

      assert :autovacuum_vacuum_scale_factor in knobs
      assert :autovacuum_vacuum_cost_limit in knobs
      assert :maintenance_work_mem in knobs
    end

    test "high_concurrency_oltp has connection knobs" do
      knobs = KnobSpace.for_archetype(:high_concurrency_oltp)

      assert :max_connections in knobs
      assert :shared_buffers in knobs
      assert :commit_delay in knobs
    end

    test "returns idle_or_unknown for unknown archetype" do
      knobs = KnobSpace.for_archetype(:nonexistent_archetype)
      expected = KnobSpace.for_archetype(:idle_or_unknown)

      assert knobs == expected
    end
  end

  describe "space_for_archetype/1" do
    test "returns knob space map for archetype" do
      space = KnobSpace.space_for_archetype(:analytical)

      assert is_map(space)
      assert Map.has_key?(space, :work_mem)
      assert Map.has_key?(space, :max_parallel_workers_per_gather)

      # Verify it contains definitions, not just names
      assert {:continuous, _, _} = space[:work_mem]
    end

    test "all returned knobs are valid" do
      all_knobs = KnobSpace.all()

      for archetype <- KnobSpace.archetypes() do
        space = KnobSpace.space_for_archetype(archetype)

        for {knob, _def} <- space do
          assert Map.has_key?(all_knobs, knob),
                 "#{archetype} includes invalid knob #{knob}"
        end
      end
    end
  end

  describe "archetype_knob_counts/0" do
    test "returns count for each archetype" do
      counts = KnobSpace.archetype_knob_counts()

      assert is_map(counts)

      for archetype <- KnobSpace.archetypes() do
        assert Map.has_key?(counts, archetype)
        assert is_integer(counts[archetype])
        assert counts[archetype] > 0
      end
    end

    test "analytical has more knobs than idle" do
      counts = KnobSpace.archetype_knob_counts()

      assert counts[:analytical] > counts[:idle_or_unknown]
    end
  end

  describe "new knobs added for archetypes" do
    test "synchronous_commit is available" do
      assert {:categorical, choices} = KnobSpace.get(:synchronous_commit)
      assert "on" in choices
      assert "off" in choices
    end

    test "commit_delay is available" do
      assert {:integer, min, max} = KnobSpace.get(:commit_delay)
      assert min >= 0
      assert max > min
    end

    test "jit is available" do
      assert {:categorical, choices} = KnobSpace.get(:jit)
      assert "on" in choices
      assert "off" in choices
    end

    test "hash_mem_multiplier is available" do
      assert {:continuous, min, max} = KnobSpace.get(:hash_mem_multiplier)
      assert min >= 1.0
      assert max > min
    end

    test "checkpoint_timeout is available" do
      assert {:integer, min, max} = KnobSpace.get(:checkpoint_timeout)
      assert min > 0
      assert max > min
    end

    test "autovacuum_naptime is available" do
      assert {:integer, min, max} = KnobSpace.get(:autovacuum_naptime)
      assert min >= 1
      assert max > min
    end
  end
end
