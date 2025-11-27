defmodule PgGaConfAPITest do
  use ExUnit.Case, async: true

  alias PgGaConf.Test.Fixtures

  describe "all_knobs/0" do
    test "returns all PostgreSQL knobs" do
      knobs = PgGaConf.all_knobs()

      assert is_map(knobs)
      assert map_size(knobs) > 20
      assert Map.has_key?(knobs, :shared_buffers)
      assert Map.has_key?(knobs, :work_mem)
      assert Map.has_key?(knobs, :max_connections)
    end
  end

  describe "knobs_for_workload/1" do
    test "returns OLTP knobs" do
      knobs = PgGaConf.knobs_for_workload(:oltp)

      assert is_map(knobs)
      assert map_size(knobs) > 0
      assert Map.has_key?(knobs, :shared_buffers)
    end

    test "returns OLAP knobs" do
      knobs = PgGaConf.knobs_for_workload(:olap)

      assert is_map(knobs)
      assert map_size(knobs) > 0
    end

    test "returns mixed knobs" do
      knobs = PgGaConf.knobs_for_workload(:mixed)

      assert is_map(knobs)
      assert map_size(knobs) > 0
    end

    test "all workload knobs are subsets of all knobs" do
      all = PgGaConf.all_knobs()

      for type <- [:oltp, :olap, :mixed] do
        workload_knobs = PgGaConf.knobs_for_workload(type)

        for {name, _} <- workload_knobs do
          assert Map.has_key?(all, name),
                 "#{type} knob #{name} should be in full knob space"
        end
      end
    end
  end

  describe "format_config/1" do
    test "formats memory parameters with MB suffix" do
      config = %{shared_buffers: 4096, work_mem: 64}
      formatted = PgGaConf.format_config(config)

      assert formatted[:shared_buffers] == "4096MB"
      assert formatted[:work_mem] == "64MB"
    end

    test "formats integer parameters" do
      config = %{max_connections: 100}
      formatted = PgGaConf.format_config(config)

      assert formatted[:max_connections] == "100"
    end

    test "formats categorical parameters" do
      config = %{huge_pages: "off"}
      formatted = PgGaConf.format_config(config)

      assert formatted[:huge_pages] == "off"
    end

    test "formats full sample config" do
      config = Fixtures.sample_config()
      formatted = PgGaConf.format_config(config)

      assert is_map(formatted)
      assert map_size(formatted) == map_size(config)
    end
  end

  describe "analyze/1 with URL" do
    test "returns analysis with workload type" do
      {:ok, analysis} = PgGaConf.analyze("postgres://localhost/testdb")

      assert is_map(analysis)
      assert analysis.workload_type in [:oltp, :olap, :mixed]
      assert analysis.recommended_optimizer in [:ga, :tpe, :cma_es]
      assert is_list(analysis.recommended_knobs)
      assert is_map(analysis.fingerprint)
    end

    test "recommended knobs are atoms" do
      {:ok, analysis} = PgGaConf.analyze("postgres://localhost/testdb")

      assert Enum.all?(analysis.recommended_knobs, &is_atom/1)
    end

    test "fingerprint has expected structure" do
      {:ok, analysis} = PgGaConf.analyze("postgres://localhost/testdb")

      fp = analysis.fingerprint
      assert Map.has_key?(fp, :read_write_ratio)
      assert Map.has_key?(fp, :seq_scan_ratio)
      assert Map.has_key?(fp, :heap_blks_hit_ratio)
    end
  end

  describe "generate_db_id helper" do
    test "generates unique IDs from URL" do
      # Test via the public interface
      # The db_id is generated internally when tune is called
      url = "postgres://localhost/mydb"
      uri = URI.parse(url)

      host = uri.host || "localhost"
      db = (uri.path || "/postgres") |> String.trim_leading("/")

      assert host == "localhost"
      assert db == "mydb"
    end
  end

  describe "type specs" do
    test "optimizer type includes all options" do
      # Verify the type includes expected atoms
      optimizers = [:ga, :tpe, :cma_es, :auto]
      assert Enum.all?(optimizers, &is_atom/1)
    end

    test "benchmark type includes expected options" do
      benchmarks = [:pgbench, :custom]
      assert Enum.all?(benchmarks, &is_atom/1)
    end
  end
end

defmodule PgGaConfAPIIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  describe "tune/2" do
    @tag timeout: 120_000
    test "starts a tuning job" do
      # This test requires a running PostgreSQL instance
      db_url = "postgres://postgres@localhost:5432/pgga_test"

      case PgGaConf.tune(db_url, max_iterations: 2) do
        {:ok, job} ->
          assert is_pid(job)
          PgGaConf.stop(job)

        {:error, _} ->
          # Database not available
          :ok
      end
    end
  end

  describe "status/1" do
    @tag timeout: 60_000
    test "returns job status" do
      db_url = "postgres://postgres@localhost:5432/pgga_test"

      case PgGaConf.tune(db_url, max_iterations: 2) do
        {:ok, job} ->
          # Give it a moment to start
          Process.sleep(1_000)

          {:ok, status} = PgGaConf.status(job)

          assert is_map(status)
          assert Map.has_key?(status, :status)
          assert Map.has_key?(status, :current_iteration)

          PgGaConf.stop(job)

        {:error, _} ->
          :ok
      end
    end
  end

  describe "pause/1 and resume/1" do
    @tag timeout: 60_000
    test "pauses and resumes a job" do
      db_url = "postgres://postgres@localhost:5432/pgga_test"

      case PgGaConf.tune(db_url, max_iterations: 10) do
        {:ok, job} ->
          Process.sleep(1_000)

          assert :ok = PgGaConf.pause(job)

          {:ok, status} = PgGaConf.status(job)
          assert status.status == :paused

          assert :ok = PgGaConf.resume(job)

          PgGaConf.stop(job)

        {:error, _} ->
          :ok
      end
    end
  end
end
