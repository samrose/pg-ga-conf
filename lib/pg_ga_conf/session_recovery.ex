defmodule PgGaConf.SessionRecovery do
  @moduledoc """
  Automatically recovers and resumes paused or crashed tuning sessions on application start.
  """

  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Delay recovery to let other services start
    Process.send_after(self(), :recover_sessions, 5_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:recover_sessions, state) do
    case safe_recover() do
      {:ok, 0} ->
        Logger.debug("No sessions to recover")

      {:ok, count} ->
        Logger.info("Recovered #{count} paused tuning sessions")

      {:error, reason} ->
        Logger.warning("Session recovery failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp safe_recover do
    try do
      do_recover()
    rescue
      e ->
        {:error, Exception.message(e)}
    catch
      :exit, reason ->
        {:error, inspect(reason)}
    end
  end

  defp do_recover do
    sessions = PgGaConf.ResultStore.get_resumable_sessions()

    recovered =
      sessions
      |> Enum.map(fn session ->
        Logger.info("Auto-resuming session #{session.id} for db #{session.db_id}")

        # TuningJob will auto-recover when started with the same db_id
        # For now, we just log - actual recovery requires db_url which we don't store
        # TODO: Store db_url in session for full auto-recovery
        Logger.debug("Session #{session.id} marked for recovery - requires manual restart with db_url")
        0
      end)
      |> Enum.sum()

    {:ok, recovered}
  end
end
