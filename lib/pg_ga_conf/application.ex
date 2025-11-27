defmodule PgGaConf.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Don't start children during unit tests
    if Application.get_env(:pg_ga_conf, :start_app, true) == false do
      opts = [strategy: :one_for_one, name: PgGaConf.Supervisor]
      Supervisor.start_link([], opts)
    else
      children = [
        # Ecto Repo for persistence
        PgGaConf.Repo,

        # Task supervisor for parallel operations
        {Task.Supervisor, name: PgGaConf.TaskSupervisor},

        # Registry for tuning jobs
        {Registry, keys: :unique, name: PgGaConf.JobRegistry},

        # Dynamic supervisor for tuning jobs (legacy GA)
        {DynamicSupervisor, name: PgGaConf.TuningSupervisor, strategy: :one_for_one},

        # Dynamic supervisor for new tuning jobs (unified optimizer)
        {DynamicSupervisor, name: PgGaConf.TuningJobSupervisor, strategy: :one_for_one},

        # ETS table for fitness caching (GA)
        {PgGaConf.FitnessCache, []},

        # Job storage for web API (legacy)
        {PgGaConf.JobStorage, []},

        # Julia client (started conditionally based on config)
        julia_child_spec(),

        # Session recovery (auto-resume paused sessions)
        PgGaConf.SessionRecovery
      ]
      |> Enum.reject(&is_nil/1)

      opts = [strategy: :one_for_one, name: PgGaConf.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end

  defp julia_child_spec do
    mode = Application.get_env(:pg_ga_conf, :julia_mode, :auto)

    case mode do
      :mock -> nil
      _ -> {PgGaConf.Julia, []}
    end
  end
end
