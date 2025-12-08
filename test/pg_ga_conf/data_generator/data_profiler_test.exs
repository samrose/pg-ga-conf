defmodule PgGaConf.DataGenerator.DataProfilerTest do
  use ExUnit.Case, async: true

  alias PgGaConf.DataGenerator.DataProfiler

  describe "build_profile_from_pg_stats/1" do
    test "extracts basic stats" do
      pg_stats_row = %{
        tablename: "users",
        attname: "age",
        null_frac: 0.05,
        n_distinct: 80.0,
        most_common_vals: nil,
        most_common_freqs: nil,
        histogram_bounds: "{18,25,35,45,55,65,75,85,95}"
      }

      profile = DataProfiler.build_profile_from_pg_stats("public", pg_stats_row)

      assert profile.schema == "public"
      assert profile.table == "users"
      assert profile.column == "age"
      assert profile.null_percentage == 0.05
      assert profile.distinct_count == 80
      assert is_list(profile.histogram)
      assert length(profile.histogram) > 0
    end

    test "extracts most common values for low cardinality" do
      pg_stats_row = %{
        tablename: "orders",
        attname: "status",
        null_frac: 0.0,
        n_distinct: 3.0,
        most_common_vals: "{pending,active,closed}",
        most_common_freqs: "{0.5,0.3,0.2}",
        histogram_bounds: nil
      }

      profile = DataProfiler.build_profile_from_pg_stats("public", pg_stats_row)

      assert profile.pattern == :low_cardinality
      assert profile.sample_values == ["pending", "active", "closed"]
      assert profile.value_frequencies == [0.5, 0.3, 0.2]
    end

    test "handles nil histogram bounds" do
      pg_stats_row = %{
        tablename: "test",
        attname: "col",
        null_frac: 0.0,
        n_distinct: 100.0,
        most_common_vals: nil,
        most_common_freqs: nil,
        histogram_bounds: nil
      }

      profile = DataProfiler.build_profile_from_pg_stats("public", pg_stats_row)

      # No histogram key when bounds are nil
      refute Map.has_key?(profile, :histogram)
    end
  end

  describe "parse_pg_array/1" do
    test "parses string array" do
      result = DataProfiler.parse_pg_array("{foo,bar,baz}")
      assert result == ["foo", "bar", "baz"]
    end

    test "parses numeric array" do
      result = DataProfiler.parse_pg_array("{1,2,3}")
      assert result == ["1", "2", "3"]
    end

    test "parses float array" do
      result = DataProfiler.parse_pg_array("{0.5,0.3,0.2}")
      assert result == ["0.5", "0.3", "0.2"]
    end

    test "handles empty array" do
      result = DataProfiler.parse_pg_array("{}")
      assert result == []
    end

    test "handles nil" do
      result = DataProfiler.parse_pg_array(nil)
      assert result == nil
    end

    test "handles quoted values" do
      result = DataProfiler.parse_pg_array("{\"hello world\",\"foo bar\"}")
      assert result == ["hello world", "foo bar"]
    end
  end

  describe "histogram_to_buckets/1" do
    test "converts bounds to bucket frequencies" do
      # 5 bounds = 4 buckets, assume uniform distribution
      bounds = [10, 20, 30, 40, 50]

      buckets = DataProfiler.histogram_to_buckets(bounds)

      assert length(buckets) == 4
      assert Enum.sum(buckets) |> Float.round(2) == 1.0
    end

    test "handles two bounds (one bucket)" do
      bounds = [0, 100]
      buckets = DataProfiler.histogram_to_buckets(bounds)

      assert buckets == [1.0]
    end
  end

  describe "detect_pattern_from_sample/2" do
    test "detects email pattern" do
      samples = ["user@example.com", "test@gmail.com", "foo@bar.org"]
      column = %{data_type: "character varying"}

      pattern = DataProfiler.detect_pattern_from_sample(samples, column)

      assert pattern == :email
    end

    test "detects uuid pattern" do
      samples = [
        "550e8400-e29b-41d4-a716-446655440000",
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
      ]
      column = %{data_type: "character varying"}

      pattern = DataProfiler.detect_pattern_from_sample(samples, column)

      assert pattern == :uuid
    end

    test "returns nil for non-string types" do
      samples = [1, 2, 3]
      column = %{data_type: "integer"}

      pattern = DataProfiler.detect_pattern_from_sample(samples, column)

      assert pattern == nil
    end

    test "returns generic_text for unrecognized strings" do
      samples = ["abc", "def", "ghi"]
      column = %{data_type: "character varying"}

      pattern = DataProfiler.detect_pattern_from_sample(samples, column)

      assert pattern == :generic_text
    end
  end

  describe "extract_min_max/1" do
    test "extracts min/max from histogram bounds" do
      bounds = [10, 20, 30, 40, 50]

      {min, max} = DataProfiler.extract_min_max(bounds)

      assert min == 10
      assert max == 50
    end

    test "handles single bound" do
      bounds = [42]

      {min, max} = DataProfiler.extract_min_max(bounds)

      assert min == 42
      assert max == 42
    end

    test "handles date strings" do
      bounds = ["2020-01-01", "2024-12-31"]

      {min, max} = DataProfiler.extract_min_max(bounds)

      assert min == "2020-01-01"
      assert max == "2024-12-31"
    end
  end
end
