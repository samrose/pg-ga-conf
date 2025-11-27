defmodule PgGaConf.Schema.SobolCache do
  @moduledoc """
  Schema for caching Sobol sensitivity analysis results.
  Cached by workload fingerprint to avoid re-running expensive analysis.

  Similar workloads (by fingerprint similarity) can reuse cached sensitivity indices.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "pg_ga_conf_sobol_cache" do
    field :fingerprint, :binary
    field :workload_type, :string
    field :knob_names, {:array, :string}
    field :sensitivity_indices, :string
    field :samples_used, :integer
    field :analysis_duration_ms, :integer

    timestamps(type: :utc_datetime)
  end

  @required_fields [:fingerprint, :knob_names, :sensitivity_indices]
  @optional_fields [:workload_type, :samples_used, :analysis_duration_ms]

  def changeset(cache, attrs) do
    cache
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:workload_type, ~w(oltp olap mixed))
    |> validate_number(:samples_used, greater_than: 0)
  end
end
