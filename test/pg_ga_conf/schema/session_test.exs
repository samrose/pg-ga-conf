defmodule PgGaConf.Schema.SessionTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Schema.Session

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        db_id: "test-db-123",
        optimizer: "ga"
      }

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      assert changeset.changes.db_id == "test-db-123"
      assert changeset.changes.optimizer == "ga"
    end

    test "valid changeset with all optimizer types" do
      for optimizer <- ~w(ga tpe cma_es) do
        attrs = %{db_id: "test-db", optimizer: optimizer}
        changeset = Session.changeset(%Session{}, attrs)
        assert changeset.valid?, "Expected #{optimizer} to be valid"
      end
    end

    test "invalid changeset with unknown optimizer" do
      attrs = %{db_id: "test-db", optimizer: "unknown"}
      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
      assert {:optimizer, {"is invalid", _}} = hd(changeset.errors)
    end

    test "valid changeset with all status values" do
      for status <- Session.statuses() do
        attrs = %{db_id: "test-db", optimizer: "ga", status: status}
        changeset = Session.changeset(%Session{}, attrs)
        assert changeset.valid?, "Expected status #{status} to be valid"
      end
    end

    test "invalid changeset with unknown status" do
      attrs = %{db_id: "test-db", optimizer: "ga", status: "unknown"}
      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
      assert {:status, {"is invalid", _}} = hd(changeset.errors)
    end

    test "valid changeset with optional fields" do
      attrs = %{
        db_id: "test-db-123",
        optimizer: "tpe",
        status: "running",
        current_iteration: 10,
        max_iterations: 100,
        knobs_used: ["shared_buffers", "work_mem"],
        best_config: %{shared_buffers: 4096.0},
        best_score: 1.5,
        initial_score: 2.0,
        improvement_pct: 25.0,
        history: [%{iteration: 1, score: 2.0}],
        workload_cluster: "oltp",
        fingerprint_vector: [0.5, 0.3]
      }

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      assert changeset.changes.current_iteration == 10
      assert changeset.changes.max_iterations == 100
    end

    test "valid changeset with optimizer_state binary" do
      state = :erlang.term_to_binary(%{generation: 5, population: []})

      attrs = %{
        db_id: "test-db",
        optimizer: "ga",
        optimizer_state: state
      }

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      assert changeset.changes.optimizer_state == state
    end

    test "invalid changeset missing db_id" do
      attrs = %{optimizer: "ga"}
      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
    end

    test "invalid changeset missing optimizer" do
      attrs = %{db_id: "test-db"}
      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
    end

    test "invalid changeset with negative current_iteration" do
      attrs = %{
        db_id: "test-db",
        optimizer: "ga",
        current_iteration: -1
      }

      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
      assert {:current_iteration, {"must be greater than or equal to %{number}", _}} =
               hd(changeset.errors)
    end

    test "invalid changeset with zero max_iterations" do
      attrs = %{
        db_id: "test-db",
        optimizer: "ga",
        max_iterations: 0
      }

      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
      assert {:max_iterations, {"must be greater than %{number}", _}} = hd(changeset.errors)
    end

    test "valid changeset with error tracking" do
      attrs = %{
        db_id: "test-db",
        optimizer: "ga",
        last_error: "Connection timeout",
        error_count: 3,
        consecutive_errors: 1
      }

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      assert changeset.changes.last_error == "Connection timeout"
      assert changeset.changes.error_count == 3
    end
  end

  describe "statuses/0" do
    test "returns all valid statuses" do
      statuses = Session.statuses()

      assert "initializing" in statuses
      assert "running" in statuses
      assert "paused" in statuses
      assert "completed" in statuses
      assert "failed" in statuses
      assert "stopped" in statuses
    end
  end
end
