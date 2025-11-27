import Config

config :logger, level: :info

config :pg_ga_conf,
  julia_mode: :tcp,
  julia_host: System.get_env("JULIA_SERVICE_HOST", "localhost"),
  julia_port: String.to_integer(System.get_env("JULIA_SERVICE_PORT", "9999"))
