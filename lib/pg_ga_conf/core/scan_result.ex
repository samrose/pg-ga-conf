defmodule PgGaConf.Core.ScanResult do
  @moduledoc """
  Result of scanning a database.
  """

  defstruct [
    :roles,
    :schemas,
    :tables,
    :columns,
    :primary_keys,
    :foreign_keys,
    :unique_constraints,
    :check_constraints,
    :indexes,
    :sequences,
    :views,
    :functions,
    :triggers,
    :enums,
    :extensions,
    :data_profiles,
    :query_patterns,
    :scanned_at
  ]

  @type t :: %__MODULE__{
    roles: list(map()),
    schemas: list(map()),
    tables: list(map()),
    columns: list(map()),
    primary_keys: list(map()),
    foreign_keys: list(map()),
    unique_constraints: list(map()),
    check_constraints: list(map()),
    indexes: list(map()),
    sequences: list(map()),
    views: list(map()),
    functions: list(map()),
    triggers: list(map()),
    enums: list(map()),
    extensions: list(map()),
    data_profiles: list(map()),
    query_patterns: list(map()) | nil,
    scanned_at: DateTime.t()
  }

  def new(params \\ %{}) do
    params_with_timestamp = Map.put_new(params, :scanned_at, DateTime.utc_now())
    struct(__MODULE__, params_with_timestamp)
  end
end
