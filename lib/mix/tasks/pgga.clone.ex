defmodule Mix.Tasks.Pgga.Clone do
  @moduledoc """
  Clone a PostgreSQL database schema and generate synthetic data.

  ## Usage

      mix pgga.clone SOURCE_URL TARGET_URL [options]

  ## Examples

      # Clone with same data volume
      mix pgga.clone postgres://localhost/production postgres://localhost:5433/tuning

      # Clone at 10% scale for quick testing
      mix pgga.clone postgres://localhost/production postgres://localhost:5433/tuning --scale 0.1

      # Clone specific tables only
      mix pgga.clone postgres://localhost/production postgres://localhost:5433/tuning --only users,orders

  ## Options

      --scale FLOAT     Scale factor for row counts (default: 1.0)
      --skip TABLES     Comma-separated tables to skip
      --only TABLES     Comma-separated tables to include (exclusive)
      --no-profile      Skip data profiling (faster but less accurate)
      --batch-size INT  Rows per COPY transaction (default: 50000)

  """

  use Mix.Task

  @shortdoc "Clone database schema and generate synthetic data"

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:postgrex)

    {opts, positional, _} = OptionParser.parse(args,
      strict: [
        scale: :float,
        skip: :string,
        only: :string,
        no_profile: :boolean,
        batch_size: :integer,
        help: :boolean
      ],
      aliases: [s: :scale, h: :help]
    )

    if opts[:help] || length(positional) < 2 do
      Mix.shell().info(@moduledoc)
      System.halt(if opts[:help], do: 0, else: 1)
    end

    [source_url, target_url | _] = positional

    clone_opts = [
      scale: opts[:scale] || 1.0,
      profile_data: !opts[:no_profile],
      batch_size: opts[:batch_size] || 50_000,
      skip_tables: parse_table_list(opts[:skip]),
      only_tables: parse_table_list(opts[:only]),
      progress_fn: &Mix.shell().info/1
    ]

    Mix.shell().info("Cloning database...")
    Mix.shell().info("  Source: #{source_url}")
    Mix.shell().info("  Target: #{target_url}")
    Mix.shell().info("  Scale: #{clone_opts[:scale]}")
    Mix.shell().info("")

    # Connect to source
    {:ok, source_conn} = Postgrex.start_link(parse_url(source_url))

    # Connect to target
    {:ok, target_conn} = Postgrex.start_link(parse_url(target_url))

    case PgGaConf.generate(source_conn, target_conn, clone_opts) do
      {:ok, result} ->
        Mix.shell().info("")
        Mix.shell().info("✓ Clone complete!")
        Mix.shell().info("  Tables generated: #{result[:tables_generated]}")

      {:error, reason} ->
        Mix.shell().error("Clone failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp parse_table_list(nil), do: nil
  defp parse_table_list(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_url(url) do
    uri = URI.parse(url)
    userinfo = uri.userinfo || ""
    [username, password] = case String.split(userinfo, ":") do
      [u, p] -> [u, p]
      [u] -> [u, ""]
      [] -> ["postgres", ""]
    end

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: username,
      password: password,
      database: String.trim_leading(uri.path || "/postgres", "/")
    ]
  end
end
