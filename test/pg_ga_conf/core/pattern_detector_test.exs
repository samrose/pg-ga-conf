defmodule PgGaConf.Core.PatternDetectorTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Core.PatternDetector

  describe "detect_string_patterns/1" do
    test "detects email pattern" do
      values = ["user@example.com", "test@gmail.com", "admin@company.org"]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:email, confidence} = List.keyfind(patterns, :email, 0)
      assert confidence > 0.9
    end

    test "detects UUID pattern" do
      values = [
        "550e8400-e29b-41d4-a716-446655440000",
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
      ]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:uuid, confidence} = List.keyfind(patterns, :uuid, 0)
      assert confidence > 0.9
    end

    test "detects URL pattern" do
      values = ["https://example.com", "http://test.org/path"]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:url, _} = List.keyfind(patterns, :url, 0)
    end

    test "detects phone pattern" do
      values = ["+1234567890", "+1987654321", "123-456-7890"]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:phone, _} = List.keyfind(patterns, :phone, 0)
    end

    test "detects JSON pattern" do
      values = [~s({"key": "value"}), ~s([1, 2, 3])]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:json, _} = List.keyfind(patterns, :json, 0)
    end
  end

  describe "categorize_string_column/1" do
    test "categorizes as email" do
      values = ["user@example.com", "test@gmail.com"]

      assert PatternDetector.categorize_string_column(values) == :email
    end

    test "categorizes as full_name" do
      values = ["John Smith", "Jane Doe", "Bob Johnson"]

      assert PatternDetector.categorize_string_column(values) == :full_name
    end

    test "categorizes as generic_text when no pattern matches" do
      values = ["random", "text", "here"]

      assert PatternDetector.categorize_string_column(values) == :generic_text
    end
  end
end
