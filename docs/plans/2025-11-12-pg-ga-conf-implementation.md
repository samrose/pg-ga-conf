# PostgreSQL GA Configuration Optimizer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a hybrid (CLI + web service) system that profiles production PostgreSQL databases, generates synthetic data matching production patterns, and uses genetic algorithms to optimize PostgreSQL configuration parameters.

**Architecture:** Plugin-based architecture with behavior-driven adapters for cloud providers, workload generators, and optimization strategies. Core GA engine evolves configurations over 30 generations with parallel fitness evaluation. Nix flake provides multiple apps for different workflows (scan, generate, optimize, service).

**Tech Stack:** Elixir 1.16, OTP 26, Phoenix (API), Postgrex, Nix flakes, Docker, PostgreSQL 15

---

## Task 1: Project Setup and Dependencies

**Files:**
- Create: `mix.exs`
- Create: `.gitignore`
- Create: `config/config.exs`
- Create: `config/dev.exs`
- Create: `config/test.exs`
- Create: `config/runtime.exs`

**Step 1: Initialize Elixir project structure**

Run:
```bash
mix new . --app pg_ga_conf --module PgGaConf
```

Expected: Creates basic Elixir project structure

**Step 2: Write mix.exs with all dependencies**

File: `mix.exs`

```elixir
defmodule PgGaConf.MixProject do
  use Mix.Project

  def project do
    [
      app: :pg_ga_conf,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {PgGaConf.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Database
      {:postgrex, "~> 0.17"},
      {:db_connection, "~> 2.5"},

      # JSON
      {:jason, "~> 1.4"},

      # UUID generation
      {:elixir_uuid, "~> 1.2"},

      # HTTP client for cloud APIs
      {:req, "~> 0.4"},

      # Statistics
      {:statistics, "~> 0.6"},

      # Phoenix for web service
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.6"},
      {:cors_plug, "~> 3.0"},

      # Telemetry
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Testing
      {:ex_unit_notifier, "~> 1.3", only: :test},
      {:mix_test_watch, "~> 1.1", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["test --no-start"]
    ]
  end
end
```

**Step 3: Create .gitignore**

File: `.gitignore`

```
# Elixir
/_build
/cover
/deps
/doc
/.fetch
erl_crash.dump
*.ez
*.beam
/config/*.secret.exs
.elixir_ls/

# Development
.DS_Store
.postgres/
.nix-*
result
result-*

# Scans and results
/scans/
/results/

# Environment
.env
.envrc
```

**Step 4: Create base configuration files**

File: `config/config.exs`

```elixir
import Config

config :pg_ga_conf,
  ecto_repos: [],
  generators: [timestamp_type: :utc_datetime]

config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
```

File: `config/dev.exs`

```elixir
import Config

config :logger, level: :debug

config :pg_ga_conf,
  instance_provider: PgGaConf.Adapters.LocalPostgres,
  default_strategy: :moderate,
  default_generations: 10,
  default_population_size: 10,
  default_parallel_instances: 3
```

File: `config/test.exs`

```elixir
import Config

config :logger, level: :warning

config :pg_ga_conf,
  instance_provider: PgGaConf.Adapters.MockProvider,
  default_generations: 5,
  default_population_size: 5
```

File: `config/runtime.exs`

```elixir
import Config

if config_env() == :prod do
  config :pg_ga_conf,
    instance_provider: parse_provider(System.get_env("INSTANCE_PROVIDER", "local")),
    default_strategy: String.to_existing_atom(System.get_env("STRATEGY", "moderate")),
    default_generations: String.to_integer(System.get_env("GENERATIONS", "30")),
    default_population_size: String.to_integer(System.get_env("POPULATION_SIZE", "20")),
    default_parallel_instances: String.to_integer(System.get_env("PARALLEL_INSTANCES", "5"))
end

defp parse_provider("local"), do: PgGaConf.Adapters.LocalPostgres
defp parse_provider("supabase"), do: PgGaConf.Adapters.SupabaseCloud
defp parse_provider(_), do: PgGaConf.Adapters.LocalPostgres
```

**Step 5: Install dependencies**

Run:
```bash
mix deps.get
```

Expected: All dependencies installed successfully

**Step 6: Verify compilation**

Run:
```bash
mix compile
```

Expected: Compilation successful

---

## Task 2: Application Supervisor and Core Structure

**Files:**
- Create: `lib/pg_ga_conf/application.ex`
- Create: `lib/pg_ga_conf.ex`

**Step 1: Write application supervisor**

File: `lib/pg_ga_conf/application.ex`

```elixir
defmodule PgGaConf.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Task supervisor for parallel operations
      {Task.Supervisor, name: PgGaConf.TaskSupervisor},

      # ETS table for fitness caching
      {PgGaConf.FitnessCache, []},

      # Job storage for web API
      {PgGaConf.JobStorage, []}
    ]

    opts = [strategy: :one_for_one, name: PgGaConf.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

**Step 2: Write main module with public API**

File: `lib/pg_ga_conf.ex`

```elixir
defmodule PgGaConf do
  @moduledoc """
  PostgreSQL Genetic Algorithm Configuration Optimizer.

  Public API for optimizing PostgreSQL configurations based on
  production database profiling and genetic algorithm evolution.
  """

  alias PgGaConf.Orchestrator

  @doc """
  Optimize PostgreSQL configuration for a given database.

  ## Options

    * `:strategy` - Optimization strategy: :conservative, :moderate, :aggressive (default: :moderate)
    * `:instance_provider` - Instance provider module (default: from config)
    * `:scale_factor` - Data scale factor (default: 0.1)
    * `:generations` - Number of GA generations (default: 30)
    * `:population_size` - Population size (default: 20)
    * `:parallel_instances` - Number of parallel test instances (default: 5)
    * `:workload` - Workload generator module (default: WorkloadReplicator)

  ## Examples

      iex> PgGaConf.optimize(
      ...>   %{host: "localhost", database: "mydb", username: "postgres", password: "secret"},
      ...>   strategy: :moderate,
      ...>   generations: 30
      ...> )
      {:ok, %{optimized_config: ..., improvements: ..., scan_summary: ...}}
  """
  def optimize(connection_config, opts \\ []) do
    Orchestrator.optimize(connection_config, opts)
  end

  @doc """
  Scan a database and return profiling information.
  """
  def scan(connection_config) do
    Orchestrator.scan(connection_config)
  end

  @doc """
  Generate synthetic data based on a scan result.
  """
  def generate(scan_result, target_connection_config, opts \\ []) do
    Orchestrator.generate(scan_result, target_connection_config, opts)
  end
end
```

**Step 3: Compile and verify**

Run:
```bash
mix compile
```

Expected: Compilation successful with warnings about missing modules (we'll create them next)

---

## Task 3: Core Data Structures

**Files:**
- Create: `lib/pg_ga_conf/core/config_chromosome.ex`
- Create: `lib/pg_ga_conf/core/metrics.ex`
- Create: `lib/pg_ga_conf/core/scan_result.ex`
- Test: `test/pg_ga_conf/core/config_chromosome_test.exs`

**Step 1: Write test for ConfigChromosome**

File: `test/pg_ga_conf/core/config_chromosome_test.exs`

```elixir
defmodule PgGaConf.Core.ConfigChromosomeTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Core.ConfigChromosome

  describe "new/1" do
    test "creates chromosome with default values" do
      chromosome = ConfigChromosome.new()

      assert chromosome.shared_buffers > 0
      assert chromosome.effective_cache_size > 0
      assert chromosome.work_mem > 0
      assert chromosome.fitness == nil
      assert chromosome.generation == 0
    end

    test "creates chromosome with custom values" do
      chromosome = ConfigChromosome.new(%{
        shared_buffers: 1024,
        work_mem: 64,
        generation: 5
      })

      assert chromosome.shared_buffers == 1024
      assert chromosome.work_mem == 64
      assert chromosome.generation == 5
    end
  end

  describe "to_postgresql_conf/1" do
    test "converts chromosome to PostgreSQL config map" do
      chromosome = ConfigChromosome.new(%{
        shared_buffers: 1024,
        work_mem: 64
      })

      config = ConfigChromosome.to_postgresql_conf(chromosome)

      assert config["shared_buffers"] == "1024MB"
      assert config["work_mem"] == "64MB"
      assert is_map(config)
    end
  end

  describe "validate/1" do
    test "validates effective_cache_size >= shared_buffers" do
      valid = ConfigChromosome.new(%{
        shared_buffers: 1024,
        effective_cache_size: 2048
      })

      invalid = ConfigChromosome.new(%{
        shared_buffers: 2048,
        effective_cache_size: 1024
      })

      assert ConfigChromosome.validate(valid) == :ok
      assert {:error, _} = ConfigChromosome.validate(invalid)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run:
```bash
mix test test/pg_ga_conf/core/config_chromosome_test.exs
```

Expected: FAIL with "module PgGaConf.Core.ConfigChromosome not defined"

**Step 3: Implement ConfigChromosome**

File: `lib/pg_ga_conf/core/config_chromosome.ex`

```elixir
defmodule PgGaConf.Core.ConfigChromosome do
  @moduledoc """
  Represents a PostgreSQL configuration as a chromosome for genetic algorithm.
  """

  defstruct [
    # Memory settings (in MB)
    :shared_buffers,
    :effective_cache_size,
    :work_mem,
    :maintenance_work_mem,

    # Checkpointing & WAL
    :checkpoint_completion_target,
    :checkpoint_timeout,
    :max_wal_size,
    :wal_buffers,

    # Query planning
    :default_statistics_target,
    :random_page_cost,
    :effective_io_concurrency,

    # Parallelism
    :max_worker_processes,
    :max_parallel_workers_per_gather,
    :max_parallel_workers,

    # Autovacuum (optional, aggressive only)
    :autovacuum_scale_factor,
    :autovacuum_vacuum_cost_limit,

    # Metadata
    :fitness,
    :generation,
    :metrics
  ]

  @type t :: %__MODULE__{
    shared_buffers: non_neg_integer(),
    effective_cache_size: non_neg_integer(),
    work_mem: non_neg_integer(),
    maintenance_work_mem: non_neg_integer(),
    checkpoint_completion_target: float(),
    checkpoint_timeout: non_neg_integer(),
    max_wal_size: non_neg_integer(),
    wal_buffers: non_neg_integer(),
    default_statistics_target: non_neg_integer(),
    random_page_cost: float(),
    effective_io_concurrency: non_neg_integer(),
    max_worker_processes: non_neg_integer(),
    max_parallel_workers_per_gather: non_neg_integer(),
    max_parallel_workers: non_neg_integer(),
    autovacuum_scale_factor: float() | nil,
    autovacuum_vacuum_cost_limit: non_neg_integer() | nil,
    fitness: float() | nil,
    generation: non_neg_integer(),
    metrics: map() | nil
  }

  @doc """
  Creates a new chromosome with default or custom values.
  """
  def new(params \\ %{}) do
    defaults = %{
      shared_buffers: 256,
      effective_cache_size: 1024,
      work_mem: 4,
      maintenance_work_mem: 64,
      checkpoint_completion_target: 0.9,
      checkpoint_timeout: 300,
      max_wal_size: 1024,
      wal_buffers: 16,
      default_statistics_target: 100,
      random_page_cost: 4.0,
      effective_io_concurrency: 1,
      max_worker_processes: 8,
      max_parallel_workers_per_gather: 2,
      max_parallel_workers: 8,
      autovacuum_scale_factor: nil,
      autovacuum_vacuum_cost_limit: nil,
      fitness: nil,
      generation: 0,
      metrics: nil
    }

    struct(__MODULE__, Map.merge(defaults, params))
  end

  @doc """
  Converts chromosome to PostgreSQL configuration format.
  """
  def to_postgresql_conf(%__MODULE__{} = chromosome) do
    base_config = %{
      "shared_buffers" => "#{chromosome.shared_buffers}MB",
      "effective_cache_size" => "#{chromosome.effective_cache_size}MB",
      "work_mem" => "#{chromosome.work_mem}MB",
      "maintenance_work_mem" => "#{chromosome.maintenance_work_mem}MB",
      "checkpoint_completion_target" => Float.to_string(chromosome.checkpoint_completion_target),
      "checkpoint_timeout" => "#{chromosome.checkpoint_timeout}s",
      "max_wal_size" => "#{chromosome.max_wal_size}MB",
      "wal_buffers" => "#{chromosome.wal_buffers}MB",
      "default_statistics_target" => Integer.to_string(chromosome.default_statistics_target),
      "random_page_cost" => Float.to_string(chromosome.random_page_cost),
      "effective_io_concurrency" => Integer.to_string(chromosome.effective_io_concurrency),
      "max_worker_processes" => Integer.to_string(chromosome.max_worker_processes),
      "max_parallel_workers_per_gather" => Integer.to_string(chromosome.max_parallel_workers_per_gather),
      "max_parallel_workers" => Integer.to_string(chromosome.max_parallel_workers)
    }

    # Add autovacuum settings if present
    if chromosome.autovacuum_scale_factor do
      Map.merge(base_config, %{
        "autovacuum_scale_factor" => Float.to_string(chromosome.autovacuum_scale_factor),
        "autovacuum_vacuum_cost_limit" => Integer.to_string(chromosome.autovacuum_vacuum_cost_limit)
      })
    else
      base_config
    end
  end

  @doc """
  Validates chromosome constraints.
  """
  def validate(%__MODULE__{} = chromosome) do
    cond do
      chromosome.effective_cache_size < chromosome.shared_buffers ->
        {:error, "effective_cache_size must be >= shared_buffers"}

      chromosome.checkpoint_completion_target < 0 or chromosome.checkpoint_completion_target > 1 ->
        {:error, "checkpoint_completion_target must be between 0 and 1"}

      chromosome.max_parallel_workers < chromosome.max_parallel_workers_per_gather ->
        {:error, "max_parallel_workers must be >= max_parallel_workers_per_gather"}

      true ->
        :ok
    end
  end
end
```

**Step 4: Implement Metrics struct**

File: `lib/pg_ga_conf/core/metrics.ex`

```elixir
defmodule PgGaConf.Core.Metrics do
  @moduledoc """
  Performance metrics from benchmark runs.
  """

  defstruct [
    :transactions_per_sec,
    :p50_latency_ms,
    :p95_latency_ms,
    :p99_latency_ms,
    :cache_hit_ratio,
    :temp_files,
    :deadlocks,
    :timeouts,
    :checkpoint_sync_time_spikes,
    :duration_seconds
  ]

  @type t :: %__MODULE__{
    transactions_per_sec: float(),
    p50_latency_ms: float(),
    p95_latency_ms: float(),
    p99_latency_ms: float(),
    cache_hit_ratio: float(),
    temp_files: non_neg_integer(),
    deadlocks: non_neg_integer(),
    timeouts: non_neg_integer(),
    checkpoint_sync_time_spikes: non_neg_integer(),
    duration_seconds: non_neg_integer()
  }

  def new(params \\ %{}) do
    struct(__MODULE__, params)
  end
end
```

**Step 5: Implement ScanResult struct**

File: `lib/pg_ga_conf/core/scan_result.ex`

```elixir
defmodule PgGaConf.Core.ScanResult do
  @moduledoc """
  Result of scanning a database.
  """

  defstruct [
    :roles,
    :schemas,
    :tables,
    :columns,
    :primary_keys,
    :foreign_keys,
    :unique_constraints,
    :check_constraints,
    :indexes,
    :sequences,
    :views,
    :functions,
    :triggers,
    :enums,
    :extensions,
    :data_profiles,
    :query_patterns,
    :scanned_at
  ]

  @type t :: %__MODULE__{
    roles: list(map()),
    schemas: list(map()),
    tables: list(map()),
    columns: list(map()),
    primary_keys: list(map()),
    foreign_keys: list(map()),
    unique_constraints: list(map()),
    check_constraints: list(map()),
    indexes: list(map()),
    sequences: list(map()),
    views: list(map()),
    functions: list(map()),
    triggers: list(map()),
    enums: list(map()),
    extensions: list(map()),
    data_profiles: list(map()),
    query_patterns: list(map()) | nil,
    scanned_at: DateTime.t()
  }

  def new(params \\ %{}) do
    params_with_timestamp = Map.put_new(params, :scanned_at, DateTime.utc_now())
    struct(__MODULE__, params_with_timestamp)
  end
end
```

**Step 6: Run tests**

Run:
```bash
mix test test/pg_ga_conf/core/config_chromosome_test.exs
```

Expected: All tests PASS

**Step 7: Run all tests**

Run:
```bash
mix test
```

Expected: All tests PASS

---

## Task 4: Pattern Detector

**Files:**
- Create: `lib/pg_ga_conf/core/pattern_detector.ex`
- Test: `test/pg_ga_conf/core/pattern_detector_test.exs`

**Step 1: Write test for PatternDetector**

File: `test/pg_ga_conf/core/pattern_detector_test.exs`

```elixir
defmodule PgGaConf.Core.PatternDetectorTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Core.PatternDetector

  describe "detect_string_patterns/1" do
    test "detects email pattern" do
      values = ["user@example.com", "test@gmail.com", "admin@company.org"]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:email, confidence} = List.keyfind(patterns, :email, 0)
      assert confidence > 0.9
    end

    test "detects UUID pattern" do
      values = [
        "550e8400-e29b-41d4-a716-446655440000",
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
      ]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:uuid, confidence} = List.keyfind(patterns, :uuid, 0)
      assert confidence > 0.9
    end

    test "detects URL pattern" do
      values = ["https://example.com", "http://test.org/path"]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:url, _} = List.keyfind(patterns, :url, 0)
    end

    test "detects phone pattern" do
      values = ["+1234567890", "+1987654321", "123-456-7890"]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:phone, _} = List.keyfind(patterns, :phone, 0)
    end

    test "detects JSON pattern" do
      values = [~s({"key": "value"}), ~s([1, 2, 3])]

      patterns = PatternDetector.detect_string_patterns(values)

      assert {:json, _} = List.keyfind(patterns, :json, 0)
    end
  end

  describe "categorize_string_column/1" do
    test "categorizes as email" do
      values = ["user@example.com", "test@gmail.com"]

      assert PatternDetector.categorize_string_column(values) == :email
    end

    test "categorizes as full_name" do
      values = ["John Smith", "Jane Doe", "Bob Johnson"]

      assert PatternDetector.categorize_string_column(values) == :full_name
    end

    test "categorizes as generic_text when no pattern matches" do
      values = ["random", "text", "here"]

      assert PatternDetector.categorize_string_column(values) == :generic_text
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run:
```bash
mix test test/pg_ga_conf/core/pattern_detector_test.exs
```

Expected: FAIL with "module not defined"

**Step 3: Implement PatternDetector**

File: `lib/pg_ga_conf/core/pattern_detector.ex`

```elixir
defmodule PgGaConf.Core.PatternDetector do
  @moduledoc """
  Detects patterns in database column values.
  """

  @doc """
  Detects string patterns in a list of values.
  Returns list of {pattern_type, confidence} tuples.
  """
  def detect_string_patterns(values) when is_list(values) do
    sample = Enum.take(values, 100)
    patterns = []

    # Email pattern
    email_count = Enum.count(sample, &is_email?/1)
    patterns = if email_count > 0 do
      [{:email, email_count / length(sample)} | patterns]
    else
      patterns
    end

    # UUID pattern
    uuid_count = Enum.count(sample, &is_uuid?/1)
    patterns = if uuid_count > 0 do
      [{:uuid, uuid_count / length(sample)} | patterns]
    else
      patterns
    end

    # URL pattern
    url_count = Enum.count(sample, &is_url?/1)
    patterns = if url_count > 0 do
      [{:url, url_count / length(sample)} | patterns]
    else
      patterns
    end

    # Phone pattern
    phone_count = Enum.count(sample, &is_phone?/1)
    patterns = if phone_count > 0 do
      [{:phone, phone_count / length(sample)} | patterns]
    else
      patterns
    end

    # JSON pattern
    json_count = Enum.count(sample, &is_json?/1)
    patterns = if json_count > 0 do
      [{:json, json_count / length(sample)} | patterns]
    else
      patterns
    end

    patterns
  end

  @doc """
  Categorizes a string column based on its values.
  """
  def categorize_string_column(values) when is_list(values) do
    patterns = detect_string_patterns(values)

    cond do
      has_pattern?(patterns, :email, 0.8) -> :email
      has_pattern?(patterns, :uuid, 0.8) -> :uuid
      has_pattern?(patterns, :url, 0.8) -> :url
      has_pattern?(patterns, :phone, 0.8) -> :phone
      has_pattern?(patterns, :json, 0.8) -> :json
      all_match?(values, ~r/^[A-Z][a-z]+ [A-Z][a-z]+$/) -> :full_name
      all_match?(values, ~r/^[A-Z][a-z]+$/) -> :first_name
      all_match?(values, ~r/^\d{4}-\d{2}-\d{2}$/) -> :date_string
      all_match?(values, ~r/^[A-Z]{2,5}$/) -> :code
      true -> :generic_text
    end
  end

  # Private helpers

  defp is_email?(value) when is_binary(value) do
    String.match?(value, ~r/@.*\./)
  end
  defp is_email?(_), do: false

  defp is_uuid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end
  defp is_uuid?(_), do: false

  defp is_url?(value) when is_binary(value) do
    String.match?(value, ~r/^https?:\/\//)
  end
  defp is_url?(_), do: false

  defp is_phone?(value) when is_binary(value) do
    String.match?(value, ~r/^[\+\d\s\-\(\)]{10,}$/)
  end
  defp is_phone?(_), do: false

  defp is_json?(value) when is_binary(value) do
    String.starts_with?(value, "{") or String.starts_with?(value, "[")
  end
  defp is_json?(_), do: false

  defp has_pattern?(patterns, type, min_confidence) do
    case List.keyfind(patterns, type, 0) do
      {^type, confidence} -> confidence >= min_confidence
      nil -> false
    end
  end

  defp all_match?(values, regex) do
    sample = Enum.take(values, 20)
    match_count = Enum.count(sample, &String.match?(&1, regex))
    match_count / length(sample) > 0.8
  end
end
```

**Step 4: Run tests**

Run:
```bash
mix test test/pg_ga_conf/core/pattern_detector_test.exs
```

Expected: All tests PASS

---

## Task 5: Database Scanner - Part 1 (Basic Structure)

**Files:**
- Create: `lib/pg_ga_conf/core/database_scanner.ex`
- Test: `test/pg_ga_conf/core/database_scanner_test.exs`
- Create: `test/support/test_helpers.ex`

**Step 1: Create test helpers**

File: `test/support/test_helpers.ex`

```elixir
defmodule PgGaConf.TestHelpers do
  @moduledoc """
  Test helpers for setting up test databases.
  """

  def create_test_connection do
    {:ok, conn} = Postgrex.start_link(
      hostname: "localhost",
      username: "postgres",
      database: "pgga_test",
      pool_size: 1
    )
    conn
  end

  def setup_test_schema(conn) do
    Postgrex.query!(conn, "DROP SCHEMA IF EXISTS public CASCADE", [])
    Postgrex.query!(conn, "CREATE SCHEMA public", [])
    Postgrex.query!(conn, "CREATE EXTENSION IF NOT EXISTS pg_stat_statements", [])
  end

  def create_test_tables(conn) do
    Postgrex.query!(conn, """
      CREATE TABLE authors (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        email VARCHAR(255) UNIQUE,
        created_at TIMESTAMP DEFAULT NOW()
      )
    """, [])

    Postgrex.query!(conn, """
      CREATE TABLE books (
        id SERIAL PRIMARY KEY,
        title VARCHAR(255) NOT NULL,
        author_id INTEGER REFERENCES authors(id),
        isbn VARCHAR(13) UNIQUE,
        published_date DATE,
        price DECIMAL(10, 2)
      )
    """, [])

    Postgrex.query!(conn, """
      CREATE INDEX idx_books_author ON books(author_id)
    """, [])
  end

  def insert_test_data(conn) do
    Postgrex.query!(conn, """
      INSERT INTO authors (name, email) VALUES
      ('John Doe', 'john@example.com'),
      ('Jane Smith', 'jane@example.com')
    """, [])

    Postgrex.query!(conn, """
      INSERT INTO books (title, author_id, isbn, price) VALUES
      ('Book One', 1, '1234567890123', 29.99),
      ('Book Two', 1, '1234567890124', 39.99),
      ('Book Three', 2, '1234567890125', 19.99)
    """, [])
  end
end
```

**Step 2: Write test for DatabaseScanner**

File: `test/pg_ga_conf/core/database_scanner_test.exs`

```elixir
defmodule PgGaConf.Core.DatabaseScannerTest do
  use ExUnit.Case

  alias PgGaConf.Core.{DatabaseScanner, ScanResult}
  alias PgGaConf.TestHelpers

  setup do
    conn = TestHelpers.create_test_connection()
    TestHelpers.setup_test_schema(conn)
    TestHelpers.create_test_tables(conn)
    TestHelpers.insert_test_data(conn)

    on_exit(fn ->
      TestHelpers.setup_test_schema(conn)
      GenServer.stop(conn)
    end)

    {:ok, conn: conn}
  end

  describe "scan_database/1" do
    test "returns ScanResult struct", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      assert %ScanResult{} = result
      assert result.scanned_at != nil
    end

    test "scans tables", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      assert length(result.tables) >= 2
      assert Enum.any?(result.tables, fn t -> t.name == "authors" end)
      assert Enum.any?(result.tables, fn t -> t.name == "books" end)
    end

    test "scans columns", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      assert length(result.columns) > 0

      # Find author name column
      name_col = Enum.find(result.columns, fn c ->
        c.table == "authors" and c.name == "name"
      end)

      assert name_col != nil
      assert name_col.data_type in ["character varying", "varchar"]
      assert name_col.nullable == false
    end

    test "scans foreign keys", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      fk = Enum.find(result.foreign_keys, fn fk ->
        fk.table == "books" and "author_id" in fk.columns
      end)

      assert fk != nil
      assert fk.foreign_table =~ "authors"
    end

    test "scans indexes", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      idx = Enum.find(result.indexes, fn idx ->
        idx.name == "idx_books_author"
      end)

      assert idx != nil
      assert idx.table == "books"
    end
  end
end
```

**Step 3: Run test to verify it fails**

Run:
```bash
mix test test/pg_ga_conf/core/database_scanner_test.exs
```

Expected: FAIL with "module not defined" or connection errors (we'll handle setup later)

**Step 4: Implement DatabaseScanner (basic structure)**

File: `lib/pg_ga_conf/core/database_scanner.ex`

```elixir
defmodule PgGaConf.Core.DatabaseScanner do
  @moduledoc """
  Scans PostgreSQL databases to understand structure and data patterns.
  """

  require Logger

  alias PgGaConf.Core.{ScanResult, PatternDetector}

  @doc """
  Performs a comprehensive scan of the database.
  """
  def scan_database(conn) do
    Logger.info("Starting comprehensive database scan...")

    ScanResult.new(%{
      roles: scan_roles(conn),
      extensions: scan_extensions(conn),
      enums: scan_enums(conn),
      schemas: scan_schemas(conn),
      sequences: scan_sequences(conn),
      tables: scan_tables_detailed(conn),
      columns: scan_columns_detailed(conn),
      primary_keys: scan_primary_keys(conn),
      foreign_keys: scan_foreign_keys(conn),
      unique_constraints: scan_unique_constraints(conn),
      check_constraints: scan_check_constraints(conn),
      indexes: scan_indexes_detailed(conn),
      views: scan_views(conn),
      functions: scan_functions(conn),
      triggers: scan_triggers(conn),
      data_profiles: [],  # Will implement in next task
      query_patterns: scan_query_patterns(conn)
    })
  end

  defp scan_roles(conn) do
    case Postgrex.query(conn, """
      SELECT rolname, rolsuper, rolcreatedb, rolcreaterole
      FROM pg_roles
      WHERE rolname NOT LIKE 'pg_%'
      ORDER BY rolname
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, super, createdb, createrole] ->
          %{
            name: name,
            superuser: super,
            createdb: createdb,
            createrole: createrole
          }
        end)
      {:error, _} -> []
    end
  end

  defp scan_extensions(conn) do
    case Postgrex.query(conn, """
      SELECT extname, extversion, extnamespace::regnamespace::text as schema
      FROM pg_extension
      ORDER BY extname
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, version, schema] ->
          %{name: name, version: version, schema: schema}
        end)
      {:error, _} -> []
    end
  end

  defp scan_enums(conn) do
    case Postgrex.query(conn, """
      SELECT
        n.nspname as schema,
        t.typname as name,
        array_agg(e.enumlabel ORDER BY e.enumsortorder) as values
      FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
      JOIN pg_enum e ON e.enumtypid = t.oid
      WHERE t.typtype = 'e'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      GROUP BY n.nspname, t.typname
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, values] ->
          %{schema: schema, name: name, values: values}
        end)
      {:error, _} -> []
    end
  end

  defp scan_schemas(conn) do
    case Postgrex.query(conn, """
      SELECT schema_name
      FROM information_schema.schemata
      WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY schema_name
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name] -> %{name: name} end)
      {:error, _} -> []
    end
  end

  defp scan_sequences(conn) do
    case Postgrex.query(conn, """
      SELECT
        schemaname as schema,
        sequencename as name,
        start_value,
        increment_by
      FROM pg_sequences
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, start, increment] ->
          %{schema: schema, name: name, start_value: start, increment_by: increment}
        end)
      {:error, _} -> []
    end
  end

  defp scan_tables_detailed(conn) do
    case Postgrex.query(conn, """
      SELECT
        n.nspname as schema_name,
        c.relname as table_name,
        c.oid as table_oid,
        obj_description(c.oid, 'pg_class') as comment,
        c.relkind,
        COALESCE(pg_stat_user_tables.n_live_tup, 0) as row_count,
        pg_total_relation_size(c.oid) as total_size
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_stat_user_tables
        ON pg_stat_user_tables.schemaname = n.nspname
        AND pg_stat_user_tables.tablename = c.relname
      WHERE c.relkind IN ('r', 'p')
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY total_size DESC NULLS LAST
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, oid, comment, kind, rows, size] ->
          %{
            schema: schema,
            name: name,
            oid: oid,
            comment: comment,
            type: if(kind == "r", do: :regular, else: :partitioned),
            row_count: rows || 0,
            size_bytes: size || 0
          }
        end)
      {:error, error} ->
        Logger.warning("Failed to scan tables: #{inspect(error)}")
        []
    end
  end

  defp scan_columns_detailed(conn) do
    case Postgrex.query(conn, """
      SELECT
        c.table_schema,
        c.table_name,
        c.column_name,
        c.ordinal_position,
        c.column_default,
        c.is_nullable,
        c.data_type,
        c.udt_name,
        c.character_maximum_length,
        c.numeric_precision,
        c.numeric_scale,
        c.is_identity,
        c.identity_generation
      FROM information_schema.columns c
      WHERE c.table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY c.table_schema, c.table_name, c.ordinal_position
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, name, position, default, nullable,
                           data_type, udt_name, char_max, num_precision, num_scale,
                           is_identity, identity_gen] ->
          %{
            schema: schema,
            table: table,
            name: name,
            position: position,
            data_type: data_type,
            udt_name: udt_name,
            nullable: nullable == "YES",
            default: default,
            char_max_length: char_max,
            numeric_precision: num_precision,
            numeric_scale: num_scale,
            is_identity: is_identity == "YES",
            identity_generation: identity_gen
          }
        end)
      {:error, error} ->
        Logger.warning("Failed to scan columns: #{inspect(error)}")
        []
    end
  end

  defp scan_primary_keys(conn) do
    case Postgrex.query(conn, """
      SELECT
        connamespace::regnamespace::text as schema,
        conrelid::regclass::text as table_name,
        conname as constraint_name,
        array_agg(a.attname ORDER BY array_position(conkey, a.attnum)) as columns
      FROM pg_constraint
      JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = ANY(conkey)
      WHERE contype = 'p'
        AND connamespace::regnamespace::text NOT IN ('pg_catalog', 'information_schema')
      GROUP BY schema, table_name, constraint_name
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, name, columns] ->
          %{schema: schema, table: parse_table_name(table), name: name, columns: columns}
        end)
      {:error, _} -> []
    end
  end

  defp scan_foreign_keys(conn) do
    case Postgrex.query(conn, """
      SELECT
        conname as constraint_name,
        connamespace::regnamespace::text as schema_name,
        conrelid::regclass::text as table_name,
        array_agg(a.attname ORDER BY array_position(conkey, a.attnum)) as columns,
        confrelid::regclass::text as foreign_table,
        array_agg(af.attname ORDER BY array_position(confkey, af.attnum)) as foreign_columns,
        confupdtype as update_action,
        confdeltype as delete_action
      FROM pg_constraint
      JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = ANY(conkey)
      JOIN pg_attribute af ON af.attrelid = confrelid AND af.attnum = ANY(confkey)
      WHERE contype = 'f'
        AND connamespace::regnamespace::text NOT IN ('pg_catalog', 'information_schema')
      GROUP BY conname, schema_name, table_name, foreign_table, update_action, delete_action
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, schema, table, columns, foreign_table, foreign_columns, update, delete] ->
          %{
            name: name,
            schema: schema,
            table: parse_table_name(table),
            columns: columns,
            foreign_table: parse_table_name(foreign_table),
            foreign_columns: foreign_columns,
            on_update: decode_fk_action(update),
            on_delete: decode_fk_action(delete)
          }
        end)
      {:error, _} -> []
    end
  end

  defp scan_unique_constraints(conn) do
    case Postgrex.query(conn, """
      SELECT
        conname as constraint_name,
        connamespace::regnamespace::text as schema_name,
        conrelid::regclass::text as table_name,
        array_agg(a.attname ORDER BY array_position(conkey, a.attnum)) as columns
      FROM pg_constraint
      JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = ANY(conkey)
      WHERE contype = 'u'
        AND connamespace::regnamespace::text NOT IN ('pg_catalog', 'information_schema')
      GROUP BY conname, schema_name, table_name
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, schema, table, columns] ->
          %{name: name, schema: schema, table: parse_table_name(table), columns: columns}
        end)
      {:error, _} -> []
    end
  end

  defp scan_check_constraints(conn) do
    case Postgrex.query(conn, """
      SELECT
        conname as constraint_name,
        connamespace::regnamespace::text as schema_name,
        conrelid::regclass::text as table_name,
        pg_get_constraintdef(oid) as definition
      FROM pg_constraint
      WHERE contype = 'c'
        AND connamespace::regnamespace::text NOT IN ('pg_catalog', 'information_schema')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, schema, table, definition] ->
          %{name: name, schema: schema, table: parse_table_name(table), definition: definition}
        end)
      {:error, _} -> []
    end
  end

  defp scan_indexes_detailed(conn) do
    case Postgrex.query(conn, """
      SELECT
        schemaname as schema,
        tablename as table_name,
        indexname as index_name,
        indexdef as definition
      FROM pg_indexes
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY schemaname, tablename, indexname
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, name, definition] ->
          %{schema: schema, table: table, name: name, definition: definition}
        end)
      {:error, _} -> []
    end
  end

  defp scan_views(conn) do
    case Postgrex.query(conn, """
      SELECT
        schemaname as schema,
        viewname as name,
        definition
      FROM pg_views
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, definition] ->
          %{schema: schema, name: name, definition: definition}
        end)
      {:error, _} -> []
    end
  end

  defp scan_functions(conn) do
    case Postgrex.query(conn, """
      SELECT
        n.nspname as schema,
        p.proname as name,
        pg_get_functiondef(p.oid) as definition
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      ORDER BY schema, name
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, name, definition] ->
          %{schema: schema, name: name, definition: definition}
        end)
      {:error, _} -> []
    end
  end

  defp scan_triggers(conn) do
    case Postgrex.query(conn, """
      SELECT
        event_object_schema as schema,
        event_object_table as table_name,
        trigger_name as name,
        action_timing as timing,
        event_manipulation as event
      FROM information_schema.triggers
      WHERE event_object_schema NOT IN ('pg_catalog', 'information_schema')
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table, name, timing, event] ->
          %{schema: schema, table: table, name: name, timing: timing, event: event}
        end)
      {:error, _} -> []
    end
  end

  defp scan_query_patterns(conn) do
    case Postgrex.query(conn, """
      SELECT
        query,
        calls,
        total_exec_time / calls as avg_time_ms,
        mean_exec_time as mean_time_ms,
        rows as total_rows
      FROM pg_stat_statements
      WHERE query NOT LIKE '%pg_stat_statements%'
      ORDER BY calls DESC
      LIMIT 100
    """, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [query, calls, avg_time, mean_time, total_rows] ->
          %{
            query: query,
            calls: calls,
            avg_time_ms: avg_time,
            mean_time_ms: mean_time,
            total_rows: total_rows
          }
        end)
      {:error, _} ->
        Logger.info("pg_stat_statements not available, skipping query pattern analysis")
        nil
    end
  end

  # Helper functions

  defp decode_fk_action(code) do
    case code do
      "a" -> "NO ACTION"
      "r" -> "RESTRICT"
      "c" -> "CASCADE"
      "n" -> "SET NULL"
      "d" -> "SET DEFAULT"
      _ -> "NO ACTION"
    end
  end

  defp parse_table_name(full_name) do
    # Remove schema prefix if present (e.g., "public.books" -> "books")
    case String.split(full_name, ".", parts: 2) do
      [_, table_name] -> table_name
      [table_name] -> table_name
    end
  end
end
```

**Step 5: Run tests (may fail due to test database not being set up)**

Run:
```bash
mix test test/pg_ga_conf/core/database_scanner_test.exs
```

Expected: Tests may fail if test database doesn't exist yet - this is OK for now

**Step 6: Compile and verify no syntax errors**

Run:
```bash
mix compile
```

Expected: Compilation successful

---

## Task 6: Storage Components (FitnessCache and JobStorage)

**Files:**
- Create: `lib/pg_ga_conf/fitness_cache.ex`
- Create: `lib/pg_ga_conf/job_storage.ex`
- Test: `test/pg_ga_conf/fitness_cache_test.exs`

**Step 1: Write test for FitnessCache**

File: `test/pg_ga_conf/fitness_cache_test.exs`

```elixir
defmodule PgGaConf.FitnessCacheTest do
  use ExUnit.Case, async: true

  alias PgGaConf.FitnessCache

  setup do
    # Start cache for each test
    {:ok, pid} = FitnessCache.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  describe "get/put" do
    test "stores and retrieves fitness scores" do
      config_hash = "abc123"
      fitness = 0.85

      assert FitnessCache.get(config_hash) == nil

      :ok = FitnessCache.put(config_hash, fitness)

      assert FitnessCache.get(config_hash) == fitness
    end

    test "overwrites existing values" do
      config_hash = "def456"

      FitnessCache.put(config_hash, 0.5)
      FitnessCache.put(config_hash, 0.9)

      assert FitnessCache.get(config_hash) == 0.9
    end
  end

  describe "clear/0" do
    test "clears all cached values" do
      FitnessCache.put("key1", 0.5)
      FitnessCache.put("key2", 0.7)

      FitnessCache.clear()

      assert FitnessCache.get("key1") == nil
      assert FitnessCache.get("key2") == nil
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run:
```bash
mix test test/pg_ga_conf/fitness_cache_test.exs
```

Expected: FAIL with "module not defined"

**Step 3: Implement FitnessCache**

File: `lib/pg_ga_conf/fitness_cache.ex`

```elixir
defmodule PgGaConf.FitnessCache do
  @moduledoc """
  ETS-based cache for fitness scores to avoid re-evaluating identical configurations.
  """

  use GenServer

  @table_name :pg_ga_conf_fitness_cache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get cached fitness score for a configuration hash.
  """
  def get(config_hash) do
    case :ets.lookup(@table_name, config_hash) do
      [{^config_hash, fitness}] -> fitness
      [] -> nil
    end
  end

  @doc """
  Store fitness score for a configuration hash.
  """
  def put(config_hash, fitness) do
    :ets.insert(@table_name, {config_hash, fitness})
    :ok
  end

  @doc """
  Clear all cached fitness scores.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
```

**Step 4: Implement JobStorage**

File: `lib/pg_ga_conf/job_storage.ex`

```elixir
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
```

**Step 5: Run tests**

Run:
```bash
mix test test/pg_ga_conf/fitness_cache_test.exs
```

Expected: All tests PASS

---

## Task 7: Strategy Behaviours and Implementations

**Files:**
- Create: `lib/pg_ga_conf/strategies/strategy.ex`
- Create: `lib/pg_ga_conf/strategies/conservative.ex`
- Create: `lib/pg_ga_conf/strategies/moderate.ex`
- Create: `lib/pg_ga_conf/strategies/aggressive.ex`
- Test: `test/pg_ga_conf/strategies/moderate_test.exs`

**Step 1: Write test for Moderate strategy**

File: `test/pg_ga_conf/strategies/moderate_test.exs`

```elixir
defmodule PgGaConf.Strategies.ModerateTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Strategies.Moderate
  alias PgGaConf.Core.ConfigChromosome

  describe "parameter_bounds/0" do
    test "returns bounds for all parameters" do
      bounds = Moderate.parameter_bounds()

      assert is_map(bounds)
      assert Map.has_key?(bounds, :shared_buffers)
      assert Map.has_key?(bounds, :work_mem)
      assert Map.has_key?(bounds, :checkpoint_completion_target)
    end

    test "bounds have min <= max" do
      bounds = Moderate.parameter_bounds()

      Enum.each(bounds, fn {_param, {min, max}} ->
        assert min <= max
      end)
    end
  end

  describe "generate_random_config/0" do
    test "generates valid configuration within bounds" do
      config = Moderate.generate_random_config()

      assert %ConfigChromosome{} = config

      bounds = Moderate.parameter_bounds()

      Enum.each(bounds, fn {param, {min, max}} ->
        value = Map.get(config, param)
        assert value >= min, "#{param} value #{value} below min #{min}"
        assert value <= max, "#{param} value #{value} above max #{max}"
      end)
    end

    test "generates different configs on successive calls" do
      configs = for _ <- 1..5, do: Moderate.generate_random_config()

      # At least some should be different
      unique_shared_buffers = configs |> Enum.map(& &1.shared_buffers) |> Enum.uniq()
      assert length(unique_shared_buffers) > 1
    end
  end

  describe "mutation_rate/0" do
    test "returns reasonable mutation rate" do
      rate = Moderate.mutation_rate()

      assert rate > 0.0
      assert rate < 1.0
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run:
```bash
mix test test/pg_ga_conf/strategies/moderate_test.exs
```

Expected: FAIL with "module not defined"

**Step 3: Define Strategy behaviour**

File: `lib/pg_ga_conf/strategies/strategy.ex`

```elixir
defmodule PgGaConf.Strategies.Strategy do
  @moduledoc """
  Behaviour for GA optimization strategies.
  """

  alias PgGaConf.Core.ConfigChromosome

  @doc """
  Returns parameter bounds as %{parameter: {min, max}}.
  """
  @callback parameter_bounds() :: %{atom() => {number(), number()}}

  @doc """
  Returns mutation rate (0.0 - 1.0).
  """
  @callback mutation_rate() :: float()

  @doc """
  Returns crossover strategy (:uniform, :single_point, :smart).
  """
  @callback crossover_strategy() :: atom()

  @doc """
  Generates a random configuration within strategy bounds.
  """
  @callback generate_random_config() :: ConfigChromosome.t()
end
```

**Step 4: Implement Conservative strategy**

File: `lib/pg_ga_conf/strategies/conservative.ex`

```elixir
defmodule PgGaConf.Strategies.Conservative do
  @moduledoc """
  Conservative optimization strategy - only safe parameters.
  """

  @behaviour PgGaConf.Strategies.Strategy

  alias PgGaConf.Core.ConfigChromosome

  @impl true
  def parameter_bounds do
    %{
      shared_buffers: {128, 4096},
      effective_cache_size: {512, 16384},
      work_mem: {4, 64},
      maintenance_work_mem: {64, 512},
      default_statistics_target: {100, 200},
      random_page_cost: {1.0, 4.0}
    }
  end

  @impl true
  def mutation_rate, do: 0.1

  @impl true
  def crossover_strategy, do: :smart

  @impl true
  def generate_random_config do
    bounds = parameter_bounds()

    ConfigChromosome.new(%{
      shared_buffers: random_in_range(bounds.shared_buffers),
      effective_cache_size: random_in_range(bounds.effective_cache_size),
      work_mem: random_in_range(bounds.work_mem),
      maintenance_work_mem: random_in_range(bounds.maintenance_work_mem),
      default_statistics_target: random_in_range(bounds.default_statistics_target),
      random_page_cost: random_float_in_range(bounds.random_page_cost)
    })
  end

  defp random_in_range({min, max}) when is_integer(min) and is_integer(max) do
    min + :rand.uniform(max - min + 1) - 1
  end

  defp random_float_in_range({min, max}) when is_float(min) and is_float(max) do
    min + :rand.uniform() * (max - min)
  end

  defp random_float_in_range({min, max}) when is_number(min) and is_number(max) do
    min + :rand.uniform() * (max - min)
  end
end
```

**Step 5: Implement Moderate strategy**

File: `lib/pg_ga_conf/strategies/moderate.ex`

```elixir
defmodule PgGaConf.Strategies.Moderate do
  @moduledoc """
  Moderate optimization strategy - balanced approach (default).
  """

  @behaviour PgGaConf.Strategies.Strategy

  alias PgGaConf.Core.ConfigChromosome

  @impl true
  def parameter_bounds do
    %{
      shared_buffers: {256, 8192},
      effective_cache_size: {1024, 32768},
      work_mem: {4, 128},
      maintenance_work_mem: {64, 1024},
      checkpoint_completion_target: {0.5, 0.9},
      checkpoint_timeout: {300, 1800},
      max_wal_size: {1024, 8192},
      wal_buffers: {16, 128},
      default_statistics_target: {100, 300},
      random_page_cost: {1.0, 4.0},
      effective_io_concurrency: {1, 200},
      max_worker_processes: {8, 32},
      max_parallel_workers_per_gather: {0, 8},
      max_parallel_workers: {8, 32}
    }
  end

  @impl true
  def mutation_rate, do: 0.15

  @impl true
  def crossover_strategy, do: :smart

  @impl true
  def generate_random_config do
    bounds = parameter_bounds()

    ConfigChromosome.new(%{
      shared_buffers: random_in_range(bounds.shared_buffers),
      effective_cache_size: random_in_range(bounds.effective_cache_size),
      work_mem: random_in_range(bounds.work_mem),
      maintenance_work_mem: random_in_range(bounds.maintenance_work_mem),
      checkpoint_completion_target: random_float_in_range(bounds.checkpoint_completion_target),
      checkpoint_timeout: random_in_range(bounds.checkpoint_timeout),
      max_wal_size: random_in_range(bounds.max_wal_size),
      wal_buffers: random_in_range(bounds.wal_buffers),
      default_statistics_target: random_in_range(bounds.default_statistics_target),
      random_page_cost: random_float_in_range(bounds.random_page_cost),
      effective_io_concurrency: random_in_range(bounds.effective_io_concurrency),
      max_worker_processes: random_in_range(bounds.max_worker_processes),
      max_parallel_workers_per_gather: random_in_range(bounds.max_parallel_workers_per_gather),
      max_parallel_workers: random_in_range(bounds.max_parallel_workers)
    })
  end

  defp random_in_range({min, max}) when is_integer(min) and is_integer(max) do
    min + :rand.uniform(max - min + 1) - 1
  end

  defp random_float_in_range({min, max}) do
    min + :rand.uniform() * (max - min)
  end
end
```

**Step 6: Implement Aggressive strategy**

File: `lib/pg_ga_conf/strategies/aggressive.ex`

```elixir
defmodule PgGaConf.Strategies.Aggressive do
  @moduledoc """
  Aggressive optimization strategy - all parameters, wider bounds.
  """

  @behaviour PgGaConf.Strategies.Strategy

  alias PgGaConf.Core.ConfigChromosome

  @impl true
  def parameter_bounds do
    %{
      shared_buffers: {512, 16384},
      effective_cache_size: {2048, 65536},
      work_mem: {8, 256},
      maintenance_work_mem: {128, 2048},
      checkpoint_completion_target: {0.5, 0.95},
      checkpoint_timeout: {300, 3600},
      max_wal_size: {2048, 51200},
      wal_buffers: {32, 256},
      default_statistics_target: {100, 500},
      random_page_cost: {1.0, 4.0},
      effective_io_concurrency: {100, 1000},
      max_worker_processes: {16, 64},
      max_parallel_workers_per_gather: {2, 16},
      max_parallel_workers: {16, 64},
      autovacuum_scale_factor: {0.01, 0.2},
      autovacuum_vacuum_cost_limit: {200, 3000}
    }
  end

  @impl true
  def mutation_rate, do: 0.2

  @impl true
  def crossover_strategy, do: :smart

  @impl true
  def generate_random_config do
    bounds = parameter_bounds()

    ConfigChromosome.new(%{
      shared_buffers: random_in_range(bounds.shared_buffers),
      effective_cache_size: random_in_range(bounds.effective_cache_size),
      work_mem: random_in_range(bounds.work_mem),
      maintenance_work_mem: random_in_range(bounds.maintenance_work_mem),
      checkpoint_completion_target: random_float_in_range(bounds.checkpoint_completion_target),
      checkpoint_timeout: random_in_range(bounds.checkpoint_timeout),
      max_wal_size: random_in_range(bounds.max_wal_size),
      wal_buffers: random_in_range(bounds.wal_buffers),
      default_statistics_target: random_in_range(bounds.default_statistics_target),
      random_page_cost: random_float_in_range(bounds.random_page_cost),
      effective_io_concurrency: random_in_range(bounds.effective_io_concurrency),
      max_worker_processes: random_in_range(bounds.max_worker_processes),
      max_parallel_workers_per_gather: random_in_range(bounds.max_parallel_workers_per_gather),
      max_parallel_workers: random_in_range(bounds.max_parallel_workers),
      autovacuum_scale_factor: random_float_in_range(bounds.autovacuum_scale_factor),
      autovacuum_vacuum_cost_limit: random_in_range(bounds.autovacuum_vacuum_cost_limit)
    })
  end

  defp random_in_range({min, max}) when is_integer(min) and is_integer(max) do
    min + :rand.uniform(max - min + 1) - 1
  end

  defp random_float_in_range({min, max}) do
    min + :rand.uniform() * (max - min)
  end
end
```

**Step 7: Run tests**

Run:
```bash
mix test test/pg_ga_conf/strategies/moderate_test.exs
```

Expected: All tests PASS

---

## Task 8: Nix Flake

**Files:**
- Create: `flake.nix`
- Create: `flake.lock` (will be generated)

**Step 1: Create Nix flake**

File: `flake.nix`

```nix
{
  description = "PostgreSQL Genetic Algorithm Configuration Optimizer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Elixir and Erlang versions
        beam = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_26;
        elixir = beam.elixir_1_16;

        # PostgreSQL for local development
        postgresql = pkgs.postgresql_15;

      in {
        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = [
            elixir
            postgresql
            pkgs.git
            pkgs.docker
            pkgs.curl
            pkgs.jq
          ];

          shellHook = ''
            # Set up PostgreSQL data directory
            export PGDATA="$PWD/.postgres"
            export PGHOST="localhost"
            export PGPORT=5432
            export DATABASE_URL="postgresql://postgres@localhost:5432/pgga_dev"

            # Initialize PostgreSQL if needed
            if [ ! -d "$PGDATA" ]; then
              echo "Initializing PostgreSQL database..."
              initdb -U postgres --no-locale --encoding=UTF8
              echo "unix_socket_directories = '$PGDATA'" >> "$PGDATA/postgresql.conf"
              echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"

              # Start postgres temporarily to set up
              pg_ctl start -l "$PGDATA/logfile" -o "-c unix_socket_directories=$PGDATA"
              sleep 2

              # Create development database
              createdb -h localhost -U postgres pgga_dev

              # Enable required extensions
              psql -h localhost -U postgres -d pgga_dev -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

              pg_ctl stop
            fi

            echo "PostgreSQL ready. Commands:"
            echo "  pg_start     - Start PostgreSQL"
            echo "  pg_stop      - Stop PostgreSQL"
            echo "  pg_connect   - Connect to dev database"
            echo ""
            echo "Elixir commands:"
            echo "  mix deps.get - Install dependencies"
            echo "  mix test     - Run tests"
            echo "  iex -S mix   - Start interactive shell"

            # Helper functions
            pg_start() {
              pg_ctl start -l "$PGDATA/logfile" -o "-c unix_socket_directories=$PGDATA"
            }

            pg_stop() {
              pg_ctl stop
            }

            pg_connect() {
              psql -h localhost -U postgres pgga_dev
            }

            export -f pg_start pg_stop pg_connect
          '';
        };

        # Flake apps for different operations
        apps = {
          # Quick development mode
          dev = {
            type = "app";
            program = toString (pkgs.writeShellScript "pg-ga-dev" ''
              export PGDATA="$PWD/.postgres"

              if [ ! -d "$PGDATA" ]; then
                echo "Setting up development environment..."
                ${postgresql}/bin/initdb -U postgres --no-locale --encoding=UTF8
                echo "unix_socket_directories = '$PGDATA'" >> "$PGDATA/postgresql.conf"
              fi

              ${postgresql}/bin/pg_ctl start -l "$PGDATA/logfile" -o "-c unix_socket_directories=$PGDATA"

              echo "PostgreSQL started. Press Ctrl+C to stop"

              # Cleanup on exit
              trap "${postgresql}/bin/pg_ctl stop" EXIT

              # Keep running
              tail -f "$PGDATA/logfile"
            '');
          };
        };
      }
    );
}
```

**Step 2: Initialize flake lock**

Run:
```bash
nix flake lock
```

Expected: Creates `flake.lock` file

**Step 3: Test dev shell**

Run:
```bash
nix develop
```

Expected: Enters development shell with PostgreSQL initialized

**Step 4: Exit dev shell and verify**

Run:
```bash
exit
```

Expected: Back to normal shell

---

Due to length constraints, I'll continue this plan in the next section. The remaining tasks are:

- Task 9-12: Instance Providers (Behaviour, Local, Supabase, Mock)
- Task 13-16: GA Engine (Population, Evolution, Fitness, Selection)
- Task 17: Benchmark System
- Task 18-19: Smart Data Generator
- Task 20: Orchestrator
- Task 21-22: CLI and Web API
- Task 23: Integration Tests
- Task 24: Documentation

Would you like me to continue with the remaining tasks?
