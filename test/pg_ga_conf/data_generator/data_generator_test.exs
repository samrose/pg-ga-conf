defmodule PgGaConf.DataGenerator.DataGeneratorTest do
  use ExUnit.Case, async: true

  alias PgGaConf.DataGenerator.DataGenerator
  alias PgGaConf.Core.ScanResult

  describe "prepare_generation_plan/1" do
    test "returns tables in topological order" do
      scan_result = %ScanResult{
        tables: [
          %{name: "posts", schema: "public", row_count: 100},
          %{name: "users", schema: "public", row_count: 10}
        ],
        foreign_keys: [
          %{table: "posts", columns: ["user_id"], foreign_table: "users", foreign_columns: ["id"]}
        ],
        columns: [],
        primary_keys: [],
        unique_constraints: [],
        check_constraints: [],
        indexes: [],
        sequences: [],
        enums: [],
        extensions: [],
        schemas: [],
        data_profiles: []
      }

      {:ok, plan} = DataGenerator.prepare_generation_plan(scan_result)

      assert length(plan.tables) == 2
      [first, second] = plan.tables
      assert first.name == "users"
      assert second.name == "posts"
    end

    test "returns error on circular dependency" do
      scan_result = %ScanResult{
        tables: [
          %{name: "a", schema: "public", row_count: 10},
          %{name: "b", schema: "public", row_count: 10}
        ],
        foreign_keys: [
          %{table: "a", columns: ["b_id"], foreign_table: "b", foreign_columns: ["id"]},
          %{table: "b", columns: ["a_id"], foreign_table: "a", foreign_columns: ["id"]}
        ],
        columns: [],
        primary_keys: [],
        unique_constraints: [],
        check_constraints: [],
        indexes: [],
        sequences: [],
        enums: [],
        extensions: [],
        schemas: [],
        data_profiles: []
      }

      assert {:error, :circular_dependency} = DataGenerator.prepare_generation_plan(scan_result)
    end
  end

  describe "generate_row/3" do
    test "generates values for each column" do
      columns = [
        %{name: "id", table: "users", data_type: "integer", nullable: false},
        %{name: "name", table: "users", data_type: "character varying", char_max_length: 100, nullable: false},
        %{name: "email", table: "users", data_type: "character varying", char_max_length: 255, nullable: true}
      ]

      profiles = %{
        {"users", "id"} => %{pattern: nil, min: 1, max: 1000},
        {"users", "name"} => %{pattern: :full_name},
        {"users", "email"} => %{pattern: :email}
      }

      pk_cache = :ets.new(:test_pk_cache, [:set, :public])

      try do
        row = DataGenerator.generate_row("users", columns, profiles, pk_cache)

        assert is_map(row)
        assert is_integer(row["id"])
        assert is_binary(row["name"])
        assert is_binary(row["email"])
        assert String.contains?(row["email"], "@")
      after
        :ets.delete(pk_cache)
      end
    end

    test "generates FK reference from pk_cache" do
      columns = [
        %{name: "id", table: "posts", data_type: "integer", nullable: false},
        %{name: "user_id", table: "posts", data_type: "integer", nullable: false}
      ]

      profiles = %{
        {"posts", "id"} => %{pattern: nil, min: 1, max: 1000},
        {"posts", "user_id"} => %{pattern: :fk_reference, fk_table: "users", fk_column: "id"}
      }

      # Create ETS table and populate with user PKs
      pk_cache = :ets.new(:test_pk_cache, [:set, :public])
      :ets.insert(pk_cache, {{"users", "id"}, MapSet.new([1, 2, 3, 4, 5])})

      try do
        row = DataGenerator.generate_row("posts", columns, profiles, pk_cache)
        assert row["user_id"] in [1, 2, 3, 4, 5]
      after
        :ets.delete(pk_cache)
      end
    end

    test "handles nullable columns" do
      columns = [
        %{name: "bio", table: "users", data_type: "text", nullable: true}
      ]

      profiles = %{
        {"users", "bio"} => %{pattern: :generic_text, null_percentage: 1.0}
      }

      pk_cache = :ets.new(:test_pk_cache, [:set, :public])

      try do
        row = DataGenerator.generate_row("users", columns, profiles, pk_cache)
        assert row["bio"] == nil
      after
        :ets.delete(pk_cache)
      end
    end
  end

  describe "encode_csv_row/2" do
    test "encodes values for COPY format" do
      row = %{"id" => 1, "name" => "John Doe", "active" => true}
      columns = ["id", "name", "active"]

      csv = DataGenerator.encode_csv_row(row, columns)

      assert csv == "1\tJohn Doe\tt\n"
    end

    test "encodes nil as \\N" do
      row = %{"id" => 1, "name" => nil}
      columns = ["id", "name"]

      csv = DataGenerator.encode_csv_row(row, columns)

      assert csv == "1\t\\N\n"
    end

    test "escapes special characters" do
      row = %{"text" => "hello\tworld\ntest"}
      columns = ["text"]

      csv = DataGenerator.encode_csv_row(row, columns)

      assert csv == "hello\\tworld\\ntest\n"
    end

    test "encodes dates and timestamps" do
      row = %{
        "date" => ~D[2024-01-15],
        "timestamp" => ~U[2024-01-15 10:30:00Z]
      }
      columns = ["date", "timestamp"]

      csv = DataGenerator.encode_csv_row(row, columns)

      assert String.contains?(csv, "2024-01-15")
      assert String.contains?(csv, "10:30:00")
    end
  end

  describe "build_profiles_map/2" do
    test "creates lookup map from data_profiles" do
      data_profiles = [
        %{schema: "public", table: "users", column: "email", pattern: :email},
        %{schema: "public", table: "users", column: "age", min: 18, max: 100}
      ]

      columns = [
        %{name: "email", table: "users", schema: "public"},
        %{name: "age", table: "users", schema: "public"}
      ]

      profiles_map = DataGenerator.build_profiles_map(data_profiles, columns)

      assert profiles_map[{"users", "email"}].pattern == :email
      assert profiles_map[{"users", "age"}].min == 18
    end
  end
end
