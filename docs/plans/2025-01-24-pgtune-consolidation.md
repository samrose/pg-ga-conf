# PgTune Consolidation: Runtime Adaptive Tuning

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Consolidate pgtune's runtime adaptive capabilities into pg-ga-conf, creating a unified system that:
1. Fingerprints workloads on startup and matches to cached optimized configs
2. Monitors for workload changes using E-Divisive change detection (via Pythonx)
3. Triggers Sobol/TPE optimization when no cached profile matches
4. Stores new fingerprint→config mappings for future instant lookup

**Architecture:**

```
┌─────────────────────────────────────────────────────────────────────┐
│                         pg-ga-conf (Elixir)                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────────┐    │
│  │ Fingerprint │───▶│ ProfileCache │───▶│ Config Application  │    │
│  │  (existing) │    │    (new)     │    │ (PostgresLifecycle) │    │
│  └─────────────┘    └──────────────┘    └─────────────────────┘    │
│         │                  │                                        │
│         │                  │ no match                               │
│         │                  ▼                                        │
│         │           ┌──────────────┐                                │
│         │           │ Sobol + TPE  │                                │
│         │           │  (existing)  │                                │
│         │           └──────────────┘                                │
│         │                  │                                        │
│         ▼                  │ save new profile                       │
│  ┌─────────────┐           │                                        │
│  │   Monitor   │◀──────────┘                                        │
│  │    (new)    │                                                    │
│  └──────┬──────┘                                                    │
│         │                                                           │
│         │ periodic check                                            │
│         ▼                                                           │
│  ┌─────────────────┐                                                │
│  │  ChangeDetector │  ◀── E-Divisive via Pythonx                    │
│  │      (new)      │      (ported from pgtune/otava)                │
│  └─────────────────┘                                                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Tech Stack:** Elixir 1.16+, Pythonx (for E-Divisive), existing pg-ga-conf modules

---

## Task 1: ProfileCache Schema and Storage

**Files:**
- Create: `lib/pg_ga_conf/schema/workload_profile.ex`
- Create: `lib/pg_ga_conf/profile_cache.ex`
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_create_workload_profiles.exs`

**Step 1: Define WorkloadProfile schema**

File: `lib/pg_ga_conf/schema/workload_profile.ex`

```elixir
defmodule PgGaConf.Schema.WorkloadProfile do
  @moduledoc """
  Stores workload fingerprints with their optimized configurations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "workload_profiles" do
    field :fingerprint, :map
    field :fingerprint_vector, {:array, :float}
    field :workload_type, Ecto.Enum, values: [:oltp, :olap, :mixed]
    field :config, :map
    field :optimization_method, :string
    field :optimization_score, :float
    field :sobol_sensitivities, :map
    field :times_matched, :integer, default: 0
    field :last_matched_at, :utc_datetime
    field :source_database, :string
    field :benchmark_type, :string

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :fingerprint, :fingerprint_vector, :workload_type, :config,
      :optimization_method, :optimization_score, :sobol_sensitivities,
      :times_matched, :last_matched_at, :source_database, :benchmark_type
    ])
    |> validate_required([:fingerprint, :fingerprint_vector, :config])
  end
end
```

**Step 2: Create ProfileCache module**

File: `lib/pg_ga_conf/profile_cache.ex`

```elixir
defmodule PgGaConf.ProfileCache do
  @moduledoc """
  Cache for workload fingerprint → optimized config mappings.
  """

  alias PgGaConf.{Repo, Fingerprint}
  alias PgGaConf.Schema.WorkloadProfile
  import Ecto.Query

  @similarity_threshold 0.85

  @spec find_matching_profile(Fingerprint.fingerprint()) ::
    {:ok, {float(), WorkloadProfile.t()}} | {:no_match, float()}
  def find_matching_profile(fingerprint) do
    current_vector = Fingerprint.fingerprint_to_vector(fingerprint)
    profiles = Repo.all(WorkloadProfile)

    case find_best_match(current_vector, profiles) do
      {similarity, profile} when similarity >= @similarity_threshold ->
        update_match_stats(profile)
        {:ok, {similarity, profile}}

      {similarity, _profile} ->
        {:no_match, similarity}
    end
  end

  @spec store_profile(Fingerprint.fingerprint(), map(), keyword()) ::
    {:ok, WorkloadProfile.t()} | {:error, Ecto.Changeset.t()}
  def store_profile(fingerprint, config, opts \\ []) do
    vector = Fingerprint.fingerprint_to_vector(fingerprint)
    workload_type = Fingerprint.classify(fingerprint)

    attrs = %{
      fingerprint: fingerprint,
      fingerprint_vector: vector,
      workload_type: workload_type,
      config: config,
      optimization_method: Keyword.get(opts, :method, "sobol_tpe"),
      optimization_score: Keyword.get(opts, :score),
      sobol_sensitivities: Keyword.get(opts, :sensitivities),
      source_database: Keyword.get(opts, :source_database),
      benchmark_type: Keyword.get(opts, :benchmark_type)
    }

    %WorkloadProfile{}
    |> WorkloadProfile.changeset(attrs)
    |> Repo.insert()
  end

  def list_profiles(opts \\ []) do
    query = from(p in WorkloadProfile, order_by: [desc: p.times_matched])

    query = case Keyword.get(opts, :workload_type) do
      nil -> query
      type -> from(p in query, where: p.workload_type == ^type)
    end

    Repo.all(query)
  end

  def similarity_threshold, do: @similarity_threshold

  defp find_best_match(_vector, []), do: {0.0, nil}

  defp find_best_match(current_vector, profiles) do
    profiles
    |> Enum.map(fn profile ->
      similarity = cosine_similarity(current_vector, profile.fingerprint_vector)
      {similarity, profile}
    end)
    |> Enum.max_by(fn {sim, _} -> sim end)
  end

  defp cosine_similarity(vec1, vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    magnitude1 = :math.sqrt(Enum.map(vec1, &(&1 * &1)) |> Enum.sum())
    magnitude2 = :math.sqrt(Enum.map(vec2, &(&1 * &1)) |> Enum.sum())

    if magnitude1 == 0 or magnitude2 == 0, do: 0.0, else: dot_product / (magnitude1 * magnitude2)
  end

  defp update_match_stats(profile) do
    from(p in WorkloadProfile, where: p.id == ^profile.id)
    |> Repo.update_all(set: [times_matched: profile.times_matched + 1, last_matched_at: DateTime.utc_now()])
  end
end
```

**Step 3: Create migration**

```bash
mix ecto.gen.migration create_workload_profiles
```

Then edit the migration file:

```elixir
defmodule PgGaConf.Repo.Migrations.CreateWorkloadProfiles do
  use Ecto.Migration

  def change do
    create table(:workload_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :fingerprint, :map, null: false
      add :fingerprint_vector, {:array, :float}, null: false
      add :workload_type, :string, null: false
      add :config, :map, null: false
      add :optimization_method, :string
      add :optimization_score, :float
      add :sobol_sensitivities, :map
      add :times_matched, :integer, default: 0
      add :last_matched_at, :utc_datetime
      add :source_database, :string
      add :benchmark_type, :string

      timestamps()
    end

    create index(:workload_profiles, [:workload_type])
    create index(:workload_profiles, [:times_matched])
  end
end
```

---

## Task 2: Change Detector with Pythonx (E-Divisive)

**Files:**
- Create: `lib/pg_ga_conf/runtime/change_detector.ex`
- Create: `priv/python/e_divisive.py`

**Step 1: Create Python E-Divisive module**

File: `priv/python/e_divisive.py`

```python
"""E-Divisive change point detection algorithm."""

import numpy as np
from scipy import stats
from typing import List, Optional

def detect_change_points(
    data: List[float],
    window_len: int = 50,
    max_pvalue: float = 0.05,
    min_magnitude: float = 0.05
) -> List[dict]:
    """Detect change points using E-Divisive algorithm."""
    if len(data) < window_len * 2:
        return []

    changes = []
    arr = np.array(data)

    for i in range(window_len, len(arr) - window_len):
        before = arr[i - window_len:i]
        after = arr[i:i + window_len]
        t_stat, p_value = stats.ttest_ind(before, after)

        if p_value <= max_pvalue:
            before_mean = np.mean(before)
            after_mean = np.mean(after)
            magnitude = (after_mean - before_mean) / abs(before_mean) if before_mean != 0 else float('inf')

            if abs(magnitude) >= min_magnitude:
                changes.append({
                    'position': i,
                    'magnitude': float(magnitude),
                    'p_value': float(p_value),
                    'direction': 'increase' if magnitude > 0 else 'decrease',
                    'before_mean': float(before_mean),
                    'after_mean': float(after_mean)
                })

    return deduplicate_changes(changes, window_len // 2)

def deduplicate_changes(changes: List[dict], min_distance: int) -> List[dict]:
    if not changes:
        return []
    sorted_changes = sorted(changes, key=lambda x: x['p_value'])
    kept = []
    used_positions = set()

    for change in sorted_changes:
        pos = change['position']
        if not any(abs(pos - used) < min_distance for used in used_positions):
            kept.append(change)
            used_positions.add(pos)

    return sorted(kept, key=lambda x: x['position'])

def analyze_metric_buffer(buffer: List[List], window_minutes: int = 30) -> Optional[dict]:
    if len(buffer) < 10:
        return None
    values = [v for _, v in buffer]
    changes = detect_change_points(values, window_len=max(10, len(values) // 4))
    return changes[-1] if changes else None
```

**Step 2: Create Elixir ChangeDetector module**

File: `lib/pg_ga_conf/runtime/change_detector.ex`

```elixir
defmodule PgGaConf.Runtime.ChangeDetector do
  @moduledoc """
  Detects workload changes using E-Divisive algorithm via Pythonx.
  """

  use GenServer
  require Logger

  @default_check_interval_ms 60_000
  @max_buffer_size 500

  defstruct [:repo, :metric_buffers, :last_fingerprint, :window_minutes, :check_interval_ms, :on_change_callback]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def record_fingerprint(server \\ __MODULE__, fingerprint) do
    GenServer.cast(server, {:record_fingerprint, fingerprint})
  end

  def check_now(server \\ __MODULE__) do
    GenServer.call(server, :check_now)
  end

  @impl true
  def init(opts) do
    init_python()

    state = %__MODULE__{
      repo: Keyword.get(opts, :repo),
      metric_buffers: %{},
      last_fingerprint: nil,
      window_minutes: Keyword.get(opts, :window_minutes, 30),
      check_interval_ms: Keyword.get(opts, :check_interval_ms, @default_check_interval_ms),
      on_change_callback: Keyword.get(opts, :on_change)
    }

    schedule_check(state.check_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:record_fingerprint, fingerprint}, state) do
    timestamp = System.system_time(:second)
    buffers = state.metric_buffers
    |> update_buffer(:buffer_hit_ratio, {timestamp, fingerprint.heap_blks_hit_ratio})
    |> update_buffer(:seq_scan_ratio, {timestamp, fingerprint.seq_scan_ratio})
    |> update_buffer(:index_scan_ratio, {timestamp, fingerprint.index_scan_ratio})

    {:noreply, %{state | metric_buffers: buffers, last_fingerprint: fingerprint}}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    case detect_changes(state) do
      {:changes_detected, changes} ->
        handle_changes(changes, state)
        {:reply, {:ok, changes}, state}
      :no_changes ->
        {:reply, :no_changes, state}
    end
  end

  @impl true
  def handle_info(:check_for_changes, state) do
    case detect_changes(state) do
      {:changes_detected, changes} -> handle_changes(changes, state)
      :no_changes -> :ok
    end
    schedule_check(state.check_interval_ms)
    {:noreply, state}
  end

  defp init_python do
    Pythonx.uv_init("""
    [project]
    name = "pg_ga_conf_change_detector"
    version = "0.1.0"
    dependencies = ["numpy", "scipy"]
    """)
  end

  defp update_buffer(buffers, metric, sample) do
    buffer = Map.get(buffers, metric, [])
    buffer = [sample | buffer] |> Enum.take(@max_buffer_size)
    Map.put(buffers, metric, buffer)
  end

  defp detect_changes(state) do
    changes = state.metric_buffers
    |> Enum.map(fn {metric, buffer} ->
      case analyze_buffer(buffer, state.window_minutes) do
        {:ok, change} -> {metric, change}
        :no_change -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    if Enum.empty?(changes), do: :no_changes, else: {:changes_detected, changes}
  end

  defp analyze_buffer(buffer, window_minutes) when length(buffer) < 10, do: :no_change
  defp analyze_buffer(buffer, window_minutes) do
    data = buffer |> Enum.reverse() |> Enum.map(fn {ts, val} -> [ts, val] end)

    {result, _} = Pythonx.eval("""
    import sys
    sys.path.insert(0, priv_path)
    import e_divisive
    e_divisive.analyze_metric_buffer(data, window_minutes=window_minutes)
    """, %{
      "data" => data,
      "window_minutes" => window_minutes,
      "priv_path" => Path.join(:code.priv_dir(:pg_ga_conf), "python")
    })

    case result do
      nil -> :no_change
      change -> {:ok, change}
    end
  end

  defp handle_changes(changes, state) do
    Logger.info("Workload changes detected: #{inspect(changes)}")
    if state.on_change_callback, do: state.on_change_callback.(changes, state.last_fingerprint)
  end

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check_for_changes, interval_ms)
  end
end
```

---

## Task 3: Runtime Monitor

**Files:**
- Create: `lib/pg_ga_conf/runtime/monitor.ex`

File: `lib/pg_ga_conf/runtime/monitor.ex`

```elixir
defmodule PgGaConf.Runtime.Monitor do
  @moduledoc """
  Monitors PostgreSQL workloads and adapts configuration automatically.

  Workflow:
  1. On Start: Extract fingerprint, lookup cached profile, apply config
  2. Periodic: Re-extract fingerprint, compare to last known state
  3. On Change: Lookup new fingerprint in cache, apply or trigger optimization
  4. On Optimization Complete: Store new profile in cache
  """

  use GenServer
  require Logger

  alias PgGaConf.{Fingerprint, ProfileCache, Optimizer}
  alias PgGaConf.Runtime.ChangeDetector

  @fingerprint_interval_ms 60_000
  @similarity_threshold 0.85

  defstruct [:repo, :current_fingerprint, :current_profile, :change_detector,
             :postgres_lifecycle, :on_config_change, :fingerprint_interval_ms,
             :optimization_in_progress]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now, 30_000)
  def optimize_now(server \\ __MODULE__), do: GenServer.call(server, :optimize_now, :infinity)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      postgres_lifecycle: Keyword.get(opts, :postgres_lifecycle),
      on_config_change: Keyword.get(opts, :on_config_change),
      fingerprint_interval_ms: Keyword.get(opts, :fingerprint_interval_ms, @fingerprint_interval_ms),
      optimization_in_progress: false
    }
    send(self(), :initial_setup)
    {:ok, state}
  end

  @impl true
  def handle_info(:initial_setup, state) do
    Logger.info("Monitor: Starting initial workload fingerprinting...")

    case Fingerprint.extract(state.repo) do
      {:ok, fingerprint} ->
        Logger.info("Monitor: Workload type: #{Fingerprint.classify(fingerprint)}")
        state = %{state | current_fingerprint: fingerprint}

        state = case ProfileCache.find_matching_profile(fingerprint) do
          {:ok, {similarity, profile}} ->
            Logger.info("Monitor: Found matching profile (similarity: #{Float.round(similarity, 3)})")
            apply_profile(profile, state)
            %{state | current_profile: profile}

          {:no_match, best} ->
            Logger.info("Monitor: No matching profile (best: #{Float.round(best, 3)})")
            state
        end

        {:ok, detector} = ChangeDetector.start_link(
          repo: state.repo,
          on_change: fn changes, fp -> send(self(), {:workload_change, changes, fp}) end
        )

        schedule_fingerprint(state.fingerprint_interval_ms)
        {:noreply, %{state | change_detector: detector}}

      {:error, reason} ->
        Logger.error("Monitor: Failed to extract fingerprint: #{inspect(reason)}")
        Process.send_after(self(), :initial_setup, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:periodic_fingerprint, state) do
    case Fingerprint.extract(state.repo) do
      {:ok, fingerprint} ->
        if state.change_detector, do: ChangeDetector.record_fingerprint(state.change_detector, fingerprint)
        state = check_fingerprint_drift(fingerprint, state)
        schedule_fingerprint(state.fingerprint_interval_ms)
        {:noreply, %{state | current_fingerprint: fingerprint}}

      {:error, _} ->
        schedule_fingerprint(state.fingerprint_interval_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:workload_change, _changes, fingerprint}, state) do
    case ProfileCache.find_matching_profile(fingerprint) do
      {:ok, {similarity, profile}} ->
        Logger.info("Monitor: Found profile for changed workload (similarity: #{Float.round(similarity, 3)})")
        apply_profile(profile, state)
        {:noreply, %{state | current_profile: profile, current_fingerprint: fingerprint}}

      {:no_match, _} ->
        Logger.info("Monitor: No cached profile, optimization recommended")
        {:noreply, %{state | current_fingerprint: fingerprint}}
    end
  end

  @impl true
  def handle_info({:optimization_complete, {:ok, config, score}}, state) do
    Logger.info("Monitor: Optimization complete, score: #{score}")
    {:ok, profile} = ProfileCache.store_profile(state.current_fingerprint, config, method: "sobol_tpe", score: score)
    apply_profile(profile, state)
    {:noreply, %{state | current_profile: profile, optimization_in_progress: false}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{
      workload_type: state.current_fingerprint && Fingerprint.classify(state.current_fingerprint),
      profile_id: state.current_profile && state.current_profile.id,
      optimization_in_progress: state.optimization_in_progress
    }, state}
  end

  @impl true
  def handle_call(:optimize_now, _from, state) do
    if state.optimization_in_progress do
      {:reply, {:error, :in_progress}, state}
    else
      start_optimization(state)
      {:reply, :ok, %{state | optimization_in_progress: true}}
    end
  end

  defp check_fingerprint_drift(new_fp, state) do
    if state.current_profile do
      similarity = Fingerprint.similarity(new_fp, state.current_profile.fingerprint)
      if similarity < @similarity_threshold do
        Logger.info("Monitor: Workload drift detected (similarity: #{Float.round(similarity, 3)})")
        send(self(), {:workload_change, :drift, new_fp})
      end
    end
    state
  end

  defp apply_profile(profile, state) do
    Logger.info("Monitor: Applying profile #{profile.id}")
    cond do
      state.postgres_lifecycle -> state.postgres_lifecycle.apply_config(profile.config)
      state.on_config_change -> state.on_config_change.(profile.config)
      true -> Logger.warning("Monitor: No config application method configured")
    end
  end

  defp start_optimization(state) do
    parent = self()
    Task.start(fn ->
      result = Optimizer.optimize(state.repo, fingerprint: state.current_fingerprint, method: :tpe)
      send(parent, {:optimization_complete, result})
    end)
  end

  defp schedule_fingerprint(interval), do: Process.send_after(self(), :periodic_fingerprint, interval)
end
```

---

## Task 4: Calibration Mix Task

**Files:**
- Create: `lib/mix/tasks/pg_ga_conf.calibrate.ex`

File: `lib/mix/tasks/pg_ga_conf.calibrate.ex`

```elixir
defmodule Mix.Tasks.PgGaConf.Calibrate do
  @moduledoc """
  Build workload profile cache by running standard benchmarks.

  Usage:
      mix pg_ga_conf.calibrate
      mix pg_ga_conf.calibrate --benchmarks pgbench,tpcc
      mix pg_ga_conf.calibrate --scale 10
      mix pg_ga_conf.calibrate --fingerprint-only
  """

  use Mix.Task
  require Logger

  alias PgGaConf.{Fingerprint, ProfileCache, Optimizer, PostgresLifecycle}

  @benchmarks [
    {:pgbench_default, "pgbench TPC-B", []},
    {:pgbench_select, "pgbench Select-Only", ["-S"]},
    {:tpcc, "TPC-C (go-tpc)", :tpcc},
    {:tpch, "TPC-H (go-tpc)", :tpch}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [
      benchmarks: :string, scale: :integer, fingerprint_only: :boolean,
      warmup: :integer, duration: :integer
    ])

    Mix.Task.run("app.start")

    scale = opts[:scale] || 1
    fingerprint_only = opts[:fingerprint_only] || false
    warmup = opts[:warmup] || 30
    duration = opts[:duration] || 60

    {:ok, lifecycle} = PostgresLifecycle.start_test_instance()

    try do
      for {key, name, bench_opts} <- filter_benchmarks(opts[:benchmarks]) do
        Logger.info("\n=== Running #{name} ===")

        init_benchmark(key, scale, lifecycle)
        run_benchmark(key, bench_opts, lifecycle, %{warmup: warmup, duration: duration, scale: scale})

        {:ok, fingerprint} = Fingerprint.extract(lifecycle.repo)
        Logger.info("Workload type: #{Fingerprint.classify(fingerprint)}")

        unless fingerprint_only do
          case ProfileCache.find_matching_profile(fingerprint) do
            {:ok, {sim, _}} when sim > 0.95 ->
              Logger.info("Profile exists (similarity: #{sim})")

            _ ->
              {:ok, config, score} = Optimizer.optimize(lifecycle.repo, fingerprint: fingerprint, method: :tpe)
              {:ok, profile} = ProfileCache.store_profile(fingerprint, config, method: "sobol_tpe", score: score, benchmark_type: to_string(key))
              Logger.info("Profile saved: #{profile.id}")
          end
        end
      end

      Logger.info("\n=== Calibration Complete ===")
      Logger.info("Profiles in cache: #{length(ProfileCache.list_profiles())}")
    after
      PostgresLifecycle.stop_instance(lifecycle)
    end
  end

  defp filter_benchmarks(nil), do: @benchmarks
  defp filter_benchmarks(str) do
    requested = String.split(str, ",") |> Enum.map(&String.to_atom/1)
    Enum.filter(@benchmarks, fn {key, _, _} -> key in requested end)
  end

  defp init_benchmark(:pgbench_default, scale, lc), do: run_cmd("pgbench", pgbench_init_args(lc, scale))
  defp init_benchmark(:pgbench_select, scale, lc), do: run_cmd("pgbench", pgbench_init_args(lc, scale))
  defp init_benchmark(:tpcc, scale, lc), do: run_cmd("go-tpc", ["tpcc", "prepare" | tpc_args(lc, scale)])
  defp init_benchmark(:tpch, scale, lc), do: run_cmd("go-tpc", ["tpch", "prepare" | tpc_args(lc, scale)])

  defp run_benchmark(key, extra, lc, opts) when key in [:pgbench_default, :pgbench_select] do
    run_cmd("pgbench", pgbench_run_args(lc, opts.duration) ++ extra)
  end
  defp run_benchmark(:tpcc, _, lc, opts), do: run_cmd("go-tpc", ["tpcc", "run", "--time", "#{opts.duration}s" | tpc_args(lc, opts.scale)])
  defp run_benchmark(:tpch, _, lc, opts), do: run_cmd("go-tpc", ["tpch", "run" | tpc_args(lc, opts.scale)])

  defp pgbench_init_args(lc, scale), do: ["-h", lc.host, "-p", "#{lc.port}", "-U", lc.user, "-d", lc.database, "-i", "-s", "#{scale}"]
  defp pgbench_run_args(lc, dur), do: ["-h", lc.host, "-p", "#{lc.port}", "-U", lc.user, "-d", lc.database, "-c", "10", "-T", "#{dur}"]
  defp tpc_args(lc, scale), do: ["-H", lc.host, "-P", "#{lc.port}", "-D", lc.database, "--warehouses", "#{scale}"]

  defp run_cmd(cmd, args), do: System.cmd(cmd, args, stderr_to_stdout: true)
end
```

---

## Summary

This plan adds runtime adaptive tuning to pg-ga-conf:

| Module | Purpose |
|--------|---------|
| `ProfileCache` | Stores fingerprint → config mappings |
| `ChangeDetector` | E-Divisive via Pythonx |
| `Monitor` | Orchestrates fingerprint → lookup → adapt |
| `mix pg_ga_conf.calibrate` | Builds profile cache from benchmarks |

**Workflow:**

```
Workload Starts
    ↓
Extract Fingerprint (existing)
    ↓
Lookup in ProfileCache
    ↓
┌──────────────┬─────────────────┐
│ Match Found  │ No Match        │
│ (sim > 0.85) │                 │
├──────────────┼─────────────────┤
│ Apply cached │ Run Sobol/TPE   │
│ config       │ via Pythonx     │
│              │      ↓          │
│              │ Store profile   │
└──────────────┴─────────────────┘
    ↓
Monitor for Changes (ChangeDetector)
    ↓
On Change → Re-fingerprint → Lookup → Adapt
```

No Docker, no Graphite, no separate services - everything in-process with Python via Pythonx.
