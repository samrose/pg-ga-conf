defmodule PgGaConf.JobStorage do
  @moduledoc """
  ETS-based storage for optimization job status and results.
  """

  use GenServer

  @table_name :pg_ga_conf_jobs

  defstruct [
    :job_id,
    :state,
    :progress,
    :best_fitness,
    :elapsed_seconds,
    :estimated_remaining,
    :result,
    :started_at,
    :completed_at
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get job status.
  """
  def get_job_status(job_id) do
    case :ets.lookup(@table_name, job_id) do
      [{^job_id, status}] -> {:ok, status}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Create a new job.
  """
  def create_job(job_id) do
    status = %__MODULE__{
      job_id: job_id,
      state: :running,
      progress: %{current_generation: 0, total_generations: 0, percentage: 0},
      best_fitness: nil,
      elapsed_seconds: 0,
      estimated_remaining: nil,
      result: nil,
      started_at: DateTime.utc_now(),
      completed_at: nil
    }

    :ets.insert(@table_name, {job_id, status})
    {:ok, status}
  end

  @doc """
  Update job status.
  """
  def update_job(job_id, updates) do
    case :ets.lookup(@table_name, job_id) do
      [{^job_id, status}] ->
        updated_status = struct(status, updates)
        :ets.insert(@table_name, {job_id, updated_status})
        {:ok, updated_status}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Save final result for a job.
  """
  def save_result(job_id, result) do
    update_job(job_id, %{
      state: :completed,
      result: result,
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Mark job as failed.
  """
  def mark_failed(job_id, reason) do
    update_job(job_id, %{
      state: :failed,
      result: %{error: reason},
      completed_at: DateTime.utc_now()
    })
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
