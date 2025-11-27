defmodule PgGaConf.Repo do
  use Ecto.Repo,
    otp_app: :pg_ga_conf,
    adapter: Ecto.Adapters.Postgres
end
