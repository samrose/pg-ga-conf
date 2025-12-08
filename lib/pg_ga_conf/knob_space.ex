defmodule PgGaConf.KnobSpace do
  @moduledoc """
  PostgreSQL configuration knob definitions and reduced knob sets.

  Defines the full knob space (~27 tunable parameters) and predefined
  reduced sets for different workload types (OLTP, OLAP, Mixed).
  """

  @type knob_type :: :continuous | :integer | :categorical
  @type knob_def ::
          {:continuous, min :: float(), max :: float()}
          | {:integer, min :: integer(), max :: integer()}
          | {:categorical, choices :: [String.t()]}

  # Full knob space - all tunable PostgreSQL parameters (without restart)
  @full_knobs %{
    # Memory settings (in MB)
    shared_buffers: {:continuous, 128.0, 16384.0},
    work_mem: {:continuous, 4.0, 2048.0},
    maintenance_work_mem: {:continuous, 64.0, 4096.0},
    effective_cache_size: {:continuous, 512.0, 65536.0},
    huge_pages: {:categorical, ["off", "on", "try"]},

    # WAL settings
    wal_buffers: {:integer, 4, 256},
    checkpoint_completion_target: {:continuous, 0.5, 0.9},
    max_wal_size: {:integer, 1024, 16384},
    min_wal_size: {:integer, 80, 2048},

    # Planner settings
    random_page_cost: {:continuous, 1.0, 4.0},
    seq_page_cost: {:continuous, 0.5, 2.0},
    cpu_tuple_cost: {:continuous, 0.001, 0.05},
    cpu_index_tuple_cost: {:continuous, 0.001, 0.02},
    effective_io_concurrency: {:integer, 1, 200},
    default_statistics_target: {:integer, 50, 500},

    # Parallelism settings
    max_parallel_workers_per_gather: {:integer, 0, 8},
    max_parallel_workers: {:integer, 2, 16},
    max_parallel_maintenance_workers: {:integer, 0, 8},
    parallel_tuple_cost: {:continuous, 0.001, 0.1},
    parallel_setup_cost: {:continuous, 100.0, 10000.0},

    # Autovacuum settings
    autovacuum_vacuum_scale_factor: {:continuous, 0.01, 0.2},
    autovacuum_analyze_scale_factor: {:continuous, 0.01, 0.1},
    autovacuum_vacuum_cost_limit: {:integer, 200, 2000},
    autovacuum_vacuum_cost_delay: {:integer, 0, 20},

    # Background writer settings
    bgwriter_delay: {:integer, 10, 500},
    bgwriter_lru_maxpages: {:integer, 50, 1000},

    # Connection settings
    max_connections: {:integer, 20, 500}
  }

  # Predefined reduced knob sets by workload type
  @oltp_knobs [
    :shared_buffers,
    :work_mem,
    :effective_cache_size,
    :random_page_cost,
    :checkpoint_completion_target,
    :max_wal_size,
    :autovacuum_vacuum_cost_limit,
    :bgwriter_lru_maxpages
  ]

  @olap_knobs [
    :shared_buffers,
    :work_mem,
    :maintenance_work_mem,
    :effective_cache_size,
    :max_parallel_workers_per_gather,
    :max_parallel_workers,
    :parallel_tuple_cost,
    :default_statistics_target,
    :random_page_cost
  ]

  @mixed_knobs [
    :shared_buffers,
    :work_mem,
    :effective_cache_size,
    :random_page_cost,
    :max_parallel_workers_per_gather,
    :checkpoint_completion_target,
    :autovacuum_vacuum_scale_factor,
    :max_wal_size
  ]

  @doc """
  Returns the full knob space with all tunable parameters.
  """
  @spec all() :: %{atom() => knob_def()}
  def all, do: @full_knobs

  @doc """
  Alias for all/0 - returns the full knob space.
  """
  @spec all_knobs() :: %{atom() => knob_def()}
  def all_knobs, do: @full_knobs

  @doc """
  Returns reduced knob space for OLTP workloads.
  """
  @spec oltp_knobs() :: %{atom() => knob_def()}
  def oltp_knobs, do: subset(@oltp_knobs)

  @doc """
  Returns reduced knob space for OLAP workloads.
  """
  @spec olap_knobs() :: %{atom() => knob_def()}
  def olap_knobs, do: subset(@olap_knobs)

  @doc """
  Returns reduced knob space for mixed workloads.
  """
  @spec mixed_knobs() :: %{atom() => knob_def()}
  def mixed_knobs, do: subset(@mixed_knobs)

  @doc """
  Returns the definition for a specific knob.
  """
  @spec get(atom()) :: knob_def() | nil
  def get(knob), do: Map.get(@full_knobs, knob)

  @doc """
  Returns the definition for a specific knob, raising if not found.
  """
  @spec get!(atom()) :: knob_def()
  def get!(knob), do: Map.fetch!(@full_knobs, knob)

  @doc """
  Returns a subset of knobs by their names.
  """
  @spec subset([atom()]) :: %{atom() => knob_def()}
  def subset(knob_names) do
    Map.take(@full_knobs, knob_names)
  end

  @doc """
  Returns the predefined knob set for a workload type.
  """
  @spec for_workload(:oltp | :olap | :mixed) :: [atom()]
  def for_workload(:oltp), do: @oltp_knobs
  def for_workload(:olap), do: @olap_knobs
  def for_workload(:mixed), do: @mixed_knobs

  @doc """
  Returns the knob space for a workload type.
  """
  @spec space_for_workload(:oltp | :olap | :mixed) :: %{atom() => knob_def()}
  def space_for_workload(workload) do
    workload
    |> for_workload()
    |> subset()
  end

  @doc """
  Returns all knob names.
  """
  @spec knob_names() :: [atom()]
  def knob_names, do: Map.keys(@full_knobs)

  @doc """
  Returns the type of a knob (:continuous, :integer, :categorical).
  """
  @spec type(atom()) :: knob_type() | nil
  def type(knob) do
    case get(knob) do
      {type, _, _} -> type
      {type, _} -> type
      nil -> nil
    end
  end

  @doc """
  Returns the bounds for a knob as {min, max}.
  For categorical knobs, returns {0, num_choices - 1}.
  """
  @spec bounds(atom()) :: {number(), number()} | nil
  def bounds(knob) do
    case get(knob) do
      {:continuous, min, max} -> {min, max}
      {:integer, min, max} -> {min, max}
      {:categorical, choices} -> {0, length(choices) - 1}
      nil -> nil
    end
  end

  @doc """
  Returns the categorical choices for a knob, or nil if not categorical.
  """
  @spec choices(atom()) :: [String.t()] | nil
  def choices(knob) do
    case get(knob) do
      {:categorical, choices} -> choices
      _ -> nil
    end
  end

  @doc """
  Checks if a knob is categorical.
  """
  @spec categorical?(atom()) :: boolean()
  def categorical?(knob), do: type(knob) == :categorical

  @doc """
  Returns all categorical knobs in a list of knob names.
  """
  @spec categorical_knobs([atom()]) :: [atom()]
  def categorical_knobs(knob_names) do
    Enum.filter(knob_names, &categorical?/1)
  end

  @doc """
  Returns all continuous/integer knobs in a list of knob names.
  """
  @spec numeric_knobs([atom()]) :: [atom()]
  def numeric_knobs(knob_names) do
    Enum.reject(knob_names, &categorical?/1)
  end

  @doc """
  Formats a knob value for PostgreSQL configuration.
  """
  @spec format_value(atom(), number() | String.t()) :: String.t()
  def format_value(knob, value) when knob in [:shared_buffers, :work_mem, :maintenance_work_mem,
                                               :effective_cache_size, :wal_buffers, :max_wal_size,
                                               :min_wal_size] do
    "#{round(value)}MB"
  end

  def format_value(knob, value) when knob in [:bgwriter_delay, :autovacuum_vacuum_cost_delay] do
    "#{round(value)}ms"
  end

  def format_value(knob, value) when knob in [:checkpoint_timeout] do
    "#{round(value)}s"
  end

  def format_value(_knob, value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 6)
  end

  def format_value(_knob, value) when is_integer(value) do
    Integer.to_string(value)
  end

  def format_value(_knob, value) when is_binary(value) do
    value
  end

  @doc """
  Validates a configuration map against knob definitions.
  """
  @spec validate_config(map()) :: :ok | {:error, [String.t()]}
  def validate_config(config) do
    errors =
      config
      |> Enum.map(fn {knob, value} -> validate_knob_value(knob, value) end)
      |> Enum.reject(&(&1 == :ok))
      |> Enum.map(fn {:error, msg} -> msg end)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp validate_knob_value(knob, value) do
    case get(knob) do
      nil ->
        {:error, "Unknown knob: #{knob}"}

      {:continuous, min, max} when is_number(value) ->
        if value >= min and value <= max do
          :ok
        else
          {:error, "#{knob}: #{value} not in range [#{min}, #{max}]"}
        end

      {:integer, min, max} when is_number(value) ->
        if value >= min and value <= max do
          :ok
        else
          {:error, "#{knob}: #{value} not in range [#{min}, #{max}]"}
        end

      {:categorical, choices} when is_binary(value) ->
        if value in choices do
          :ok
        else
          {:error, "#{knob}: #{value} not in #{inspect(choices)}"}
        end

      _ ->
        {:error, "#{knob}: invalid value type"}
    end
  end
end
