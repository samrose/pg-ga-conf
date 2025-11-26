import Config

config :logger, level: :warning

config :pg_ga_conf,
  instance_provider: PgGaConf.Adapters.MockProvider,
  default_generations: 5,
  default_population_size: 5
