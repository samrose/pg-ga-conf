import Config

config :logger, level: :warning

# Don't start application during unit tests
config :pg_ga_conf, start_app: false

config :pg_ga_conf, PgGaConf.Repo,
  database: "pgga_test#{System.get_env("MIX_TEST_PARTITION")}",
  username: "postgres",
  password: "",
  hostname: "localhost",
  port: 5432,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :pg_ga_conf,
  # Test settings
  julia_mode: :mock,
  max_iterations: 5,
  sobol_samples: 16,
  benchmark_duration: 1,

  # GA-specific settings (existing)
  instance_provider: PgGaConf.Instance.MockProvider,
  default_generations: 5,
  default_population_size: 5
