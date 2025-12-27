defmodule PgGaConf.Schema.WorkloadPattern do
  @moduledoc """
  Ecto schema for discovered workload patterns.

  Patterns are clusters of similar database profiles discovered via DBSCAN.
  Each pattern has a centroid vector and, once validated, a set of
  empirically validated knobs determined by Sobol sensitivity analysis.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pg_ga_conf_workload_patterns" do
    # Cluster geometry
    field :centroid_vector, {:array, :float}
    field :radius, :float
    field :member_count, :integer, default: 0

    # Sobol validation results (null until validated)
    field :validated_knobs, {:array, :string}
    field :sobol_indices, :map
    field :sobol_validated_at, :utc_datetime
    field :sobol_db_id, :string

    # Metadata
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields [:centroid_vector]
  @optional_fields [
    :radius,
    :member_count,
    :validated_knobs,
    :sobol_indices,
    :sobol_validated_at,
    :sobol_db_id,
    :description
  ]

  def changeset(pattern, attrs) do
    pattern
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:centroid_vector, is: 59)
  end

  @doc """
  Returns true if this pattern has been validated with Sobol analysis.
  """
  def validated?(%__MODULE__{validated_knobs: knobs}) when is_list(knobs) and length(knobs) > 0,
    do: true

  def validated?(_), do: false
end
