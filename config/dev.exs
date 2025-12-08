import Config

config :logger, level: :debug

# App database (port 5432) - for application state, never restarted
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

  # Target database (port 5433) - for tuning benchmarks, may be restarted
  target_db_port: 5433,
  target_db_host: "localhost",
  target_db_user: "postgres",
  target_db_password: "",
  target_db_name: "pgga_target",
  target_pgdata: nil,  # Will use PGDATA_TARGET env var

  # GA-specific settings (existing)
  instance_provider: PgGaConf.Instance.LocalPostgres,
  default_strategy: :moderate,
  default_generations: 10,
  default_population_size: 10,
  default_parallel_instances: 3
