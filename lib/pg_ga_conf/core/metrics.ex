defmodule PgGaConf.Core.Metrics do
  @moduledoc """
  Performance metrics from benchmark runs.
  """

  defstruct [
    :transactions_per_sec,
    :p50_latency_ms,
    :p95_latency_ms,
    :p99_latency_ms,
    :cache_hit_ratio,
    :temp_files,
    :deadlocks,
    :timeouts,
    :checkpoint_sync_time_spikes,
    :duration_seconds
  ]

  @type t :: %__MODULE__{
    transactions_per_sec: float(),
    p50_latency_ms: float(),
    p95_latency_ms: float(),
    p99_latency_ms: float(),
    cache_hit_ratio: float(),
    temp_files: non_neg_integer(),
    deadlocks: non_neg_integer(),
    timeouts: non_neg_integer(),
    checkpoint_sync_time_spikes: non_neg_integer(),
    duration_seconds: non_neg_integer()
  }

  def new(params \\ %{}) do
    struct(__MODULE__, params)
  end
end
