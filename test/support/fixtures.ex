defmodule PgGaConf.Test.Fixtures do
  @moduledoc """
  Test fixtures for PgGaConf tests.
  """

  @doc "Sample knob space for testing"
  def sample_knob_space do
    %{
      shared_buffers: {:continuous, 128.0, 16384.0},
      work_mem: {:continuous, 4.0, 2048.0},
      max_connections: {:integer, 20, 500},
      huge_pages: {:categorical, ["off", "on", "try"]}
    }
  end

  @doc "Minimal knob space for quick tests"
  def minimal_knob_space do
    %{
      shared_buffers: {:continuous, 128.0, 1024.0},
      work_mem: {:continuous, 4.0, 64.0}
    }
  end

  @doc "Sample OLTP-like fingerprint"
  def oltp_fingerprint do
    %{
      read_write_ratio: 0.6,
      seq_scan_ratio: 0.2,
      index_scan_ratio: 0.8,
      heap_blks_hit_ratio: 0.98,
      idx_blks_hit_ratio: 0.99,
      avg_tuple_size: 50.0,
      temp_files_ratio: 0.001,
      deadlock_ratio: 0.0,
      xact_commit_ratio: 0.99,
      tup_returned_per_fetch: 1.2,
      tup_inserted_ratio: 0.35,
      tup_updated_ratio: 0.40,
      tup_deleted_ratio: 0.25,
      blk_read_time_ratio: 0.2,
      blk_write_time_ratio: 0.8
    }
  end

  @doc "Sample OLAP-like fingerprint"
  def olap_fingerprint do
    %{
      read_write_ratio: 0.95,
      seq_scan_ratio: 0.8,
      index_scan_ratio: 0.2,
      heap_blks_hit_ratio: 0.7,
      idx_blks_hit_ratio: 0.8,
      avg_tuple_size: 500.0,
      temp_files_ratio: 0.1,
      deadlock_ratio: 0.0,
      xact_commit_ratio: 0.99,
      tup_returned_per_fetch: 1000.0,
      tup_inserted_ratio: 0.1,
      tup_updated_ratio: 0.05,
      tup_deleted_ratio: 0.05,
      blk_read_time_ratio: 0.8,
      blk_write_time_ratio: 0.2
    }
  end

  @doc "Sample mixed workload fingerprint"
  def mixed_fingerprint do
    %{
      read_write_ratio: 0.7,
      seq_scan_ratio: 0.5,
      index_scan_ratio: 0.5,
      heap_blks_hit_ratio: 0.9,
      idx_blks_hit_ratio: 0.92,
      avg_tuple_size: 150.0,
      temp_files_ratio: 0.02,
      deadlock_ratio: 0.0,
      xact_commit_ratio: 0.98,
      tup_returned_per_fetch: 50.0,
      tup_inserted_ratio: 0.3,
      tup_updated_ratio: 0.4,
      tup_deleted_ratio: 0.3,
      blk_read_time_ratio: 0.5,
      blk_write_time_ratio: 0.5
    }
  end

  @doc "Sample config within bounds"
  def sample_config do
    %{
      shared_buffers: 4096.0,
      work_mem: 64.0,
      max_connections: 100,
      huge_pages: "off"
    }
  end

  @doc "Sample config for minimal knob space"
  def minimal_config do
    %{
      shared_buffers: 512.0,
      work_mem: 32.0
    }
  end

  @doc "Sample observations for warm-start"
  def sample_observations do
    [
      {%{shared_buffers: 256.0, work_mem: 16.0}, 1.0},
      {%{shared_buffers: 512.0, work_mem: 32.0}, 0.8},
      {%{shared_buffers: 1024.0, work_mem: 64.0}, 0.6},
      {%{shared_buffers: 2048.0, work_mem: 128.0}, 0.5},
      {%{shared_buffers: 4096.0, work_mem: 256.0}, 0.4}
    ]
  end

  @doc "Sample sensitivity indices"
  def sample_sensitivity_indices do
    %{
      shared_buffers: %{s1: 0.25, st: 0.35},
      work_mem: %{s1: 0.15, st: 0.20},
      max_connections: %{s1: 0.05, st: 0.08},
      huge_pages: %{s1: 0.02, st: 0.03}
    }
  end

  @doc "pgbench output for parsing tests"
  def pgbench_output do
    """
    pgbench (PostgreSQL) 15.4
    transaction type: <builtin: TPC-B (sort of)>
    scaling factor: 10
    query mode: simple
    number of clients: 10
    number of threads: 2
    duration: 60 s
    number of transactions actually processed: 123456
    latency average = 4.867 ms
    initial connection time = 45.123 ms
    tps = 2054.261234 (without initial connection time)
    tps = 2057.789012 (excluding connections establishing)
    """
  end
end
