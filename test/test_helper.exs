# Start the application to initialize DBConnection and other services
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:pg_ga_conf)

ExUnit.start()
