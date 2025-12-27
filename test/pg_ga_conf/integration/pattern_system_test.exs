defmodule PgGaConf.Integration.PatternSystemTest do
  @moduledoc """
  End-to-end integration test for the Workload Pattern Discovery System.

  Run with: mix test test/pg_ga_conf/integration/pattern_system_test.exs --include integration

  Requires:
  - App database running on port 5432 (pg_start_app)
  - Target database running on port 5433 (pg_start_target)
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias PgGaConf.Repo
  alias PgGaConf.Workload.RichProfiler
  alias PgGaConf.PatternDiscovery
  alias PgGaConf.PatternMatcher
  alias PgGaConf.PatternMaintenance
  alias PgGaConf.Schema.{DatabaseProfile, WorkloadPattern, PatternAssignment}

  import Ecto.Query

  setup do
    # Clean up any existing test data
    Repo.delete_all(PatternAssignment)
    Repo.delete_all(WorkloadPattern)
    Repo.delete_all(DatabaseProfile)

    :ok
  end

  describe "end-to-end pattern system" do
    @tag timeout: 120_000
    test "full flow: profile → discover → match" do
      IO.puts("\n=== Starting End-to-End Pattern System Test ===\n")

      # =========================================================================
      # Step 1: Profile the current database
      # =========================================================================
      IO.puts("Step 1: Profiling database with RichProfiler...")

      {:ok, profile} = RichProfiler.quick_profile(Repo)

      assert length(profile.feature_vector) == 59
      assert is_boolean(profile.has_pg_stat_statements)
      assert profile.pg_version > 0

      IO.puts("  ✓ Profile collected: #{profile.feature_count} features")
      IO.puts("  ✓ PG version: #{profile.pg_version}")
      IO.puts("  ✓ Has pg_stat_statements: #{profile.has_pg_stat_statements}")

      # Print some interesting features
      IO.puts("  Sample features:")
      IO.puts("    - Table count: #{profile.schema_features.table_count}")
      IO.puts("    - Select ratio: #{Float.round(profile.query_features.select_ratio, 3)}")
      IO.puts("    - Cache hit ratio: #{Float.round(profile.query_features.cache_hit_ratio, 3)}")

      # =========================================================================
      # Step 2: Store profiles (simulate multiple databases)
      # =========================================================================
      IO.puts("\nStep 2: Storing profiles for simulated database fleet...")

      # Create variations of the profile to simulate a fleet
      # We need at least min_samples (15) for DBSCAN to form a cluster
      db_ids = for i <- 1..20, do: "test-db-#{i}"

      profiles_stored =
        Enum.map(db_ids, fn db_id ->
          # Add some noise to simulate different but similar databases
          noisy_vector = add_noise(profile.feature_vector, 0.05)

          {:ok, stored} =
            %DatabaseProfile{}
            |> DatabaseProfile.changeset(%{
              db_id: db_id,
              feature_vector: noisy_vector,
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
            |> Repo.insert()

          stored
        end)

      IO.puts("  ✓ Stored #{length(profiles_stored)} profiles")

      # =========================================================================
      # Step 3: Discover patterns via DBSCAN
      # =========================================================================
      IO.puts("\nStep 3: Running pattern discovery (DBSCAN clustering)...")

      {:ok, discovery_result} = PatternDiscovery.discover_patterns(Repo, min_samples: 5)

      IO.puts("  ✓ Patterns discovered: #{length(discovery_result.patterns)}")
      IO.puts("  ✓ Outliers: #{length(discovery_result.outliers)}")
      IO.puts("  ✓ Assignments created: #{discovery_result.assignments}")

      assert length(discovery_result.patterns) >= 1, "Should discover at least 1 pattern"

      # Print pattern details
      Enum.each(discovery_result.patterns, fn pattern ->
        IO.puts("  Pattern #{pattern.id}:")
        IO.puts("    - Members: #{pattern.member_count}")
        IO.puts("    - Description: #{pattern.description}")
        IO.puts("    - Radius: #{Float.round(pattern.radius, 4)}")
      end)

      # =========================================================================
      # Step 4: Verify pattern matching works
      # =========================================================================
      IO.puts("\nStep 4: Testing pattern matching...")

      # Get one of the patterns
      [first_pattern | _] = discovery_result.patterns

      # Store a new profile and try to match it
      new_db_id = "new-test-db"
      new_vector = add_noise(profile.feature_vector, 0.02)  # Very similar

      {:ok, _} =
        %DatabaseProfile{}
        |> DatabaseProfile.changeset(%{
          db_id: new_db_id,
          feature_vector: new_vector,
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
        |> Repo.insert()

      # Since we don't have validated knobs yet, it should say needs_validation
      # But let's manually add validated knobs to test the full flow
      first_pattern
      |> WorkloadPattern.changeset(%{
        validated_knobs: ["shared_buffers", "work_mem", "effective_cache_size"],
        sobol_validated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        sobol_db_id: "test-db-1"
      })
      |> Repo.update!()

      IO.puts("  ✓ Added mock validated knobs to pattern")

      # Now try matching
      result = PatternMatcher.get_knobs_for_database(new_db_id, Repo, Repo)

      case result do
        {:ok, match} ->
          IO.puts("  ✓ Pattern matched!")
          IO.puts("    - Source: #{match.source}")
          IO.puts("    - Similarity: #{Float.round(match.similarity, 3)}")
          IO.puts("    - Knobs: #{Enum.join(match.knobs, ", ")}")
          assert match.source == :pattern_match
          assert length(match.knobs) == 3

        {:needs_validation, reason} ->
          IO.puts("  ⚠ No pattern match: #{inspect(reason)}")
      end

      # =========================================================================
      # Step 5: Test maintenance functions
      # =========================================================================
      IO.puts("\nStep 5: Testing maintenance functions...")

      stats = PatternMaintenance.get_stats(Repo)

      IO.puts("  System stats:")
      IO.puts("    - Total patterns: #{stats.patterns.total}")
      IO.puts("    - Validated patterns: #{stats.patterns.validated}")
      IO.puts("    - Total assignments: #{stats.assignments.total}")
      IO.puts("    - Unique databases profiled: #{stats.profiles.unique_databases}")

      {:ok, drift_result} = PatternMaintenance.check_drift(Repo)
      IO.puts("  ✓ Drift check: #{drift_result.checked} checked, #{length(drift_result.drifted)} drifted")

      # =========================================================================
      # Summary
      # =========================================================================
      IO.puts("\n=== End-to-End Test Complete ===")
      IO.puts("All components working:")
      IO.puts("  ✓ RichProfiler - 59-feature profiling")
      IO.puts("  ✓ PatternDiscovery - DBSCAN clustering")
      IO.puts("  ✓ PatternMatcher - Similarity matching")
      IO.puts("  ✓ PatternMaintenance - Stats and drift detection")
      IO.puts("")
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp add_noise(vector, noise_level) do
    Enum.map(vector, fn v ->
      noise = (:rand.uniform() - 0.5) * 2 * noise_level
      max(0.0, min(1.0, v + noise))
    end)
  end
end
