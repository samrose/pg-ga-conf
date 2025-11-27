import Config

if config_env() == :prod do
  # Database configuration
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :pg_ga_conf, PgGaConf.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Julia service configuration
  config :pg_ga_conf,
    julia_mode: :tcp,
    julia_host: System.get_env("JULIA_SERVICE_HOST", "localhost"),
    julia_port: String.to_integer(System.get_env("JULIA_SERVICE_PORT", "9999"))

  # Optimization defaults from environment
  if max_iter = System.get_env("MAX_ITERATIONS") do
    config :pg_ga_conf, max_iterations: String.to_integer(max_iter)
  end

  if optimizer = System.get_env("DEFAULT_OPTIMIZER") do
    config :pg_ga_conf, default_optimizer: String.to_existing_atom(optimizer)
  end

  # Legacy GA settings
  instance_provider =
    case System.get_env("INSTANCE_PROVIDER", "local") do
      "supabase" -> PgGaConf.Instance.SupabaseCloud
      _ -> PgGaConf.Instance.LocalPostgres
    end

  config :pg_ga_conf,
    instance_provider: instance_provider,
    default_strategy: String.to_existing_atom(System.get_env("STRATEGY", "moderate")),
    default_generations: String.to_integer(System.get_env("GENERATIONS", "30")),
    default_population_size: String.to_integer(System.get_env("POPULATION_SIZE", "20")),
    default_parallel_instances: String.to_integer(System.get_env("PARALLEL_INSTANCES", "5"))
end
