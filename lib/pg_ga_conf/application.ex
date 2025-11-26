defmodule PgGaConf.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Task supervisor for parallel operations
      {Task.Supervisor, name: PgGaConf.TaskSupervisor},

      # ETS table for fitness caching
      {PgGaConf.FitnessCache, []},

      # Job storage for web API
      {PgGaConf.JobStorage, []}
    ]

    opts = [strategy: :one_for_one, name: PgGaConf.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
