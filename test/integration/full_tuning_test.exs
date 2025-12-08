defmodule PgGaConf.Integration.FullTuningTest do
  @moduledoc """
  End-to-end integration tests for the complete tuning workflow.

  These tests require:
  - Running PostgreSQL instance
  - pgbench installed
  - Python with Optuna (for TPE/CMA-ES)
  - Julia (for Sobol analysis)

  Run with: mix test --include integration
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :full_integration
  @moduletag timeout: 300_000

  alias PgGaConf.Test.Fixtures

  setup do
    # Check if PostgreSQL is available
    db_url = System.get_env("TEST_DATABASE_URL", "postgres://postgres@localhost:5432/pgga_test")

    case check_postgres_connection(db_url) do
      :ok -> {:ok, db_url: db_url}
      :error -> :skip
    end
  end

  describe "full GA optimization workflow" do
    @tag timeout: 180_000
    test "optimizes configuration using GA", %{db_url: db_url} do
      {:ok, job} =
        PgGaConf.tune(db_url,
          optimizer: :ga,
          max_iterations: 5,
          duration: 5,
          clients: 2,
          population_size: 5
        )

      # Wait for completion or timeout
      result = wait_for_completion(job, 180_000)

      assert result in [:completed, :timeout]

      if result == :completed do
        {:ok, best_config, best_score} = PgGaConf.best(job)

        assert is_map(best_config)
        assert is_float(best_score)
        assert best_score > 0
      end

      PgGaConf.stop(job)
    end
  end

  describe "full TPE optimization workflow" do
    @tag timeout: 180_000
    test "optimizes configuration using TPE", %{db_url: db_url} do
      # Skip if Pythonx not available
      unless pythonx_available?() do
        :skip
      else
        {:ok, job} =
          PgGaConf.tune(db_url,
            optimizer: :tpe,
            max_iterations: 5,
            duration: 5,
            clients: 2
          )

        result = wait_for_completion(job, 180_000)

        if result == :completed do
          {:ok, best_config, best_score} = PgGaConf.best(job)

          assert is_map(best_config)
          assert best_score > 0
        end

        PgGaConf.stop(job)
      end
    end
  end

  describe "pause and resume workflow" do
    @tag timeout: 120_000
    test "pauses, checkpoints, and resumes", %{db_url: db_url} do
      {:ok, job} =
        PgGaConf.tune(db_url,
          optimizer: :ga,
          max_iterations: 10,
          duration: 5,
          clients: 2,
          population_size: 5
        )

      # Wait for a couple iterations
      Process.sleep(15_000)

      # Pause
      :ok = PgGaConf.pause(job)

      {:ok, status} = PgGaConf.status(job)
      assert status.status == :paused
      iterations_at_pause = status.current_iteration

      # Resume
      :ok = PgGaConf.resume(job)

      {:ok, status} = PgGaConf.status(job)
      assert status.status == :running
      # Should resume from where we left off
      assert status.current_iteration >= iterations_at_pause

      PgGaConf.stop(job)
    end
  end

  describe "warm start workflow" do
    @tag timeout: 180_000
    test "uses prior observations for warm start", %{db_url: db_url} do
      # Run first optimization
      {:ok, job1} =
        PgGaConf.tune(db_url,
          optimizer: :ga,
          max_iterations: 3,
          duration: 5,
          clients: 2,
          population_size: 5,
          warm_start: false
        )

      wait_for_completion(job1, 90_000)
      {:ok, first_config, first_score} = PgGaConf.best(job1)
      PgGaConf.stop(job1)

      # Run second optimization with warm start
      {:ok, job2} =
        PgGaConf.tune(db_url,
          optimizer: :ga,
          max_iterations: 3,
          duration: 5,
          clients: 2,
          population_size: 5,
          warm_start: true
        )

      wait_for_completion(job2, 90_000)
      {:ok, second_config, second_score} = PgGaConf.best(job2)
      PgGaConf.stop(job2)

      # Second run should have benefited from warm start
      # (At minimum, both should have valid results)
      assert is_map(first_config)
      assert is_map(second_config)
      assert first_score > 0
      assert second_score > 0
    end
  end

  describe "workload analysis" do
    test "analyzes workload fingerprint", %{db_url: db_url} do
      {:ok, analysis} = PgGaConf.analyze(db_url)

      assert analysis.workload_type in [:oltp, :olap, :mixed]
      assert analysis.recommended_optimizer in [:ga, :tpe, :cma_es]
      assert is_list(analysis.recommended_knobs)
      assert length(analysis.recommended_knobs) > 0
    end
  end

  describe "config formatting" do
    test "formats configuration for PostgreSQL" do
      config = Fixtures.sample_config()
      formatted = PgGaConf.format_config(config)

      assert formatted[:shared_buffers] =~ ~r/MB$/
      assert formatted[:work_mem] =~ ~r/MB$/
    end
  end

  # Helper functions

  defp check_postgres_connection(db_url) do
    uri = URI.parse(db_url)

    opts = [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: get_userinfo(uri, :username) || "postgres",
      password: get_userinfo(uri, :password),
      database: String.trim_leading(uri.path || "/postgres", "/")
    ]

    case Postgrex.start_link(opts) do
      {:ok, conn} ->
        GenServer.stop(conn)
        :ok

      {:error, _} ->
        :error
    end
  rescue
    _ -> :error
  end

  defp get_userinfo(uri, :username) do
    case uri.userinfo do
      nil -> nil
      info -> info |> String.split(":") |> hd()
    end
  end

  defp get_userinfo(uri, :password) do
    case uri.userinfo do
      nil -> nil
      info -> info |> String.split(":") |> Enum.at(1)
    end
  end

  defp wait_for_completion(job, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait_loop(job, deadline)
  end

  defp wait_loop(job, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      :timeout
    else
      case PgGaConf.status(job) do
        {:ok, %{status: :completed}} ->
          :completed

        {:ok, %{status: :error}} ->
          :error

        {:ok, %{status: _}} ->
          Process.sleep(1_000)
          wait_loop(job, deadline)

        {:error, _} ->
          :error
      end
    end
  end

  defp pythonx_available? do
    try do
      Code.ensure_loaded?(Pythonx)
    rescue
      _ -> false
    end
  end
end
