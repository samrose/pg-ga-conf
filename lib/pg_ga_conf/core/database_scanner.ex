defmodule PgGaConf.Core.DatabaseScanner do
  @moduledoc """
  Scans PostgreSQL databases to understand structure and data patterns.
  """

  require Logger

  alias PgGaConf.Core.ScanResult

  @doc """
  Performs a comprehensive scan of the database.
  """
  def scan_database(conn) do
    Logger.info("Starting comprehensive database scan...")

    ScanResult.new(%{
      roles: scan_roles(conn),
      extensions: scan_extensions(conn),
      enums: scan_enums(conn),
      schemas: scan_schemas(conn),
      sequences: scan_sequences(conn),
      tables: scan_tables_detailed(conn),
      columns: scan_columns_detailed(conn),
      primary_keys: scan_primary_keys(conn),
      foreign_keys: scan_foreign_keys(conn),
      unique_constraints: scan_unique_constraints(conn),
      check_constraints: scan_check_constraints(conn),
      indexes: scan_indexes_detailed(conn),
      views: scan_views(conn),
      functions: scan_functions(conn),
      triggers: scan_triggers(conn),
      data_profiles: [],  # Will implement in next task
      query_patterns: scan_query_patterns(conn)
    })
  end

  defp scan_roles(conn) do
    case Postgrex.query(conn, """
      SELECT rolname, rolsuper, rolcreatedb, rolcreaterole
      FROM pg_roles
      WHERE rolname NOT LIKE 'pg_%'
      ORDER BY rolname
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, super, createdb, createrole] ->
          %{
            name: name,
            superuser: super,
            createdb: createdb,
            createrole: createrole
          }
        end)
      {:error, _} -> []
    end
  end

  defp scan_extensions(conn) do
    case Postgrex.query(conn, """
      SELECT extname, extversion, extnamespace::regnamespace::text as schema
      FROM pg_extension
      ORDER BY extname
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, version, schema] ->
          %{name: name, version: version, schema: schema}
        end)
      {:error, _} -> []
    end
  end

  defp scan_enums(conn) do
    case Postgrex.query(conn, """
      SELECT
        n.nspname as schema,
        t.typname as name,
        array_agg(e.enumlabel ORDER BY e.enumsortorder) as values
      FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
      JOIN pg_enum e ON e.enumtypid = t.oid
      WHERE t.typtype = 'e'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      GROUP BY n.nspname, t.typname
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, values] ->
          %{schema: schema, name: name, values: values}
        end)
      {:error, _} -> []
    end
  end

  defp scan_schemas(conn) do
    case Postgrex.query(conn, """
      SELECT schema_name
      FROM information_schema.schemata
      WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY schema_name
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name] -> %{name: name} end)
      {:error, _} -> []
    end
  end

  defp scan_sequences(conn) do
    case Postgrex.query(conn, """
      SELECT
        schemaname as schema,
        sequencename as name,
        start_value,
        increment_by
      FROM pg_sequences
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, start, increment] ->
          %{schema: schema, name: name, start_value: start, increment_by: increment}
        end)
      {:error, _} -> []
    end
  end

  defp scan_tables_detailed(conn) do
    case Postgrex.query(conn, """
      SELECT
        n.nspname as schema_name,
        c.relname as table_name,
        c.oid as table_oid,
        obj_description(c.oid, 'pg_class') as comment,
        c.relkind,
        COALESCE(pg_stat_user_tables.n_live_tup, 0) as row_count,
        pg_total_relation_size(c.oid) as total_size
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_stat_user_tables
        ON pg_stat_user_tables.schemaname = n.nspname
        AND pg_stat_user_tables.relname = c.relname
      WHERE c.relkind IN ('r', 'p')
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY total_size DESC NULLS LAST
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, oid, comment, kind, rows, size] ->
          %{
            schema: schema,
            name: name,
            oid: oid,
            comment: comment,
            type: if(kind == "r", do: :regular, else: :partitioned),
            row_count: rows || 0,
            size_bytes: size || 0
          }
        end)
      {:error, error} ->
        Logger.warning("Failed to scan tables: #{inspect(error)}")
        []
    end
  end

  defp scan_columns_detailed(conn) do
    case Postgrex.query(conn, """
      SELECT
        c.table_schema,
        c.table_name,
        c.column_name,
        c.ordinal_position,
        c.column_default,
        c.is_nullable,
        c.data_type,
        c.udt_name,
        c.character_maximum_length,
        c.numeric_precision,
        c.numeric_scale,
        c.is_identity,
        c.identity_generation
      FROM information_schema.columns c
      WHERE c.table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY c.table_schema, c.table_name, c.ordinal_position
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, name, position, default, nullable,
                           data_type, udt_name, char_max, num_precision, num_scale,
                           is_identity, identity_gen] ->
          %{
            schema: schema,
            table: table,
            name: name,
            position: position,
            data_type: data_type,
            udt_name: udt_name,
            nullable: nullable == "YES",
            default: default,
            char_max_length: char_max,
            numeric_precision: num_precision,
            numeric_scale: num_scale,
            is_identity: is_identity == "YES",
            identity_generation: identity_gen
          }
        end)
      {:error, error} ->
        Logger.warning("Failed to scan columns: #{inspect(error)}")
        []
    end
  end

  defp scan_primary_keys(conn) do
    case Postgrex.query(conn, """
      SELECT
        connamespace::regnamespace::text as schema,
        conrelid::regclass::text as table_name,
        conname as constraint_name,
        array_agg(a.attname ORDER BY array_position(conkey, a.attnum)) as columns
      FROM pg_constraint
      JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = ANY(conkey)
      WHERE contype = 'p'
        AND connamespace::regnamespace::text NOT IN ('pg_catalog', 'information_schema')
      GROUP BY schema, table_name, constraint_name
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, name, columns] ->
          %{schema: schema, table: parse_table_name(table), name: name, columns: columns}
        end)
      {:error, _} -> []
    end
  end

  defp scan_foreign_keys(conn) do
    case Postgrex.query(conn, """
      SELECT
        conname as constraint_name,
        connamespace::regnamespace::text as schema_name,
        conrelid::regclass::text as table_name,
        array_agg(a.attname ORDER BY array_position(conkey, a.attnum)) as columns,
        confrelid::regclass::text as foreign_table,
        array_agg(af.attname ORDER BY array_position(confkey, af.attnum)) as foreign_columns,
        confupdtype as update_action,
        confdeltype as delete_action
      FROM pg_constraint
      JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = ANY(conkey)
      JOIN pg_attribute af ON af.attrelid = confrelid AND af.attnum = ANY(confkey)
      WHERE contype = 'f'
        AND connamespace::regnamespace::text NOT IN ('pg_catalog', 'information_schema')
      GROUP BY conname, schema_name, table_name, foreign_table, update_action, delete_action
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, schema, table, columns, foreign_table, foreign_columns, update, delete] ->
          %{
            name: name,
            schema: schema,
            table: parse_table_name(table),
            columns: columns,
            foreign_table: parse_table_name(foreign_table),
            foreign_columns: foreign_columns,
            on_update: decode_fk_action(update),
            on_delete: decode_fk_action(delete)
          }
        end)
      {:error, _} -> []
    end
  end

  defp scan_unique_constraints(conn) do
    case Postgrex.query(conn, """
      SELECT
        conname as constraint_name,
        connamespace::regnamespace::text as schema_name,
        conrelid::regclass::text as table_name,
        array_agg(a.attname ORDER BY array_position(conkey, a.attnum)) as columns
      FROM pg_constraint
      JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = ANY(conkey)
      WHERE contype = 'u'
        AND connamespace::regnamespace::text NOT IN ('pg_catalog', 'information_schema')
      GROUP BY conname, schema_name, table_name
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, schema, table, columns] ->
          %{name: name, schema: schema, table: parse_table_name(table), columns: columns}
        end)
      {:error, _} -> []
    end
  end

  defp scan_check_constraints(conn) do
    case Postgrex.query(conn, """
      SELECT
        conname as constraint_name,
        connamespace::regnamespace::text as schema_name,
        conrelid::regclass::text as table_name,
        pg_get_constraintdef(oid) as definition
      FROM pg_constraint
      WHERE contype = 'c'
        AND connamespace::regnamespace::text NOT IN ('pg_catalog', 'information_schema')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, schema, table, definition] ->
          %{name: name, schema: schema, table: parse_table_name(table), definition: definition}
        end)
      {:error, _} -> []
    end
  end

  defp scan_indexes_detailed(conn) do
    case Postgrex.query(conn, """
      SELECT
        schemaname as schema,
        tablename as table_name,
        indexname as index_name,
        indexdef as definition
      FROM pg_indexes
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY schemaname, tablename, indexname
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, name, definition] ->
          %{schema: schema, table: table, name: name, definition: definition}
        end)
      {:error, _} -> []
    end
  end

  defp scan_views(conn) do
    case Postgrex.query(conn, """
      SELECT
        schemaname as schema,
        viewname as name,
        definition
      FROM pg_views
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, definition] ->
          %{schema: schema, name: name, definition: definition}
        end)
      {:error, _} -> []
    end
  end

  defp scan_functions(conn) do
    case Postgrex.query(conn, """
      SELECT
        n.nspname as schema,
        p.proname as name,
        pg_get_functiondef(p.oid) as definition
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      ORDER BY schema, name
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, definition] ->
          %{schema: schema, name: name, definition: definition}
        end)
      {:error, _} -> []
    end
  end

  defp scan_triggers(conn) do
    case Postgrex.query(conn, """
      SELECT
        event_object_schema as schema,
        event_object_table as table_name,
        trigger_name as name,
        action_timing as timing,
        event_manipulation as event
      FROM information_schema.triggers
      WHERE event_object_schema NOT IN ('pg_catalog', 'information_schema')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, name, timing, event] ->
          %{schema: schema, table: table, name: name, timing: timing, event: event}
        end)
      {:error, _} -> []
    end
  end

  defp scan_query_patterns(conn) do
    case Postgrex.query(conn, """
      SELECT
        query,
        calls,
        total_exec_time / calls as avg_time_ms,
        mean_exec_time as mean_time_ms,
        rows as total_rows
      FROM pg_stat_statements
      WHERE query NOT LIKE '%pg_stat_statements%'
      ORDER BY calls DESC
      LIMIT 100
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [query, calls, avg_time, mean_time, total_rows] ->
          %{
            query: query,
            calls: calls,
            avg_time_ms: avg_time,
            mean_time_ms: mean_time,
            total_rows: total_rows
          }
        end)
      {:error, _} ->
        Logger.info("pg_stat_statements not available, skipping query pattern analysis")
        nil
    end
  end

  # Helper functions

  defp decode_fk_action(code) do
    case code do
      "a" -> "NO ACTION"
      "r" -> "RESTRICT"
      "c" -> "CASCADE"
      "n" -> "SET NULL"
      "d" -> "SET DEFAULT"
      _ -> "NO ACTION"
    end
  end

  defp parse_table_name(full_name) do
    # Remove schema prefix if present (e.g., "public.books" -> "books")
    case String.split(full_name, ".", parts: 2) do
      [_, table_name] -> table_name
      [table_name] -> table_name
    end
  end
end
