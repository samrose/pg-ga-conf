defmodule PgGaConf.Schema.SobolCacheTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Schema.SobolCache
  alias PgGaConf.Fingerprint
  alias PgGaConf.Test.Fixtures

  describe "changeset/2" do
    test "valid changeset with required fields" do
      fp = Fixtures.oltp_fingerprint()
      indices = Fixtures.sample_sensitivity_indices()

      attrs = %{
        fingerprint: Fingerprint.serialize(fp),
        knob_names: ["shared_buffers", "work_mem"],
        sensitivity_indices: Jason.encode!(indices)
      }

      changeset = SobolCache.changeset(%SobolCache{}, attrs)

      assert changeset.valid?
      assert changeset.changes.knob_names == ["shared_buffers", "work_mem"]
    end

    test "valid changeset with optional fields" do
      fp = Fixtures.oltp_fingerprint()
      indices = Fixtures.sample_sensitivity_indices()

      attrs = %{
        fingerprint: Fingerprint.serialize(fp),
        knob_names: ["shared_buffers", "work_mem"],
        sensitivity_indices: Jason.encode!(indices),
        workload_type: "oltp",
        samples_used: 128,
        analysis_duration_ms: 5000
      }

      changeset = SobolCache.changeset(%SobolCache{}, attrs)

      assert changeset.valid?
      assert changeset.changes.workload_type == "oltp"
      assert changeset.changes.samples_used == 128
      assert changeset.changes.analysis_duration_ms == 5000
    end

    test "valid changeset with all workload types" do
      for type <- ~w(oltp olap mixed) do
        fp = Fixtures.oltp_fingerprint()

        attrs = %{
          fingerprint: Fingerprint.serialize(fp),
          knob_names: ["shared_buffers"],
          sensitivity_indices: "{}",
          workload_type: type
        }

        changeset = SobolCache.changeset(%SobolCache{}, attrs)
        assert changeset.valid?, "Expected workload_type #{type} to be valid"
      end
    end

    test "invalid changeset with unknown workload_type" do
      fp = Fixtures.oltp_fingerprint()

      attrs = %{
        fingerprint: Fingerprint.serialize(fp),
        knob_names: ["shared_buffers"],
        sensitivity_indices: "{}",
        workload_type: "unknown"
      }

      changeset = SobolCache.changeset(%SobolCache{}, attrs)

      refute changeset.valid?
      assert {:workload_type, {"is invalid", _}} = hd(changeset.errors)
    end

    test "invalid changeset missing fingerprint" do
      attrs = %{
        knob_names: ["shared_buffers"],
        sensitivity_indices: "{}"
      }

      changeset = SobolCache.changeset(%SobolCache{}, attrs)

      refute changeset.valid?
    end

    test "invalid changeset missing knob_names" do
      fp = Fixtures.oltp_fingerprint()

      attrs = %{
        fingerprint: Fingerprint.serialize(fp),
        sensitivity_indices: "{}"
      }

      changeset = SobolCache.changeset(%SobolCache{}, attrs)

      refute changeset.valid?
    end

    test "invalid changeset missing sensitivity_indices" do
      fp = Fixtures.oltp_fingerprint()

      attrs = %{
        fingerprint: Fingerprint.serialize(fp),
        knob_names: ["shared_buffers"]
      }

      changeset = SobolCache.changeset(%SobolCache{}, attrs)

      refute changeset.valid?
    end

    test "invalid changeset with zero samples_used" do
      fp = Fixtures.oltp_fingerprint()

      attrs = %{
        fingerprint: Fingerprint.serialize(fp),
        knob_names: ["shared_buffers"],
        sensitivity_indices: "{}",
        samples_used: 0
      }

      changeset = SobolCache.changeset(%SobolCache{}, attrs)

      refute changeset.valid?
      assert {:samples_used, {"must be greater than %{number}", _}} = hd(changeset.errors)
    end

    test "valid changeset preserves binary fingerprint" do
      fp = Fixtures.olap_fingerprint()
      binary = Fingerprint.serialize(fp)

      attrs = %{
        fingerprint: binary,
        knob_names: ["shared_buffers"],
        sensitivity_indices: "{}"
      }

      changeset = SobolCache.changeset(%SobolCache{}, attrs)

      assert changeset.valid?
      # Fingerprint should be stored as binary
      {:ok, restored} = Fingerprint.deserialize(changeset.changes.fingerprint)
      assert restored == fp
    end
  end
end
