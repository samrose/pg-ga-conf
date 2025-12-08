defmodule PgGaConf.Benchmark.Custom do
  @moduledoc """
  Custom benchmark implementation using user-provided functions.

  Allows running arbitrary workloads while still using the tuning system.

  ## Usage

  ```elixir
  {:ok, runner} = PgGaConf.Benchmark.Custom.init(
    db_url: "postgres://...",
    run_fn: fn conn ->
      # Your benchmark code
      {:ok, score, metrics}
    end,
    apply_config_fn: fn conn, config ->
      # Your config application code
      :ok
    end
  )
  ```
  """

  @behaviour PgGaConf.Benchmark

  require Logger

  defstruct [
    :db_url,
    :conn,
    :run_fn,
    :apply_config_fn,
    :reset_fn,
    :cleanup_fn
  ]

  @impl true
  def init(opts) do
    db_url = Keyword.fetch!(opts, :db_url)
    run_fn = Keyword.fetch!(opts, :run_fn)
    apply_config_fn = Keyword.get(opts, :apply_config_fn, &default_apply_config/2)
    reset_fn = Keyword.get(opts, :reset_fn)
    cleanup_fn = Keyword.get(opts, :cleanup_fn)

    # Connect to database
    case Postgrex.start_link(parse_db_url(db_url)) do
      {:ok, conn} ->
        state = %__MODULE__{
          db_url: db_url,
          conn: conn,
          run_fn: run_fn,
          apply_config_fn: apply_config_fn,
          reset_fn: reset_fn,
          cleanup_fn: cleanup_fn
        }

        {:ok, state}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  @impl true
  def run(%__MODULE__{} = state) do
    Logger.info("Running custom benchmark")

    case state.run_fn.(state.conn) do
      {:ok, score, metrics} when is_number(score) ->
        {:ok, score, metrics}

      {:ok, score} when is_number(score) ->
        {:ok, score, %{}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_run_result, other}}
    end
  rescue
    e ->
      {:error, {:benchmark_error, Exception.message(e)}}
  end

  @impl true
  def apply_config(%__MODULE__{} = state, config) do
    Logger.info("Applying config via custom function")

    case state.apply_config_fn.(state.conn, config) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      {:error, {:apply_config_error, Exception.message(e)}}
  end

  @impl true
  def reset(%__MODULE__{reset_fn: nil}), do: :ok

  def reset(%__MODULE__{} = state) do
    Logger.info("Resetting via custom function")

    case state.reset_fn.(state.conn) do
      :ok -> :ok
      {:error, reason} -> {:error, {:reset_error, reason}}
    end
  rescue
    e ->
      {:error, {:reset_error, Exception.message(e)}}
  end

  @impl true
  def cleanup(%__MODULE__{cleanup_fn: nil, conn: conn}) do
    GenServer.stop(conn)
    :ok
  end

  def cleanup(%__MODULE__{} = state) do
    case state.cleanup_fn.(state.conn) do
      :ok -> :ok
      _ -> :ok
    end

    GenServer.stop(state.conn)
    :ok
  rescue
    _ -> :ok
  end

  # Private functions

  defp default_apply_config(conn, config) do
    # Generate ALTER SYSTEM commands
    Enum.each(config, fn {param, value} ->
      sql = "ALTER SYSTEM SET #{param} = '#{format_value(value)}'"

      case Postgrex.query(conn, sql, []) do
        {:ok, _} -> :ok
        {:error, reason} -> throw({:alter_failed, param, reason})
      end
    end)

    # Reload config
    case Postgrex.query(conn, "SELECT pg_reload_conf()", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:reload_failed, reason}}
    end
  catch
    {:alter_failed, param, reason} ->
      {:error, {:alter_failed, param, reason}}
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)

  defp parse_db_url(url) do
    uri = URI.parse(url)

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: get_username(uri),
      password: get_password(uri),
      database: get_database(uri)
    ]
  end

  defp get_username(uri) do
    case uri.userinfo do
      nil -> "postgres"
      info -> info |> String.split(":") |> hd()
    end
  end

  defp get_password(uri) do
    case uri.userinfo do
      nil -> nil
      info -> info |> String.split(":") |> Enum.at(1)
    end
  end

  defp get_database(uri) do
    case uri.path do
      nil -> "postgres"
      "/" <> db -> db
      path -> path
    end
  end
end
