import Config

config :logger, level: :debug

config :pg_ga_conf, PgGaConf.Repo,
  database: "pgga_dev",
  username: "postgres",
  password: "",
  hostname: "localhost",
  port: 5432,
  pool_size: 10

config :pg_ga_conf,
  # Development settings
  julia_mode: :local,
  max_iterations: 10,
  sobol_samples: 64,
  benchmark_duration: 10,

  # GA-specific settings (existing)
  instance_provider: PgGaConf.Instance.LocalPostgres,
  default_strategy: :moderate,
  default_generations: 10,
  default_population_size: 10,
  default_parallel_instances: 3
