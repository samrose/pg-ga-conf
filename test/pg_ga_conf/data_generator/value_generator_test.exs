defmodule PgGaConf.DataGenerator.ValueGeneratorTest do
  use ExUnit.Case, async: true

  alias PgGaConf.DataGenerator.ValueGenerator

  describe "generate_integer/3" do
    test "generates integer within bounds" do
      for _ <- 1..100 do
        value = ValueGenerator.generate_integer(1, 100, nil)
        assert is_integer(value)
        assert value >= 1 and value <= 100
      end
    end

    test "generates from histogram distribution" do
      # Histogram with 5 buckets, heavily weighted toward first bucket
      histogram = [0.8, 0.05, 0.05, 0.05, 0.05]

      values = for _ <- 1..1000, do: ValueGenerator.generate_integer(0, 100, histogram)

      # Most values should be in first bucket (0-20)
      low_bucket_count = Enum.count(values, &(&1 < 20))
      assert low_bucket_count > 600, "Expected most values in first bucket"
    end

    test "handles single value range" do
      value = ValueGenerator.generate_integer(42, 42, nil)
      assert value == 42
    end
  end

  describe "generate_float/4" do
    test "generates float within bounds" do
      for _ <- 1..100 do
        value = ValueGenerator.generate_float(0.0, 100.0, nil, 2)
        assert is_float(value)
        assert value >= 0.0 and value <= 100.0
      end
    end

    test "respects precision" do
      value = ValueGenerator.generate_float(0.0, 100.0, nil, 2)
      # Should have at most 2 decimal places
      [_int, decimal] = value |> Float.to_string() |> String.split(".")
      assert String.length(decimal) <= 2
    end
  end

  describe "generate_date/3" do
    test "generates date within bounds" do
      min = ~D[2020-01-01]
      max = ~D[2024-12-31]

      for _ <- 1..100 do
        value = ValueGenerator.generate_date(min, max, nil)
        assert %Date{} = value
        assert Date.compare(value, min) in [:gt, :eq]
        assert Date.compare(value, max) in [:lt, :eq]
      end
    end
  end

  describe "generate_timestamp/3" do
    test "generates timestamp within bounds" do
      min = ~U[2020-01-01 00:00:00Z]
      max = ~U[2024-12-31 23:59:59Z]

      for _ <- 1..100 do
        value = ValueGenerator.generate_timestamp(min, max, nil)
        assert %DateTime{} = value
        assert DateTime.compare(value, min) in [:gt, :eq]
        assert DateTime.compare(value, max) in [:lt, :eq]
      end
    end
  end

  describe "generate_email/0" do
    test "generates valid email format" do
      for _ <- 1..100 do
        email = ValueGenerator.generate_email()
        assert String.contains?(email, "@")
        assert String.match?(email, ~r/^[a-z0-9._]+@[a-z]+\.[a-z]{2,}$/)
      end
    end

    test "generates unique emails" do
      emails = for _ <- 1..100, do: ValueGenerator.generate_email()
      unique = Enum.uniq(emails)
      # Should have very high uniqueness
      assert length(unique) > 95
    end
  end

  describe "generate_uuid/0" do
    test "generates valid UUID format" do
      for _ <- 1..100 do
        uuid = ValueGenerator.generate_uuid()
        assert String.match?(uuid, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
      end
    end
  end

  describe "generate_phone/0" do
    test "generates phone number format" do
      for _ <- 1..10 do
        phone = ValueGenerator.generate_phone()
        assert String.match?(phone, ~r/^\+1\d{10}$/)
      end
    end
  end

  describe "generate_name/0" do
    test "generates name-like string" do
      for _ <- 1..100 do
        name = ValueGenerator.generate_name()
        assert is_binary(name)
        assert String.length(name) > 0
        # Should start with capital letter
        assert String.match?(name, ~r/^[A-Z]/)
      end
    end
  end

  describe "generate_text/2" do
    test "generates text within length bounds" do
      for _ <- 1..100 do
        text = ValueGenerator.generate_text(10, 50)
        len = String.length(text)
        assert len >= 10 and len <= 50
      end
    end

    test "handles zero min length" do
      text = ValueGenerator.generate_text(0, 10)
      assert String.length(text) <= 10
    end
  end

  describe "generate_from_values/2" do
    test "samples from provided values" do
      values = ["active", "pending", "closed"]
      frequencies = [0.6, 0.3, 0.1]

      results = for _ <- 1..1000, do: ValueGenerator.generate_from_values(values, frequencies)

      # All results should be from values
      assert Enum.all?(results, &(&1 in values))

      # Distribution should roughly match frequencies
      active_count = Enum.count(results, &(&1 == "active"))
      assert active_count > 400 and active_count < 800
    end

    test "handles uniform distribution" do
      values = ["a", "b", "c"]
      frequencies = nil

      results = for _ <- 1..300, do: ValueGenerator.generate_from_values(values, frequencies)

      # Each value should appear roughly equally
      for v <- values do
        count = Enum.count(results, &(&1 == v))
        assert count > 50, "Expected #{v} to appear more often"
      end
    end
  end

  describe "generate_boolean/2" do
    test "respects true percentage" do
      results = for _ <- 1..1000, do: ValueGenerator.generate_boolean(0.0, 0.8)

      true_count = Enum.count(results, &(&1 == true))

      # Should be roughly 80% true
      assert true_count > 700 and true_count < 900
    end

    test "handles null percentage" do
      results = for _ <- 1..1000, do: ValueGenerator.generate_boolean(0.5, 0.5)

      nil_count = Enum.count(results, &is_nil/1)

      # Should be roughly 50% nil
      assert nil_count > 400 and nil_count < 600
    end
  end

  describe "generate_json/1" do
    test "generates valid JSON object" do
      json = ValueGenerator.generate_json(:object)
      assert is_map(json)
    end

    test "generates valid JSON array" do
      json = ValueGenerator.generate_json(:array)
      assert is_list(json)
    end
  end

  describe "weighted_random/1" do
    test "selects index based on weights" do
      weights = [0.9, 0.05, 0.05]

      results = for _ <- 1..1000, do: ValueGenerator.weighted_random(weights)

      # Most should be index 0
      zero_count = Enum.count(results, &(&1 == 0))
      assert zero_count > 800
    end
  end
end
