defmodule PgGaConf.Schema.Observation do
  @moduledoc """
  Schema for storing individual optimization observations (config + score pairs).
  Used for transfer learning warm-start.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "pg_ga_conf_observations" do
    field :db_id, :string
    field :config, :map
    field :score, :float
    field :metrics, :map
    field :workload_cluster, :string
    field :fingerprint_vector, {:array, :float}

    timestamps(type: :utc_datetime)
  end

  @required_fields [:db_id, :config, :score, :workload_cluster]
  @optional_fields [:metrics, :fingerprint_vector]

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:score, greater_than_or_equal_to: 0)
  end
end
