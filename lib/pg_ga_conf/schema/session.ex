defmodule PgGaConf.Schema.Session do
  @moduledoc """
  Schema for storing tuning session state and history.
  Supports checkpointing for crash recovery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(initializing running paused completed failed stopped)

  schema "pg_ga_conf_sessions" do
    field :db_id, :string
    field :optimizer, :string
    field :status, :string, default: "initializing"

    # Checkpoint data
    field :optimizer_state, :binary
    field :current_iteration, :integer, default: 0
    field :max_iterations, :integer
    field :knobs_used, {:array, :string}

    # Results
    field :best_config, :map
    field :best_score, :float
    field :initial_score, :float
    field :improvement_pct, :float
    field :history, {:array, :map}

    # Error tracking
    field :last_error, :string
    field :error_count, :integer, default: 0
    field :consecutive_errors, :integer, default: 0

    # Metadata
    field :workload_cluster, :string
    field :fingerprint_vector, {:array, :float}

    timestamps(type: :utc_datetime)
  end

  @required_fields [:db_id, :optimizer]
  @optional_fields [
    :status,
    :optimizer_state,
    :current_iteration,
    :max_iterations,
    :knobs_used,
    :best_config,
    :best_score,
    :initial_score,
    :improvement_pct,
    :history,
    :last_error,
    :error_count,
    :consecutive_errors,
    :workload_cluster,
    :fingerprint_vector
  ]

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:optimizer, ~w(ga tpe cma_es))
    |> validate_number(:current_iteration, greater_than_or_equal_to: 0)
    |> validate_number(:max_iterations, greater_than: 0)
  end

  def statuses, do: @statuses
end
