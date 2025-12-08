defmodule PgGaConf.Schema.ObservationTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Schema.Observation

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        db_id: "test-db-123",
        config: %{shared_buffers: 4096.0},
        score: 1.5,
        workload_cluster: "oltp"
      }

      changeset = Observation.changeset(%Observation{}, attrs)

      assert changeset.valid?
      assert changeset.changes.db_id == "test-db-123"
      assert changeset.changes.config == %{shared_buffers: 4096.0}
      assert changeset.changes.score == 1.5
      assert changeset.changes.workload_cluster == "oltp"
    end

    test "valid changeset with optional fields" do
      attrs = %{
        db_id: "test-db-123",
        config: %{shared_buffers: 4096.0},
        score: 1.5,
        workload_cluster: "oltp",
        metrics: %{tps: 1000, latency_p99: 5.0},
        fingerprint_vector: [0.5, 0.3, 0.8]
      }

      changeset = Observation.changeset(%Observation{}, attrs)

      assert changeset.valid?
      assert changeset.changes.metrics == %{tps: 1000, latency_p99: 5.0}
      assert changeset.changes.fingerprint_vector == [0.5, 0.3, 0.8]
    end

    test "invalid changeset missing db_id" do
      attrs = %{
        config: %{shared_buffers: 4096.0},
        score: 1.5,
        workload_cluster: "oltp"
      }

      changeset = Observation.changeset(%Observation{}, attrs)

      refute changeset.valid?
      assert {:db_id, {"can't be blank", _}} = hd(changeset.errors)
    end

    test "invalid changeset missing config" do
      attrs = %{
        db_id: "test-db-123",
        score: 1.5,
        workload_cluster: "oltp"
      }

      changeset = Observation.changeset(%Observation{}, attrs)

      refute changeset.valid?
      assert {:config, {"can't be blank", _}} = hd(changeset.errors)
    end

    test "invalid changeset missing score" do
      attrs = %{
        db_id: "test-db-123",
        config: %{shared_buffers: 4096.0},
        workload_cluster: "oltp"
      }

      changeset = Observation.changeset(%Observation{}, attrs)

      refute changeset.valid?
    end

    test "invalid changeset missing workload_cluster" do
      attrs = %{
        db_id: "test-db-123",
        config: %{shared_buffers: 4096.0},
        score: 1.5
      }

      changeset = Observation.changeset(%Observation{}, attrs)

      refute changeset.valid?
    end

    test "invalid changeset with negative score" do
      attrs = %{
        db_id: "test-db-123",
        config: %{shared_buffers: 4096.0},
        score: -1.0,
        workload_cluster: "oltp"
      }

      changeset = Observation.changeset(%Observation{}, attrs)

      refute changeset.valid?
      assert {:score, {"must be greater than or equal to %{number}", _}} = hd(changeset.errors)
    end

    test "valid changeset with zero score" do
      attrs = %{
        db_id: "test-db-123",
        config: %{shared_buffers: 4096.0},
        score: 0.0,
        workload_cluster: "oltp"
      }

      changeset = Observation.changeset(%Observation{}, attrs)

      assert changeset.valid?
    end
  end
end
