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

    # =========================================================================
    # Pattern Discovery Tables (Phase 2)
    # =========================================================================

    # Database profiles (time series of 59-feature profiles)
    create table(:pg_ga_conf_database_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :db_id, :string, null: false
      add :captured_at, :utc_datetime, null: false

      # Feature groups (for analysis/debugging)
      add :schema_features, :map
      add :query_features, :map
      add :execution_features, :map
      add :io_features, :map
      add :index_features, :map
      add :runtime_features, :map
      add :scale_features, :map

      # Normalized feature vector (59 floats)
      add :feature_vector, {:array, :float}, null: false

      # Metadata
      add :has_pg_stat_statements, :boolean, default: false
      add :pg_version, :integer
      add :profile_duration_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:pg_ga_conf_database_profiles, [:db_id])
    create index(:pg_ga_conf_database_profiles, [:captured_at])
    create unique_index(:pg_ga_conf_database_profiles, [:db_id, :captured_at])

    # Workload patterns (discovered clusters)
    create table(:pg_ga_conf_workload_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Cluster geometry
      add :centroid_vector, {:array, :float}, null: false
      add :radius, :float
      add :member_count, :integer, default: 0

      # Sobol validation results (null until validated)
      add :validated_knobs, {:array, :string}
      add :sobol_indices, :map
      add :sobol_validated_at, :utc_datetime
      add :sobol_db_id, :string

      # Metadata
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    # Database -> Pattern assignments
    create table(:pg_ga_conf_pattern_assignments, primary_key: false) do
      add :db_id, :string, primary_key: true
      add :pattern_id, references(:pg_ga_conf_workload_patterns, type: :binary_id, on_delete: :nilify_all)
      add :similarity, :float
      add :assigned_at, :utc_datetime

      # Database-specific validation (if no pattern match)
      add :custom_validated_knobs, {:array, :string}
      add :custom_sobol_indices, :map
      add :custom_validated_at, :utc_datetime
    end

    create index(:pg_ga_conf_pattern_assignments, [:pattern_id])
  end

  def down do
    drop_if_exists table(:pg_ga_conf_pattern_assignments)
    drop_if_exists table(:pg_ga_conf_workload_patterns)
    drop_if_exists table(:pg_ga_conf_database_profiles)
    drop table(:pg_ga_conf_sobol_cache)
    drop table(:pg_ga_conf_sessions)
    drop table(:pg_ga_conf_observations)
  end
end
