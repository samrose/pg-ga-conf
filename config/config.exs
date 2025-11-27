import Config

# Ecto configuration
config :pg_ga_conf,
  ecto_repos: [PgGaConf.Repo]

# Logger configuration
config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

# Default tuning parameters
config :pg_ga_conf,
  # Default optimizer (:ga, :tpe, :cma_es)
  default_optimizer: :tpe,
  max_iterations: 30,

  # Benchmark defaults
  benchmark_duration: 60,
  benchmark_clients: 10,
  warmup_duration: 10,

  # Sobol defaults
  sobol_samples: 128,
  sobol_cache_ttl: :timer.hours(24 * 30),

  # Error handling
  max_consecutive_errors: 3,
  error_backoff_ms: 5_000,

  # Julia connection
  julia_mode: :auto,
  julia_host: "localhost",
  julia_port: 9999,
  julia_health_check_interval: 30_000

# Phoenix JSON encoder
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
