defmodule Mix.Tasks.PatternDemo do
  @moduledoc """
  Demo the Workload Pattern Discovery System end-to-end.

  ## Usage

      # Start databases first
      pg_start_all

      # Run the demo
      mix pattern_demo

  ## What it does

  1. Profiles the current database with RichProfiler (59 features)
  2. Creates simulated fleet profiles
  3. Runs DBSCAN pattern discovery
  4. Demonstrates pattern matching
  5. Shows maintenance stats
  """

  use Mix.Task

  alias PgGaConf.Repo
  alias PgGaConf.Workload.RichProfiler
  alias PgGaConf.PatternDiscovery
  alias PgGaConf.PatternMatcher
  alias PgGaConf.PatternMaintenance
  alias PgGaConf.Schema.{DatabaseProfile, WorkloadPattern, PatternAssignment}

  @shortdoc "Demo the pattern discovery system"

  @impl Mix.Task
  def run(args) do
    # Start the application
    Mix.Task.run("app.start")

    clean? = "--clean" in args

    IO.puts("""

    ╔══════════════════════════════════════════════════════════════════╗
    ║           Workload Pattern Discovery System Demo                  ║
    ╚══════════════════════════════════════════════════════════════════╝
    """)

    if clean? do
      IO.puts("Cleaning existing data...")
      Repo.delete_all(PatternAssignment)
      Repo.delete_all(WorkloadPattern)
      Repo.delete_all(DatabaseProfile)
      IO.puts("  ✓ Cleaned\n")
    end

    # Step 1: Profile
    step_1_profile()

    # Step 2: Check/create fleet
    step_2_fleet()

    # Step 3: Discover patterns
    step_3_discover()

    # Step 4: Pattern matching
    step_4_match()

    # Step 5: Stats
    step_5_stats()

    IO.puts("""

    ╔══════════════════════════════════════════════════════════════════╗
    ║                        Demo Complete!                             ║
    ╚══════════════════════════════════════════════════════════════════╝

    Next steps:
      • Run `mix pattern_demo --clean` to reset and re-run
      • Use `PatternMatcher.get_knobs_for_database/3` in TuningJob
      • Set up scheduled `PatternMaintenance.run_maintenance/2`

    """)
  end

  defp step_1_profile do
    IO.puts("━━━ Step 1: Profile Current Database ━━━\n")

    case RichProfiler.quick_profile(Repo) do
      {:ok, profile} ->
        IO.puts("  Feature vector: #{length(profile.feature_vector)} dimensions")
        IO.puts("  PostgreSQL version: #{div(profile.pg_version, 10000)}.#{rem(div(profile.pg_version, 100), 100)}")
        IO.puts("  pg_stat_statements: #{if profile.has_pg_stat_statements, do: "available", else: "not installed"}")
        IO.puts("")
        IO.puts("  Schema layer:")
        IO.puts("    Tables: #{trunc(profile.schema_features.table_count)}")
        IO.puts("    Avg columns: #{Float.round(profile.schema_features.avg_columns, 1)}")
        IO.puts("    JSONB ratio: #{pct(profile.schema_features.jsonb_ratio)}")
        IO.puts("")
        IO.puts("  Query layer:")
        IO.puts("    SELECT ratio: #{pct(profile.query_features.select_ratio)}")
        IO.puts("    Cache hit ratio: #{pct(profile.query_features.cache_hit_ratio)}")
        IO.puts("    Parameterized: #{pct(profile.query_features.parameterized_ratio)}")
        IO.puts("")

        {:ok, profile}

      {:error, reason} ->
        IO.puts("  ✗ Failed to profile: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp step_2_fleet do
    IO.puts("━━━ Step 2: Database Fleet ━━━\n")

    import Ecto.Query
    existing = Repo.aggregate(DatabaseProfile, :count)

    if existing >= 15 do
      unique = Repo.one(from p in DatabaseProfile, select: count(p.db_id, :distinct))
      IO.puts("  Already have #{existing} profiles from #{unique} databases")
      IO.puts("  (Run with --clean to reset)\n")
    else
      IO.puts("  Creating simulated fleet for demo...")

      {:ok, profile} = RichProfiler.quick_profile(Repo)

      # Create 20 similar profiles
      for i <- 1..20 do
        db_id = "demo-db-#{String.pad_leading("#{i}", 3, "0")}"
        noisy = add_noise(profile.feature_vector, 0.03 + :rand.uniform() * 0.02)

        %DatabaseProfile{}
        |> DatabaseProfile.changeset(%{
          db_id: db_id,
          feature_vector: noisy,
          schema_features: profile.schema_features,
          query_features: profile.query_features,
          execution_features: profile.execution_features,
          io_features: profile.io_features,
          index_features: profile.index_features,
          runtime_features: profile.runtime_features,
          scale_features: profile.scale_features,
          has_pg_stat_statements: profile.has_pg_stat_statements,
          pg_version: profile.pg_version
        })
        |> Repo.insert!()
      end

      IO.puts("  ✓ Created 20 simulated database profiles\n")
    end
  end

  defp step_3_discover do
    IO.puts("━━━ Step 3: Pattern Discovery ━━━\n")

    import Ecto.Query
    existing_patterns = Repo.aggregate(WorkloadPattern, :count)

    if existing_patterns > 0 do
      patterns = Repo.all(WorkloadPattern)
      IO.puts("  Found #{existing_patterns} existing patterns:")

      Enum.each(patterns, fn p ->
        validated = if p.validated_knobs, do: "validated", else: "pending"
        IO.puts("    • #{p.description || "unnamed"} (#{p.member_count} members, #{validated})")
      end)

      IO.puts("")
    else
      IO.puts("  Running DBSCAN clustering...")

      {:ok, result} = PatternDiscovery.discover_patterns(Repo, min_samples: 5)

      IO.puts("  ✓ Discovered #{length(result.patterns)} patterns")
      IO.puts("  ✓ #{result.assignments} databases assigned")
      IO.puts("  ✓ #{length(result.outliers)} outliers")
      IO.puts("")

      Enum.each(result.patterns, fn p ->
        IO.puts("    Pattern: #{p.description}")
        IO.puts("      Members: #{p.member_count}")
        IO.puts("      Radius: #{Float.round(p.radius, 4)}")
        IO.puts("")
      end)
    end
  end

  defp step_4_match do
    IO.puts("━━━ Step 4: Pattern Matching ━━━\n")

    import Ecto.Query

    # Ensure we have a validated pattern
    pattern = Repo.one(from p in WorkloadPattern, limit: 1)

    if pattern do
      unless pattern.validated_knobs do
        IO.puts("  Adding mock validated knobs for demo...")

        pattern
        |> WorkloadPattern.changeset(%{
          validated_knobs: ["shared_buffers", "work_mem", "effective_cache_size",
                           "random_page_cost", "effective_io_concurrency"],
          sobol_validated_at: DateTime.utc_now() |> DateTime.truncate(:second),
          sobol_db_id: "demo"
        })
        |> Repo.update!()

        IO.puts("  ✓ Pattern validated with 5 knobs\n")
      end

      # Create a new profile and try matching
      {:ok, profile} = RichProfiler.quick_profile(Repo)
      test_db = "match-test-#{:rand.uniform(1000)}"

      %DatabaseProfile{}
      |> DatabaseProfile.changeset(%{
        db_id: test_db,
        feature_vector: add_noise(profile.feature_vector, 0.01),
        schema_features: profile.schema_features,
        query_features: profile.query_features,
        execution_features: profile.execution_features,
        io_features: profile.io_features,
        index_features: profile.index_features,
        runtime_features: profile.runtime_features,
        scale_features: profile.scale_features,
        has_pg_stat_statements: profile.has_pg_stat_statements,
        pg_version: profile.pg_version
      })
      |> Repo.insert!()

      IO.puts("  Testing match for database: #{test_db}")

      case PatternMatcher.get_knobs_for_database(test_db, Repo, Repo) do
        {:ok, match} ->
          IO.puts("  ✓ Matched!")
          IO.puts("    Source: #{match.source}")
          IO.puts("    Similarity: #{pct(match.similarity)}")
          IO.puts("    Description: #{match.description}")
          IO.puts("    Knobs: #{Enum.join(match.knobs, ", ")}")
          IO.puts("")

        {:needs_validation, reason} ->
          IO.puts("  ⚠ No match (#{reason.reason})")
          IO.puts("    Best similarity: #{pct(Map.get(reason, :best_similarity, 0))}")
          IO.puts("    → Would run Sobol analysis for this database")
          IO.puts("")
      end
    else
      IO.puts("  No patterns exist yet. Run discovery first.\n")
    end
  end

  defp step_5_stats do
    IO.puts("━━━ Step 5: System Stats ━━━\n")

    stats = PatternMaintenance.get_stats(Repo)

    IO.puts("  Patterns:")
    IO.puts("    Total: #{stats.patterns.total}")
    IO.puts("    Validated: #{stats.patterns.validated}")
    IO.puts("    Pending validation: #{stats.patterns.pending_validation}")
    IO.puts("")
    IO.puts("  Assignments:")
    IO.puts("    Total databases: #{stats.assignments.total}")
    IO.puts("    Pattern matched: #{stats.assignments.pattern_matched}")
    IO.puts("    Custom validated: #{stats.assignments.custom_validated}")
    IO.puts("")
    IO.puts("  Profiles:")
    IO.puts("    Total profiles: #{stats.profiles.total}")
    IO.puts("    Unique databases: #{stats.profiles.unique_databases}")
    IO.puts("")

    # Check drift
    {:ok, drift} = PatternMaintenance.check_drift(Repo)
    IO.puts("  Drift check: #{drift.checked} assignments checked, #{length(drift.drifted)} drifted")
    IO.puts("")
  end

  defp add_noise(vector, level) do
    Enum.map(vector, fn v ->
      noise = (:rand.uniform() - 0.5) * 2 * level
      max(0.0, min(1.0, v + noise))
    end)
  end

  defp pct(nil), do: "N/A"
  defp pct(v) when is_float(v), do: "#{Float.round(v * 100, 1)}%"
  defp pct(v), do: "#{v}"
end
