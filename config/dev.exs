import Config

config :logger, level: :debug

config :pg_ga_conf,
  instance_provider: PgGaConf.Adapters.LocalPostgres,
  default_strategy: :moderate,
  default_generations: 10,
  default_population_size: 10,
  default_parallel_instances: 3
