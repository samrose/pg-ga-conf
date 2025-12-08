defmodule PgGaConf.MixProject do
  use Mix.Project

  def project do
    [
      app: :pg_ga_conf,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {PgGaConf.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Database
      {:postgrex, "~> 0.17"},
      {:ecto_sql, "~> 3.11"},
      {:db_connection, "~> 2.5"},

      # JSON
      {:jason, "~> 1.4"},

      # UUID generation
      {:elixir_uuid, "~> 1.2"},

      # HTTP client for cloud APIs
      {:req, "~> 0.4"},

      # Statistics
      {:statistics, "~> 0.6"},

      # Phoenix for web service
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.6"},
      {:cors_plug, "~> 3.0"},

      # Telemetry
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Python integration for Optuna (TPE, CMA-ES)
      {:pythonx, "~> 0.4"},

      # External process management for Julia
      {:erlexec, "~> 2.2"},

      # Testing
      {:ex_unit_notifier, "~> 1.3", only: :test},
      {:mix_test_watch, "~> 1.1", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # Unit tests don't need database - use test.integration for full tests
      test: ["test"],
      "test.integration": ["ecto.create --quiet", "ecto.migrate --quiet", "test --include integration"]
    ]
  end
end
