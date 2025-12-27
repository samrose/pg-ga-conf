defmodule PgGaConf.Schema.DatabaseProfile do
  @moduledoc """
  Ecto schema for storing database workload profiles over time.

  Each profile captures 59 normalized features across 7 layers,
  enabling pattern discovery and workload classification.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pg_ga_conf_database_profiles" do
    field :db_id, :string
    field :captured_at, :utc_datetime

    # Feature groups (for analysis/debugging)
    field :schema_features, :map
    field :query_features, :map
    field :execution_features, :map
    field :io_features, :map
    field :index_features, :map
    field :runtime_features, :map
    field :scale_features, :map

    # Normalized feature vector (59 floats)
    field :feature_vector, {:array, :float}

    # Metadata
    field :has_pg_stat_statements, :boolean, default: false
    field :pg_version, :integer
    field :profile_duration_ms, :integer

    timestamps(type: :utc_datetime)
  end

  @required_fields [:db_id, :feature_vector]
  @optional_fields [
    :captured_at,
    :schema_features,
    :query_features,
    :execution_features,
    :io_features,
    :index_features,
    :runtime_features,
    :scale_features,
    :has_pg_stat_statements,
    :pg_version,
    :profile_duration_ms
  ]

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:feature_vector, is: 59)
    |> put_captured_at()
  end

  defp put_captured_at(changeset) do
    if get_field(changeset, :captured_at) do
      changeset
    else
      put_change(changeset, :captured_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end
