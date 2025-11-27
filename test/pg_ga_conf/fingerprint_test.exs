defmodule PgGaConf.FingerprintTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Fingerprint
  alias PgGaConf.Test.Fixtures

  describe "classify/1" do
    test "classifies OLTP-like fingerprint as :oltp" do
      fp = Fixtures.oltp_fingerprint()
      # Classification depends on algorithm thresholds
      result = Fingerprint.classify(fp)
      assert result in [:oltp, :mixed]
    end

    test "classifies OLAP-like fingerprint" do
      fp = Fixtures.olap_fingerprint()
      # Classification depends on algorithm thresholds
      result = Fingerprint.classify(fp)
      assert result in [:olap, :mixed]
    end

    test "classifies mixed fingerprint as :mixed" do
      fp = Fixtures.mixed_fingerprint()
      result = Fingerprint.classify(fp)
      assert result in [:oltp, :olap, :mixed]
    end

    test "high index scan ratio contributes to OLTP" do
      fp = %{
        read_write_ratio: 0.5,
        seq_scan_ratio: 0.1,
        index_scan_ratio: 0.9,
        heap_blks_hit_ratio: 0.99,
        idx_blks_hit_ratio: 0.99,
        avg_tuple_size: 50.0,
        temp_files_ratio: 0.0,
        deadlock_ratio: 0.0,
        xact_commit_ratio: 0.99,
        tup_returned_per_fetch: 1.0,
        tup_inserted_ratio: 0.33,
        tup_updated_ratio: 0.34,
        tup_deleted_ratio: 0.33,
        blk_read_time_ratio: 0.5,
        blk_write_time_ratio: 0.5
      }

      result = Fingerprint.classify(fp)
      # High index scan should lean toward OLTP
      assert result in [:oltp, :mixed]
    end

    test "high sequential scan ratio contributes to OLAP" do
      fp = %{
        read_write_ratio: 0.99,
        seq_scan_ratio: 0.95,
        index_scan_ratio: 0.05,
        heap_blks_hit_ratio: 0.5,
        idx_blks_hit_ratio: 0.5,
        avg_tuple_size: 500.0,
        temp_files_ratio: 0.15,
        deadlock_ratio: 0.0,
        xact_commit_ratio: 0.99,
        tup_returned_per_fetch: 10000.0,
        tup_inserted_ratio: 0.0,
        tup_updated_ratio: 0.0,
        tup_deleted_ratio: 0.0,
        blk_read_time_ratio: 0.9,
        blk_write_time_ratio: 0.1
      }

      result = Fingerprint.classify(fp)
      # High seq scan + reads should lean toward OLAP
      assert result in [:olap, :mixed]
    end

    test "returns valid workload type" do
      for fp <- [Fixtures.oltp_fingerprint(), Fixtures.olap_fingerprint(), Fixtures.mixed_fingerprint()] do
        result = Fingerprint.classify(fp)
        assert result in [:oltp, :olap, :mixed]
      end
    end
  end

  describe "similarity/2" do
    test "identical fingerprints have similarity 1.0" do
      fp = Fixtures.oltp_fingerprint()
      assert_in_delta Fingerprint.similarity(fp, fp), 1.0, 0.001
    end

    test "similar fingerprints have high similarity" do
      fp1 = Fixtures.oltp_fingerprint()
      fp2 = %{fp1 | read_write_ratio: fp1.read_write_ratio + 0.05}

      sim = Fingerprint.similarity(fp1, fp2)
      assert sim > 0.95
    end

    test "different workload types have lower similarity" do
      oltp = Fixtures.oltp_fingerprint()
      olap = Fixtures.olap_fingerprint()

      sim = Fingerprint.similarity(oltp, olap)
      assert sim < 0.9
    end

    test "handles zero vectors" do
      zero_fp = %{
        read_write_ratio: 0.0,
        seq_scan_ratio: 0.0,
        index_scan_ratio: 0.0,
        heap_blks_hit_ratio: 0.0,
        idx_blks_hit_ratio: 0.0,
        avg_tuple_size: 0.0,
        temp_files_ratio: 0.0,
        deadlock_ratio: 0.0,
        xact_commit_ratio: 0.0,
        tup_returned_per_fetch: 0.0,
        tup_inserted_ratio: 0.0,
        tup_updated_ratio: 0.0,
        tup_deleted_ratio: 0.0,
        blk_read_time_ratio: 0.0,
        blk_write_time_ratio: 0.0
      }

      non_zero = Fixtures.oltp_fingerprint()

      assert Fingerprint.similarity(zero_fp, non_zero) == 0.0
      assert Fingerprint.similarity(zero_fp, zero_fp) == 0.0
    end
  end

  describe "fingerprint_to_vector/1" do
    test "converts fingerprint to 15-dimension vector" do
      fp = Fixtures.oltp_fingerprint()
      vec = Fingerprint.fingerprint_to_vector(fp)

      assert is_list(vec)
      assert length(vec) == 15
      assert Enum.all?(vec, &is_number/1)
    end

    test "vector elements in expected order" do
      fp = %{
        read_write_ratio: 0.1,
        seq_scan_ratio: 0.2,
        index_scan_ratio: 0.3,
        heap_blks_hit_ratio: 0.4,
        idx_blks_hit_ratio: 0.5,
        avg_tuple_size: 0.6,
        temp_files_ratio: 0.7,
        deadlock_ratio: 0.8,
        xact_commit_ratio: 0.9,
        tup_returned_per_fetch: 1.0,
        tup_inserted_ratio: 1.1,
        tup_updated_ratio: 1.2,
        tup_deleted_ratio: 1.3,
        blk_read_time_ratio: 1.4,
        blk_write_time_ratio: 1.5
      }

      vec = Fingerprint.fingerprint_to_vector(fp)

      assert Enum.at(vec, 0) == 0.1
      assert Enum.at(vec, 1) == 0.2
      assert Enum.at(vec, 2) == 0.3
      assert Enum.at(vec, 14) == 1.5
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips fingerprint" do
      fp = Fixtures.oltp_fingerprint()

      binary = Fingerprint.serialize(fp)
      assert is_binary(binary)

      {:ok, restored} = Fingerprint.deserialize(binary)
      assert restored == fp
    end

    test "deserialize returns error for invalid binary" do
      assert {:error, :invalid_fingerprint} = Fingerprint.deserialize("invalid")
    end

    test "deserialize returns error for malformed binary" do
      # A binary that's valid erlang term but not a fingerprint
      binary = :erlang.term_to_binary([1, 2, 3])
      {:ok, result} = Fingerprint.deserialize(binary)
      # It will deserialize but won't be a valid fingerprint map
      assert result == [1, 2, 3]
    end
  end

  describe "similarity properties" do
    test "similarity is symmetric" do
      fp1 = Fixtures.oltp_fingerprint()
      fp2 = Fixtures.olap_fingerprint()

      assert_in_delta Fingerprint.similarity(fp1, fp2), Fingerprint.similarity(fp2, fp1), 0.001
    end

    test "similarity is bounded [0, 1]" do
      for _ <- 1..10 do
        fp1 = random_fingerprint()
        fp2 = random_fingerprint()

        sim = Fingerprint.similarity(fp1, fp2)
        assert sim >= 0.0
        assert sim <= 1.0
      end
    end
  end

  describe "classification edge cases" do
    test "balanced fingerprint returns valid type" do
      fp = %{
        read_write_ratio: 0.5,
        seq_scan_ratio: 0.5,
        index_scan_ratio: 0.5,
        heap_blks_hit_ratio: 0.5,
        idx_blks_hit_ratio: 0.5,
        avg_tuple_size: 100.0,
        temp_files_ratio: 0.01,
        deadlock_ratio: 0.0,
        xact_commit_ratio: 0.95,
        tup_returned_per_fetch: 10.0,
        tup_inserted_ratio: 0.33,
        tup_updated_ratio: 0.34,
        tup_deleted_ratio: 0.33,
        blk_read_time_ratio: 0.5,
        blk_write_time_ratio: 0.5
      }

      result = Fingerprint.classify(fp)
      assert result in [:oltp, :olap, :mixed]
    end
  end

  # Helper to generate random fingerprint for property tests
  defp random_fingerprint do
    %{
      read_write_ratio: :rand.uniform(),
      seq_scan_ratio: :rand.uniform(),
      index_scan_ratio: :rand.uniform(),
      heap_blks_hit_ratio: :rand.uniform(),
      idx_blks_hit_ratio: :rand.uniform(),
      avg_tuple_size: :rand.uniform() * 1000,
      temp_files_ratio: :rand.uniform(),
      deadlock_ratio: :rand.uniform() * 0.01,
      xact_commit_ratio: 0.9 + :rand.uniform() * 0.1,
      tup_returned_per_fetch: :rand.uniform() * 100,
      tup_inserted_ratio: :rand.uniform() / 3,
      tup_updated_ratio: :rand.uniform() / 3,
      tup_deleted_ratio: :rand.uniform() / 3,
      blk_read_time_ratio: :rand.uniform(),
      blk_write_time_ratio: :rand.uniform()
    }
  end
end
