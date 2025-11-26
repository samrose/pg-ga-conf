import Config

config :pg_ga_conf,
  ecto_repos: [],
  generators: [timestamp_type: :utc_datetime]

config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
