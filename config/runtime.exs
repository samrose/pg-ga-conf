import Config

if config_env() == :prod do
  instance_provider =
    case System.get_env("INSTANCE_PROVIDER", "local") do
      "supabase" -> PgGaConf.Adapters.SupabaseCloud
      _ -> PgGaConf.Adapters.LocalPostgres
    end

  config :pg_ga_conf,
    instance_provider: instance_provider,
    default_strategy: String.to_existing_atom(System.get_env("STRATEGY", "moderate")),
    default_generations: String.to_integer(System.get_env("GENERATIONS", "30")),
    default_population_size: String.to_integer(System.get_env("POPULATION_SIZE", "20")),
    default_parallel_instances: String.to_integer(System.get_env("PARALLEL_INSTANCES", "5"))
end
