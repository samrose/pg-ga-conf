defmodule PgGaConf.DataGenerator.DataProfiler do
  @moduledoc """
  Extracts data profiles from PostgreSQL pg_stats and column sampling.

  Profiles include:
  - Distribution histograms for numeric columns
  - Pattern detection for string columns
  - Low-cardinality value lists
  - Null percentages
  """

  require Logger

  alias PgGaConf.Core.PatternDetector

  @string_types ["character varying", "varchar", "char", "character", "text"]
  @low_cardinality_threshold 100

  @doc """
  Profiles all columns in a database connection.
  Returns list of column profiles.
  """
  def profile_database(conn, tables, columns) do
    # First, get stats from pg_stats
    pg_stats = fetch_pg_stats(conn)

    # Build profiles from pg_stats
    profiles =
      Enum.flat_map(tables, fn table ->
        table_columns = Enum.filter(columns, &(&1.table == table.name && &1.schema == table.schema))

        Enum.map(table_columns, fn column ->
          stats = find_stats(pg_stats, table.schema, table.name, column.name)
          build_column_profile(conn, table, column, stats)
        end)
      end)

    profiles
  end

  defp fetch_pg_stats(conn) do
    case Postgrex.query(conn, """
      SELECT
        schemaname,
        tablename,
        attname,
        null_frac,
        n_distinct,
        most_common_vals::text,
        most_common_freqs::text,
        histogram_bounds::text
      FROM pg_stats
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, col, null_frac, n_distinct, mcv, mcf, hist] ->
          %{
            schemaname: schema,
            tablename: table,
            attname: col,
            null_frac: null_frac || 0.0,
            n_distinct: n_distinct || 0.0,
            most_common_vals: mcv,
            most_common_freqs: mcf,
            histogram_bounds: hist
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp find_stats(pg_stats, schema, table, column) do
    Enum.find(pg_stats, fn s ->
      s.schemaname == schema && s.tablename == table && s.attname == column
    end)
  end

  defp build_column_profile(conn, table, column, stats) do
    base_profile = %{
      schema: table.schema,
      table: table.name,
      column: column.name,
      data_type: column.data_type,
      null_percentage: if(stats, do: stats.null_frac, else: 0.0),
      distinct_count: if(stats, do: abs(stats.n_distinct), else: nil)
    }

    # Add type-specific profiling
    cond do
      # Low cardinality with most common values
      stats && stats.most_common_vals && stats.n_distinct > 0 && stats.n_distinct <= @low_cardinality_threshold ->
        values = parse_pg_array(stats.most_common_vals)
        freqs = parse_pg_array(stats.most_common_freqs) |> parse_floats()

        Map.merge(base_profile, %{
          pattern: :low_cardinality,
          sample_values: values,
          value_frequencies: freqs
        })

      # Numeric with histogram
      stats && stats.histogram_bounds && column.data_type in ["integer", "bigint", "smallint", "numeric", "real", "double precision"] ->
        bounds = parse_pg_array(stats.histogram_bounds) |> parse_numbers()
        {min, max} = extract_min_max(bounds)

        Map.merge(base_profile, %{
          min: min,
          max: max,
          histogram: histogram_to_buckets(bounds)
        })

      # Date/timestamp with histogram
      stats && stats.histogram_bounds && String.contains?(column.data_type, "timestamp") ->
        bounds = parse_pg_array(stats.histogram_bounds)
        {min_str, max_str} = extract_min_max(bounds)

        Map.merge(base_profile, %{
          min: parse_timestamp(min_str),
          max: parse_timestamp(max_str),
          histogram: histogram_to_buckets(bounds)
        })

      stats && stats.histogram_bounds && column.data_type == "date" ->
        bounds = parse_pg_array(stats.histogram_bounds)
        {min_str, max_str} = extract_min_max(bounds)

        Map.merge(base_profile, %{
          min: parse_date(min_str),
          max: parse_date(max_str),
          histogram: histogram_to_buckets(bounds)
        })

      # String columns - sample for pattern detection
      column.data_type in @string_types ->
        sample = sample_column(conn, table, column)
        pattern = detect_pattern_from_sample(sample, column)
        lengths = Enum.map(sample, &String.length/1)

        Map.merge(base_profile, %{
          pattern: pattern,
          min_length: if(lengths != [], do: Enum.min(lengths), else: 1),
          max_length: if(lengths != [], do: Enum.max(lengths), else: column[:char_max_length] || 100)
        })

      # Default - just basic stats
      true ->
        base_profile
    end
  end

  defp sample_column(conn, table, column) do
    query = """
      SELECT #{column.name}
      FROM #{table.schema}.#{table.name}
      TABLESAMPLE BERNOULLI(10)
      WHERE #{column.name} IS NOT NULL
      LIMIT 1000
    """

    case Postgrex.query(conn, query, []) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(&hd/1)
        |> Enum.filter(&is_binary/1)

      {:error, _} ->
        # Fallback without TABLESAMPLE
        fallback_query = """
          SELECT #{column.name}
          FROM #{table.schema}.#{table.name}
          WHERE #{column.name} IS NOT NULL
          LIMIT 1000
        """

        case Postgrex.query(conn, fallback_query, []) do
          {:ok, %{rows: rows}} ->
            rows |> Enum.map(&hd/1) |> Enum.filter(&is_binary/1)

          {:error, _} ->
            []
        end
    end
  end

  @doc """
  Builds a profile from a pg_stats row.
  """
  def build_profile_from_pg_stats(schema, stats) do
    base = %{
      schema: schema,
      table: stats.tablename,
      column: stats.attname,
      null_percentage: stats.null_frac || 0.0,
      distinct_count: if(stats.n_distinct, do: abs(stats.n_distinct) |> round(), else: nil)
    }

    cond do
      stats.most_common_vals && stats.n_distinct && stats.n_distinct <= @low_cardinality_threshold ->
        values = parse_pg_array(stats.most_common_vals)
        freqs = parse_pg_array(stats.most_common_freqs) |> parse_floats()

        Map.merge(base, %{
          pattern: :low_cardinality,
          sample_values: values,
          value_frequencies: freqs
        })

      stats.histogram_bounds ->
        bounds = parse_pg_array(stats.histogram_bounds)

        Map.merge(base, %{
          histogram: histogram_to_buckets(bounds)
        })

      true ->
        base
    end
  end

  @doc """
  Parses PostgreSQL array literal format.
  """
  def parse_pg_array(nil), do: nil
  def parse_pg_array("{}"), do: []

  def parse_pg_array(str) when is_binary(str) do
    str
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> split_pg_array_elements()
  end

  defp split_pg_array_elements(""), do: []

  defp split_pg_array_elements(str) do
    # Handle quoted strings and unquoted values
    str
    |> String.split(~r/,(?=(?:[^"]*"[^"]*")*[^"]*$)/)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&unquote_pg_value/1)
  end

  defp unquote_pg_value(str) do
    str
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp parse_floats(nil), do: nil

  defp parse_floats(list) when is_list(list) do
    Enum.map(list, fn
      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> 0.0
        end

      n when is_number(n) ->
        n / 1
    end)
  end

  defp parse_numbers(nil), do: nil

  defp parse_numbers(list) when is_list(list) do
    Enum.map(list, fn
      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> 0.0
        end

      n when is_number(n) ->
        n
    end)
  end

  @doc """
  Converts histogram bounds to bucket frequencies.
  Assumes uniform distribution within each bucket.
  """
  def histogram_to_buckets(nil), do: nil
  def histogram_to_buckets([]), do: nil
  def histogram_to_buckets([_single]), do: [1.0]

  def histogram_to_buckets(bounds) when is_list(bounds) do
    bucket_count = length(bounds) - 1
    freq = 1.0 / bucket_count

    List.duplicate(freq, bucket_count)
  end

  @doc """
  Detects string pattern from sample values.
  """
  def detect_pattern_from_sample(_samples, %{data_type: dt}) when dt not in @string_types do
    nil
  end

  def detect_pattern_from_sample([], _column), do: :generic_text

  def detect_pattern_from_sample(samples, _column) do
    PatternDetector.categorize_string_column(samples)
  end

  @doc """
  Extracts min and max from histogram bounds.
  """
  def extract_min_max([single]), do: {single, single}

  def extract_min_max(bounds) when is_list(bounds) do
    {List.first(bounds), List.last(bounds)}
  end

  defp parse_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str <> "Z") do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> Date.utc_today()
    end
  end

  defp parse_date(_), do: Date.utc_today()
end
