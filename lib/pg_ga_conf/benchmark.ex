defmodule PgGaConf.Benchmark do
  @moduledoc """
  Behaviour for benchmark implementations.

  Defines the interface for running PostgreSQL benchmarks and measuring performance.
  Default implementation uses pgbench, but can be swapped for custom workloads.

  ## Usage

  ```elixir
  # Using default pgbench
  {:ok, runner} = PgGaConf.Benchmark.Pgbench.init(db_url: "postgres://...")

  # Run benchmark
  {:ok, score, metrics} = PgGaConf.Benchmark.Pgbench.run(runner)

  # Apply config and re-benchmark
  :ok = PgGaConf.Benchmark.Pgbench.apply_config(runner, %{shared_buffers: 4096})
  {:ok, new_score, new_metrics} = PgGaConf.Benchmark.Pgbench.run(runner)
  ```
  """

  @type score :: float()
  @type config :: %{atom() => term()}
  @type metrics :: %{
          optional(:tps) => float(),
          optional(:latency_avg) => float(),
          optional(:latency_p99) => float(),
          optional(:duration_ms) => integer(),
          optional(:transactions) => integer()
        }
  @type state :: term()

  @doc """
  Initialize benchmark runner with options.

  Common options:
  - `:db_url` - PostgreSQL connection URL (required)
  - `:duration` - Benchmark duration in seconds (default: 60)
  - `:clients` - Number of concurrent clients (default: 10)
  - `:scale` - Scale factor for pgbench (default: 10)
  """
  @callback init(keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Run the benchmark and return a score (lower is better).

  Also returns detailed metrics for analysis.
  """
  @callback run(state()) :: {:ok, score(), metrics()} | {:error, term()}

  @doc """
  Apply PostgreSQL configuration changes.

  May require database restart depending on the parameters.
  """
  @callback apply_config(state(), config()) :: :ok | {:error, term()}

  @doc """
  Reset database to known state before benchmark.

  Optional callback for benchmarks that modify data.
  """
  @callback reset(state()) :: :ok | {:error, term()}

  @doc """
  Clean up resources.
  """
  @callback cleanup(state()) :: :ok

  @optional_callbacks [reset: 1]

  @doc """
  Get the benchmark module for a given type.
  """
  @spec get_benchmark(:pgbench | :custom) :: module()
  def get_benchmark(:pgbench), do: PgGaConf.Benchmark.Pgbench
  def get_benchmark(:custom), do: PgGaConf.Benchmark.Custom
end
