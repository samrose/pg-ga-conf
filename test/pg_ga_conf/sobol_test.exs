defmodule PgGaConf.SobolTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Sobol
  alias PgGaConf.Test.Fixtures

  describe "filter_important/2" do
    test "filters knobs above threshold" do
      indices = Fixtures.sample_sensitivity_indices()
      important = Sobol.filter_important(indices, threshold: 0.10)

      assert :shared_buffers in important
      assert :work_mem in important
      refute :max_connections in important
      refute :huge_pages in important
    end

    test "uses default threshold of 0.05" do
      indices = Fixtures.sample_sensitivity_indices()
      important = Sobol.filter_important(indices)

      # All with ST >= 0.05 should be included
      assert :shared_buffers in important
      assert :work_mem in important
      assert :max_connections in important
      refute :huge_pages in important
    end

    test "returns top_k most important" do
      indices = Fixtures.sample_sensitivity_indices()
      important = Sobol.filter_important(indices, top_k: 2)

      assert length(important) == 2
      # Should be sorted by ST descending
      assert hd(important) == :shared_buffers
    end

    test "respects both threshold and top_k" do
      indices = Fixtures.sample_sensitivity_indices()
      important = Sobol.filter_important(indices, threshold: 0.05, top_k: 1)

      assert important == [:shared_buffers]
    end

    test "handles empty indices" do
      assert Sobol.filter_important(%{}) == []
    end

    test "handles all below threshold" do
      indices = %{
        knob1: %{s1: 0.01, st: 0.02},
        knob2: %{s1: 0.01, st: 0.01}
      }

      assert Sobol.filter_important(indices, threshold: 0.05) == []
    end
  end

  describe "reduce_knob_space/3" do
    test "returns subset of important knobs" do
      knob_space = Fixtures.sample_knob_space()
      indices = Fixtures.sample_sensitivity_indices()

      reduced = Sobol.reduce_knob_space(knob_space, indices, threshold: 0.10)

      assert Map.has_key?(reduced, :shared_buffers)
      assert Map.has_key?(reduced, :work_mem)
      refute Map.has_key?(reduced, :max_connections)
      refute Map.has_key?(reduced, :huge_pages)
    end

    test "preserves knob definitions" do
      knob_space = Fixtures.sample_knob_space()
      indices = Fixtures.sample_sensitivity_indices()

      reduced = Sobol.reduce_knob_space(knob_space, indices)

      assert reduced[:shared_buffers] == knob_space[:shared_buffers]
    end

    test "handles top_k option" do
      knob_space = Fixtures.sample_knob_space()
      indices = Fixtures.sample_sensitivity_indices()

      reduced = Sobol.reduce_knob_space(knob_space, indices, top_k: 1)

      assert map_size(reduced) == 1
      assert Map.has_key?(reduced, :shared_buffers)
    end
  end

  describe "quick_reduce/1" do
    test "returns OLTP knob set for :oltp" do
      knobs = Sobol.quick_reduce(:oltp)

      assert is_map(knobs)
      assert map_size(knobs) > 0
      # OLTP should include key knobs
      assert Map.has_key?(knobs, :shared_buffers)
    end

    test "returns OLAP knob set for :olap" do
      knobs = Sobol.quick_reduce(:olap)

      assert is_map(knobs)
      assert map_size(knobs) > 0
    end

    test "returns mixed knob set for :mixed" do
      knobs = Sobol.quick_reduce(:mixed)

      assert is_map(knobs)
      assert map_size(knobs) > 0
    end

    test "all quick_reduce results are subsets of full knob space" do
      full = PgGaConf.KnobSpace.all()

      for type <- [:oltp, :olap, :mixed] do
        reduced = Sobol.quick_reduce(type)

        for {name, _def} <- reduced do
          assert Map.has_key?(full, name),
                 "#{name} from #{type} knobs should be in full knob space"
        end
      end
    end
  end

  describe "sensitivity indices structure" do
    test "sample indices have correct structure" do
      indices = Fixtures.sample_sensitivity_indices()

      for {name, values} <- indices do
        assert is_atom(name)
        assert is_map(values)
        assert Map.has_key?(values, :s1)
        assert Map.has_key?(values, :st)
        assert is_number(values.s1)
        assert is_number(values.st)
        # Total order should be >= first order
        assert values.st >= values.s1
      end
    end

    test "sample indices sum appropriately" do
      indices = Fixtures.sample_sensitivity_indices()

      # First-order indices should sum close to 1 (or less due to interactions)
      s1_sum = indices |> Enum.map(fn {_, %{s1: s1}} -> s1 end) |> Enum.sum()
      assert s1_sum <= 1.0

      # Total-order indices can sum to more than 1 due to interactions
      st_sum = indices |> Enum.map(fn {_, %{st: st}} -> st end) |> Enum.sum()
      assert st_sum >= s1_sum
    end
  end

  describe "interaction detection" do
    test "gap between ST and S1 indicates interactions" do
      indices = Fixtures.sample_sensitivity_indices()

      for {name, %{s1: s1, st: st}} <- indices do
        gap = st - s1
        # Gap should be non-negative
        assert gap >= 0, "#{name}: ST should be >= S1"
      end
    end

    test "shared_buffers has notable interactions in sample" do
      indices = Fixtures.sample_sensitivity_indices()
      %{s1: s1, st: st} = indices[:shared_buffers]

      # Sample has ST 0.35 vs S1 0.25 = 0.10 gap
      gap = st - s1
      assert gap > 0.05, "shared_buffers should show interactions"
    end
  end

  describe "sorting by importance" do
    test "filter_important sorts by ST descending" do
      indices = %{
        knob_low: %{s1: 0.01, st: 0.06},
        knob_med: %{s1: 0.05, st: 0.15},
        knob_high: %{s1: 0.10, st: 0.30}
      }

      important = Sobol.filter_important(indices, threshold: 0.05)

      assert important == [:knob_high, :knob_med, :knob_low]
    end
  end
end
