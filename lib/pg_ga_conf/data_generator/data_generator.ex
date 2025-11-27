defmodule PgGaConf.DataGenerator.DataGenerator do
  @moduledoc """
  Orchestrates synthetic data generation from ScanResult to target database.

  Workflow:
  1. Topologically sort tables by FK dependencies
  2. Create schema DDL in target database
  3. Generate synthetic data for each table using COPY protocol
  4. Enable FK constraints and run ANALYZE
  """

  require Logger

  alias PgGaConf.Core.ScanResult
  alias PgGaConf.DataGenerator.{DependencyGraph, SchemaBuilder, ValueGenerator}

  @default_batch_size 50_000

  @doc """
  Generates synthetic data in target database based on scan result.

  ## Options
    * `:scale` - Scale factor for row counts (default: 1.0)
    * `:batch_size` - Rows per COPY transaction (default: 50,000)
    * `:progress_fn` - Callback for progress updates
    * `:skip_tables` - Tables to exclude
    * `:only_tables` - Only generate these tables
  """
  def generate(%ScanResult{} = scan_result, target_conn, opts \\ []) do
    with {:ok, plan} <- prepare_generation_plan(scan_result, opts) do
      # Create schema
      :ok = create_schema(target_conn, plan)

      # Generate data for each table in order
      pk_cache = :ets.new(:pk_cache, [:set, :public])

      try do
        Enum.each(plan.tables, fn table ->
          generate_table_data(target_conn, table, plan, pk_cache, opts)
        end)

        # Finalize
        finalize(target_conn)

        {:ok, %{tables_generated: length(plan.tables)}}
      after
        :ets.delete(pk_cache)
      end
    end
  end

  @doc """
  Prepares generation plan with tables in topological order.
  """
  def prepare_generation_plan(%ScanResult{} = scan_result, opts \\ []) do
    tables = filter_tables(scan_result.tables || [], opts)

    case DependencyGraph.topological_sort(tables, scan_result.foreign_keys || []) do
      {:error, :circular_dependency} = error ->
        error

      sorted_tables ->
        {:ok,
         %{
           tables: sorted_tables,
           columns: scan_result.columns || [],
           primary_keys: scan_result.primary_keys || [],
           foreign_keys: scan_result.foreign_keys || [],
           unique_constraints: scan_result.unique_constraints || [],
           check_constraints: scan_result.check_constraints || [],
           indexes: scan_result.indexes || [],
           sequences: scan_result.sequences || [],
           enums: scan_result.enums || [],
           extensions: scan_result.extensions || [],
           schemas: scan_result.schemas || [],
           data_profiles: scan_result.data_profiles || [],
           profiles_map: build_profiles_map(scan_result.data_profiles || [], scan_result.columns || [])
         }}
    end
  end

  defp filter_tables(tables, opts) do
    skip = opts[:skip_tables] || []
    only = opts[:only_tables]

    tables
    |> Enum.reject(&(&1.name in skip))
    |> then(fn tables ->
      if only, do: Enum.filter(tables, &(&1.name in only)), else: tables
    end)
  end

  @doc """
  Creates schema in target database from plan.
  """
  def create_schema(conn, plan) do
    scan_result = %ScanResult{
      tables: plan.tables,
      columns: plan.columns,
      primary_keys: plan.primary_keys,
      foreign_keys: [],
      unique_constraints: plan.unique_constraints,
      check_constraints: plan.check_constraints,
      indexes: [],
      sequences: plan.sequences,
      enums: plan.enums,
      extensions: plan.extensions,
      schemas: plan.schemas
    }

    ddl_statements = SchemaBuilder.build_all(scan_result)

    Enum.each(ddl_statements, fn sql ->
      if sql && String.trim(sql) != "" do
        case Postgrex.query(conn, sql, []) do
          {:ok, _} -> :ok
          {:error, error} -> Logger.warning("DDL failed: #{sql} - #{inspect(error)}")
        end
      end
    end)

    :ok
  end

  @doc """
  Generates data for a single table using COPY protocol.
  """
  def generate_table_data(conn, table, plan, pk_cache, opts) do
    scale = opts[:scale] || 1.0
    batch_size = opts[:batch_size] || @default_batch_size
    progress_fn = opts[:progress_fn]

    row_count = round(table.row_count * scale)
    table_columns = Enum.filter(plan.columns, &(&1.table == table.name))
    column_names = Enum.map(table_columns, & &1.name)

    # Find PK column for this table
    pk_info = Enum.find(plan.primary_keys, &(&1.table == table.name))
    pk_columns = if pk_info, do: pk_info.columns, else: []

    if progress_fn do
      progress_fn.("Generating #{row_count} rows for #{table.name}")
    end

    # Generate in batches
    1..row_count
    |> Stream.chunk_every(batch_size)
    |> Enum.each(fn batch_range ->
      generate_batch(conn, table, table_columns, column_names, pk_columns, plan.profiles_map, pk_cache, batch_range)
    end)

    :ok
  end

  defp generate_batch(conn, table, columns, column_names, pk_columns, profiles_map, pk_cache, batch_range) do
    # Generate all rows first
    rows =
      Enum.map(batch_range, fn _i ->
        row = generate_row(table.name, columns, profiles_map, pk_cache)

        # Track PK values
        Enum.each(pk_columns, fn pk_col ->
          if pk_value = row[pk_col] do
            key = {table.name, pk_col}
            existing = :ets.lookup(pk_cache, key)

            case existing do
              [{^key, set}] ->
                :ets.insert(pk_cache, {key, MapSet.put(set, pk_value)})

              [] ->
                :ets.insert(pk_cache, {key, MapSet.new([pk_value])})
            end
          end
        end)

        row
      end)

    # Build COPY data
    copy_data =
      rows
      |> Enum.map(&encode_csv_row(&1, column_names))
      |> Enum.join()

    # Use COPY with data
    column_list = Enum.join(column_names, ", ")

    Postgrex.transaction(conn, fn conn ->
      # Create temp table data and insert via COPY
      copy_sql = "COPY #{table.schema}.#{table.name} (#{column_list}) FROM STDIN"

      case Postgrex.query(conn, copy_sql, [], copy_data: copy_data) do
        {:ok, _} -> :ok
        {:error, error} -> Logger.warning("COPY failed: #{inspect(error)}")
      end
    end)
  end

  @doc """
  Generates a single row of data for a table.
  """
  def generate_row(table_name, columns, profiles_map, pk_cache) do
    Map.new(columns, fn column ->
      profile = Map.get(profiles_map, {table_name, column.name}, %{})
      value = generate_value(column, profile, pk_cache)
      {column.name, value}
    end)
  end

  defp generate_value(column, profile, pk_cache) do
    # Check null first
    null_pct = profile[:null_percentage] || 0.0

    if column[:nullable] != false and null_pct > 0 and :rand.uniform() < null_pct do
      nil
    else
      do_generate_value(column, profile, pk_cache)
    end
  end

  defp do_generate_value(column, profile, pk_cache) do
    case profile[:pattern] do
      :fk_reference ->
        generate_fk_reference(profile[:fk_table], profile[:fk_column], pk_cache)

      :email ->
        ValueGenerator.generate_email()

      :uuid ->
        ValueGenerator.generate_uuid()

      :phone ->
        ValueGenerator.generate_phone()

      :url ->
        ValueGenerator.generate_url()

      :full_name ->
        ValueGenerator.generate_name()

      :first_name ->
        ValueGenerator.generate_first_name()

      :generic_text ->
        min_len = profile[:min_length] || 10
        max_len = profile[:max_length] || 100
        ValueGenerator.generate_text(min_len, max_len)

      :low_cardinality ->
        ValueGenerator.generate_from_values(profile[:sample_values], profile[:value_frequencies])

      _ ->
        generate_by_type(column, profile)
    end
  end

  defp generate_by_type(column, profile) do
    data_type = column.data_type || column[:udt_name]
    histogram = profile[:histogram]

    case data_type do
      t when t in ["integer", "int4", "smallint", "int2", "bigint", "int8"] ->
        min = profile[:min] || 1
        max = profile[:max] || 1_000_000
        ValueGenerator.generate_integer(min, max, histogram)

      t when t in ["numeric", "decimal"] ->
        min = profile[:min] || 0.0
        max = profile[:max] || 10000.0
        scale = column[:numeric_scale] || 2
        ValueGenerator.generate_decimal(min, max, histogram, scale)

      t when t in ["real", "float4", "double precision", "float8"] ->
        min = profile[:min] || 0.0
        max = profile[:max] || 10000.0
        ValueGenerator.generate_float(min, max, histogram, 4)

      t when t in ["character varying", "varchar", "char", "character", "text"] ->
        min_len = profile[:min_length] || 5
        max_len = profile[:max_length] || column[:char_max_length] || 100
        ValueGenerator.generate_text(min_len, max_len)

      "boolean" ->
        true_pct = profile[:true_percentage] || 0.5
        ValueGenerator.generate_boolean(0.0, true_pct)

      "date" ->
        min = profile[:min] || ~D[2020-01-01]
        max = profile[:max] || Date.utc_today()
        ValueGenerator.generate_date(min, max, histogram)

      t when t in ["timestamp without time zone", "timestamp", "timestamp with time zone", "timestamptz"] ->
        min = profile[:min] || ~U[2020-01-01 00:00:00Z]
        max = profile[:max] || DateTime.utc_now()
        ValueGenerator.generate_timestamp(min, max, histogram)

      "uuid" ->
        ValueGenerator.generate_uuid()

      t when t in ["json", "jsonb"] ->
        ValueGenerator.generate_json(:object)

      _ ->
        # Fallback to text
        ValueGenerator.generate_text(5, 50)
    end
  end

  defp generate_fk_reference(fk_table, fk_column, pk_cache) do
    key = {fk_table, fk_column}

    case :ets.lookup(pk_cache, key) do
      [{^key, set}] when set != %MapSet{} ->
        set |> MapSet.to_list() |> Enum.random()

      _ ->
        # No parent values yet, generate placeholder
        1
    end
  end

  @doc """
  Encodes a row map to COPY format (tab-delimited with newline).
  """
  def encode_csv_row(row, columns) do
    values =
      Enum.map(columns, fn col ->
        encode_value(row[col])
      end)

    Enum.join(values, "\t") <> "\n"
  end

  defp encode_value(nil), do: "\\N"
  defp encode_value(true), do: "t"
  defp encode_value(false), do: "f"
  defp encode_value(%Date{} = d), do: Date.to_iso8601(d)
  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp encode_value(value) when is_map(value) do
    Jason.encode!(value) |> escape_copy_string()
  end

  defp encode_value(value) when is_list(value) do
    Jason.encode!(value) |> escape_copy_string()
  end

  defp encode_value(value) when is_binary(value) do
    escape_copy_string(value)
  end

  defp encode_value(value) do
    to_string(value)
  end

  defp escape_copy_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\t", "\\t")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
  end

  @doc """
  Builds lookup map from data_profiles list.
  """
  def build_profiles_map(data_profiles, _columns) do
    Map.new(data_profiles, fn profile ->
      key = {profile.table, profile.column}
      {key, profile}
    end)
  end

  defp finalize(conn) do
    # Run ANALYZE to update statistics
    case Postgrex.query(conn, "ANALYZE", []) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
end
