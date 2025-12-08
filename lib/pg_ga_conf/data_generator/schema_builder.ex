defmodule PgGaConf.DataGenerator.SchemaBuilder do
  @moduledoc """
  Builds DDL statements from ScanResult data to recreate schema in target database.
  """

  @doc """
  Generates CREATE TABLE statement from table and columns info.
  """
  def build_create_table(table, columns) do
    table_columns = Enum.filter(columns, &(&1.table == table.name))

    column_defs =
      table_columns
      |> Enum.sort_by(& &1[:position])
      |> Enum.map(&column_definition/1)
      |> Enum.join(",\n  ")

    """
    CREATE TABLE #{table.schema}.#{table.name} (
      #{column_defs}
    )
    """
    |> String.trim()
  end

  @doc """
  Formats a single column definition.
  """
  def column_definition(column) do
    parts = [
      column.name,
      format_data_type(column),
      if(column[:nullable] == false, do: "NOT NULL"),
      if(column[:default], do: "DEFAULT #{column[:default]}")
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_data_type(column) do
    base_type = column.data_type

    cond do
      # USER-DEFINED types (enums, composite types) - use the actual type name
      base_type == "USER-DEFINED" and column[:udt_name] ->
        column[:udt_name]

      # Character types with length
      base_type in ["character varying", "varchar", "char", "character"] and column[:char_max_length] ->
        "#{base_type}(#{column[:char_max_length]})"

      # Numeric with precision and scale
      base_type in ["numeric", "decimal"] and column[:numeric_precision] ->
        if column[:numeric_scale] do
          "#{base_type}(#{column[:numeric_precision]},#{column[:numeric_scale]})"
        else
          "#{base_type}(#{column[:numeric_precision]})"
        end

      # ARRAY types - use udt_name which has the proper array notation
      base_type == "ARRAY" and column[:udt_name] ->
        # udt_name for arrays is like "_int4", convert to "integer[]"
        element_type = String.trim_leading(column[:udt_name], "_")
        "#{element_type}[]"

      # Types without modifiers
      true ->
        base_type
    end
  end

  @doc """
  Generates ALTER TABLE ADD PRIMARY KEY statement.
  """
  def build_primary_key(pk) do
    columns = Enum.join(pk.columns, ", ")
    "ALTER TABLE #{pk.table} ADD CONSTRAINT #{pk.name} PRIMARY KEY (#{columns})"
  end

  @doc """
  Generates ALTER TABLE ADD FOREIGN KEY statement.
  """
  def build_foreign_key(fk) do
    columns = Enum.join(fk.columns, ", ")
    foreign_columns = Enum.join(fk.foreign_columns, ", ")

    """
    ALTER TABLE #{fk.table} ADD CONSTRAINT #{fk.name} \
    FOREIGN KEY (#{columns}) REFERENCES #{fk.foreign_table}(#{foreign_columns}) \
    ON DELETE #{fk.on_delete} ON UPDATE #{fk.on_update}
    """
    |> String.replace("\n", "")
    |> String.replace("\\", "")
    |> String.trim()
  end

  @doc """
  Generates ALTER TABLE ADD UNIQUE statement.
  """
  def build_unique_constraint(constraint) do
    columns = Enum.join(constraint.columns, ", ")
    "ALTER TABLE #{constraint.table} ADD CONSTRAINT #{constraint.name} UNIQUE (#{columns})"
  end

  @doc """
  Returns the index definition (already complete DDL from pg_indexes).
  """
  def build_index(index) do
    index.definition
  end

  @doc """
  Generates CREATE SEQUENCE statement.
  """
  def build_sequence(sequence) do
    """
    CREATE SEQUENCE #{sequence.schema}.#{sequence.name} \
    START WITH #{sequence.start_value} INCREMENT BY #{sequence.increment_by}
    """
    |> String.replace("\n", "")
    |> String.replace("\\", "")
    |> String.trim()
  end

  @doc """
  Generates CREATE TYPE ... AS ENUM statement.
  """
  def build_enum(enum) do
    values =
      enum.values
      |> Enum.map(&"'#{&1}'")
      |> Enum.join(", ")

    "CREATE TYPE #{enum.schema}.#{enum.name} AS ENUM (#{values})"
  end

  @doc """
  Generates CHECK constraint statement.
  """
  def build_check_constraint(constraint) do
    "ALTER TABLE #{constraint.table} ADD CONSTRAINT #{constraint.name} #{constraint.definition}"
  end

  @doc """
  Builds all schema DDL in correct order from ScanResult.
  Returns list of SQL statements.
  """
  def build_all(scan_result) do
    ddl = []

    # 1. Extensions
    ddl = ddl ++ Enum.map(scan_result.extensions || [], &build_extension/1)

    # 2. Schemas
    ddl = ddl ++ Enum.map(scan_result.schemas || [], &build_schema/1)

    # 3. Enums (before tables that might use them)
    ddl = ddl ++ Enum.map(scan_result.enums || [], &build_enum/1)

    # 4. Sequences
    ddl = ddl ++ Enum.map(scan_result.sequences || [], &build_sequence/1)

    # 5. Tables (without constraints initially)
    ddl =
      ddl ++
        Enum.map(scan_result.tables || [], fn table ->
          build_create_table(table, scan_result.columns || [])
        end)

    # 6. Primary keys
    ddl = ddl ++ Enum.map(scan_result.primary_keys || [], &build_primary_key/1)

    # 7. Unique constraints
    ddl = ddl ++ Enum.map(scan_result.unique_constraints || [], &build_unique_constraint/1)

    # 8. Foreign keys (after all tables exist)
    ddl = ddl ++ Enum.map(scan_result.foreign_keys || [], &build_foreign_key/1)

    # 9. Check constraints
    ddl = ddl ++ Enum.map(scan_result.check_constraints || [], &build_check_constraint/1)

    # 10. Indexes (after tables and constraints)
    ddl = ddl ++ Enum.map(scan_result.indexes || [], &build_index/1)

    ddl
  end

  defp build_extension(ext) do
    "CREATE EXTENSION IF NOT EXISTS #{ext.name}"
  end

  defp build_schema(schema) do
    if schema.name == "public" do
      nil
    else
      "CREATE SCHEMA IF NOT EXISTS #{schema.name}"
    end
  end
end
