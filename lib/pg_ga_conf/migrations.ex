defmodule PgGaConf.Migrations do
  @moduledoc """
  Migration helpers for PgGaConf tables.

  Usage in your application:

      # Generate migration:
      mix ecto.gen.migration add_pg_ga_conf_tables

      # In the migration file:
      defmodule MyApp.Repo.Migrations.AddPgGaConfTables do
        use Ecto.Migration

        def up, do: PgGaConf.Migrations.up()
        def down, do: PgGaConf.Migrations.down()
      end
  """

  use Ecto.Migration

  def up do
    # Observations table for transfer learning
    create table(:pg_ga_conf_observations) do
      add :db_id, :string, null: false
      add :config, :map, null: false
      add :score, :float, null: false
      add :metrics, :map
      add :workload_cluster, :string, null: false
      add :fingerprint_vector, {:array, :float}

      timestamps(type: :utc_datetime)
    end

    create index(:pg_ga_conf_observations, [:workload_cluster])
    create index(:pg_ga_conf_observations, [:db_id])

    # Sessions table for tuning state and history
    create table(:pg_ga_conf_sessions) do
      add :db_id, :string, null: false
      add :optimizer, :string, null: false
      add :status, :string, default: "initializing"

      # Checkpoint data
      add :optimizer_state, :binary
      add :current_iteration, :integer, default: 0
      add :max_iterations, :integer
      add :knobs_used, {:array, :string}

      # Results
      add :best_config, :map
      add :best_score, :float
      add :initial_score, :float
      add :improvement_pct, :float
      add :history, {:array, :map}

      # Error tracking
      add :last_error, :text
      add :error_count, :integer, default: 0
      add :consecutive_errors, :integer, default: 0

      # Metadata
      add :workload_cluster, :string
      add :fingerprint_vector, {:array, :float}

      timestamps(type: :utc_datetime)
    end

    create index(:pg_ga_conf_sessions, [:db_id])
    create index(:pg_ga_conf_sessions, [:status])

    # Sobol cache table
    create table(:pg_ga_conf_sobol_cache) do
      add :fingerprint, :binary, null: false
      add :workload_type, :string
      add :knob_names, {:array, :string}, null: false
      add :sensitivity_indices, :text, null: false
      add :samples_used, :integer
      add :analysis_duration_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:pg_ga_conf_sobol_cache, [:workload_type])
    create index(:pg_ga_conf_sobol_cache, [:knob_names])
  end

  def down do
    drop table(:pg_ga_conf_sobol_cache)
    drop table(:pg_ga_conf_sessions)
    drop table(:pg_ga_conf_observations)
  end
end
