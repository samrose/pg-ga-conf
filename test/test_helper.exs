# Configure ExUnit
ExUnit.start(exclude: [:integration])

# Test support files are loaded via elixirc_paths in mix.exs
# No need to require them manually

# Only start full application for integration tests
# Unit tests should not require external services
if System.get_env("INTEGRATION_TESTS") == "true" do
  {:ok, _} = Application.ensure_all_started(:postgrex)
  {:ok, _} = Application.ensure_all_started(:pg_ga_conf)
end
