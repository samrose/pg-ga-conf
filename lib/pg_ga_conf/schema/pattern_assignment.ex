defmodule PgGaConf.Schema.PatternAssignment do
  @moduledoc """
  Ecto schema for database-to-pattern assignments.

  Tracks which workload pattern each database belongs to, along with
  similarity score. Databases without a good pattern match can have
  custom validated knobs from direct Sobol analysis.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:db_id, :string, []}
  @foreign_key_type :binary_id

  schema "pg_ga_conf_pattern_assignments" do
    belongs_to :pattern, PgGaConf.Schema.WorkloadPattern, type: :binary_id
    field :similarity, :float
    field :assigned_at, :utc_datetime

    # Database-specific validation (if no pattern match)
    field :custom_validated_knobs, {:array, :string}
    field :custom_sobol_indices, :map
    field :custom_validated_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false, inserted_at: false)
  end

  @required_fields [:db_id]
  @optional_fields [
    :pattern_id,
    :similarity,
    :assigned_at,
    :custom_validated_knobs,
    :custom_sobol_indices,
    :custom_validated_at
  ]

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:similarity, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> put_assigned_at()
  end

  defp put_assigned_at(changeset) do
    if get_change(changeset, :pattern_id) || get_change(changeset, :custom_validated_knobs) do
      put_change(changeset, :assigned_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      changeset
    end
  end

  @doc """
  Returns the knobs to use for this database.

  Prefers pattern validated knobs, falls back to custom validated knobs.
  """
  def get_knobs(%__MODULE__{pattern: %{validated_knobs: knobs}}) when is_list(knobs) and length(knobs) > 0 do
    {:pattern, knobs}
  end

  def get_knobs(%__MODULE__{custom_validated_knobs: knobs}) when is_list(knobs) and length(knobs) > 0 do
    {:custom, knobs}
  end

  def get_knobs(_), do: {:none, []}
end
