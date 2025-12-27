defmodule PgGaConf.PatternMaintenance do
  @moduledoc """
  Maintains workload patterns over time.

  Handles:
  - Drift detection: Identifies databases that have drifted from their assigned pattern
  - Reassignment: Moves databases to better-matching patterns
  - Pattern cleanup: Removes empty or obsolete patterns
  - Periodic re-clustering: Discovers new patterns as the fleet evolves

  ## Usage

      # Check for drifted databases and reassign them
      {:ok, result} = PatternMaintenance.check_drift(repo)

      # Run full maintenance cycle
      {:ok, result} = PatternMaintenance.run_maintenance(repo)
  """

  require Logger

  import Ecto.Query

  alias PgGaConf.PatternDiscovery
  alias PgGaConf.PatternMatcher
  alias PgGaConf.Schema.{DatabaseProfile, WorkloadPattern, PatternAssignment}

  @drift_threshold 0.15

  @doc """
  Check for databases that have drifted from their assigned pattern.

  Returns databases where current profile distance > drift_threshold.
  """
  @spec check_drift(Ecto.Repo.t(), keyword()) :: {:ok, map()}
  def check_drift(repo, opts \\ []) do
    threshold = Keyword.get(opts, :drift_threshold, @drift_threshold)

    Logger.info("Checking for pattern drift (threshold: #{threshold})")

    # Get all assignments with patterns
    assignments =
      from(a in PatternAssignment,
        where: not is_nil(a.pattern_id),
        preload: [:pattern]
      )
      |> repo.all()

    drifted =
      assignments
      |> Enum.filter(fn assignment ->
        case get_latest_profile(assignment.db_id, repo) do
          {:ok, profile} ->
            current_distance =
              PatternDiscovery.cosine_distance(
                profile.feature_vector,
                assignment.pattern.centroid_vector
              )

            current_distance > threshold

          _ ->
            false
        end
      end)
      |> Enum.map(& &1.db_id)

    Logger.info("Found #{length(drifted)} drifted databases")

    {:ok, %{drifted: drifted, checked: length(assignments)}}
  end

  @doc """
  Reassign drifted databases to better-matching patterns.
  """
  @spec reassign_drifted(Ecto.Repo.t(), keyword()) :: {:ok, map()}
  def reassign_drifted(repo, opts \\ []) do
    {:ok, %{drifted: drifted}} = check_drift(repo, opts)

    results =
      Enum.map(drifted, fn db_id ->
        case PatternMatcher.reassign(db_id, repo, opts) do
          {:ok, result} ->
            {:reassigned, db_id, result.pattern_id}

          {:needs_validation, _} ->
            # Remove assignment - will need direct Sobol
            delete_assignment(db_id, repo)
            {:unassigned, db_id}
        end
      end)

    reassigned = Enum.filter(results, &match?({:reassigned, _, _}, &1)) |> length()
    unassigned = Enum.filter(results, &match?({:unassigned, _}, &1)) |> length()

    {:ok, %{reassigned: reassigned, unassigned: unassigned}}
  end

  @doc """
  Update pattern centroids based on current member profiles.
  """
  @spec update_centroids(Ecto.Repo.t()) :: {:ok, map()}
  def update_centroids(repo) do
    patterns = repo.all(WorkloadPattern)

    updated =
      Enum.map(patterns, fn pattern ->
        case compute_current_centroid(pattern.id, repo) do
          {:ok, new_centroid, member_count} ->
            new_radius = compute_radius(pattern.id, new_centroid, repo)

            pattern
            |> WorkloadPattern.changeset(%{
              centroid_vector: new_centroid,
              radius: new_radius,
              member_count: member_count
            })
            |> repo.update!()

            {:updated, pattern.id}

          {:error, :no_members} ->
            {:empty, pattern.id}

          _ ->
            {:unchanged, pattern.id}
        end
      end)

    updated_count = Enum.filter(updated, &match?({:updated, _}, &1)) |> length()
    empty_count = Enum.filter(updated, &match?({:empty, _}, &1)) |> length()

    {:ok, %{updated: updated_count, empty: empty_count}}
  end

  @doc """
  Remove patterns with no members.
  """
  @spec cleanup_empty_patterns(Ecto.Repo.t()) :: {:ok, map()}
  def cleanup_empty_patterns(repo) do
    # Find patterns with no assignments
    empty_patterns =
      from(p in WorkloadPattern,
        left_join: a in PatternAssignment,
        on: a.pattern_id == p.id,
        group_by: p.id,
        having: count(a.db_id) == 0,
        select: p.id
      )
      |> repo.all()

    if length(empty_patterns) > 0 do
      Logger.info("Removing #{length(empty_patterns)} empty patterns")

      from(p in WorkloadPattern, where: p.id in ^empty_patterns)
      |> repo.delete_all()
    end

    {:ok, %{removed: length(empty_patterns)}}
  end

  @doc """
  Run full maintenance cycle.

  1. Check for drift
  2. Reassign drifted databases
  3. Update centroids
  4. Cleanup empty patterns
  """
  @spec run_maintenance(Ecto.Repo.t(), keyword()) :: {:ok, map()}
  def run_maintenance(repo, opts \\ []) do
    Logger.info("Starting pattern maintenance cycle")

    {:ok, drift_result} = reassign_drifted(repo, opts)
    {:ok, centroid_result} = update_centroids(repo)
    {:ok, cleanup_result} = cleanup_empty_patterns(repo)

    result = %{
      drift: drift_result,
      centroids: centroid_result,
      cleanup: cleanup_result
    }

    Logger.info("Maintenance complete: #{inspect(result)}")

    {:ok, result}
  end

  @doc """
  Invalidate pattern validation if centroid has drifted significantly.

  Patterns with significant centroid drift should be revalidated.
  """
  @spec invalidate_drifted_validations(Ecto.Repo.t(), keyword()) :: {:ok, map()}
  def invalidate_drifted_validations(repo, opts \\ []) do
    threshold = Keyword.get(opts, :validation_drift_threshold, 0.20)

    validated_patterns =
      from(p in WorkloadPattern,
        where: not is_nil(p.validated_knobs)
      )
      |> repo.all()

    invalidated =
      Enum.filter(validated_patterns, fn pattern ->
        case compute_current_centroid(pattern.id, repo) do
          {:ok, current_centroid, _} ->
            drift = PatternDiscovery.cosine_distance(pattern.centroid_vector, current_centroid)
            drift > threshold

          _ ->
            false
        end
      end)

    if length(invalidated) > 0 do
      Logger.info("Invalidating #{length(invalidated)} pattern validations due to centroid drift")

      invalidated_ids = Enum.map(invalidated, & &1.id)

      from(p in WorkloadPattern, where: p.id in ^invalidated_ids)
      |> repo.update_all(
        set: [
          validated_knobs: nil,
          sobol_indices: nil,
          sobol_validated_at: nil,
          sobol_db_id: nil
        ]
      )
    end

    {:ok, %{invalidated: length(invalidated)}}
  end

  @doc """
  Get maintenance statistics.
  """
  @spec get_stats(Ecto.Repo.t()) :: map()
  def get_stats(repo) do
    total_patterns = repo.aggregate(WorkloadPattern, :count)

    validated_patterns =
      from(p in WorkloadPattern, where: not is_nil(p.validated_knobs))
      |> repo.aggregate(:count)

    total_assignments = repo.aggregate(PatternAssignment, :count)

    pattern_assignments =
      from(a in PatternAssignment, where: not is_nil(a.pattern_id))
      |> repo.aggregate(:count)

    custom_validations =
      from(a in PatternAssignment, where: not is_nil(a.custom_validated_knobs))
      |> repo.aggregate(:count)

    total_profiles = repo.aggregate(DatabaseProfile, :count)

    unique_dbs =
      from(p in DatabaseProfile, select: count(p.db_id, :distinct))
      |> repo.one()

    %{
      patterns: %{
        total: total_patterns,
        validated: validated_patterns,
        pending_validation: total_patterns - validated_patterns
      },
      assignments: %{
        total: total_assignments,
        pattern_matched: pattern_assignments,
        custom_validated: custom_validations
      },
      profiles: %{
        total: total_profiles,
        unique_databases: unique_dbs
      }
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_latest_profile(db_id, repo) do
    query =
      from(p in DatabaseProfile,
        where: p.db_id == ^db_id,
        order_by: [desc: p.captured_at],
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :no_profile}
      profile -> {:ok, profile}
    end
  end

  defp compute_current_centroid(pattern_id, repo) do
    assignments =
      from(a in PatternAssignment,
        where: a.pattern_id == ^pattern_id,
        select: a.db_id
      )
      |> repo.all()

    if Enum.empty?(assignments) do
      {:error, :no_members}
    else
      profiles =
        Enum.map(assignments, fn db_id ->
          case get_latest_profile(db_id, repo) do
            {:ok, profile} -> profile.feature_vector
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      if Enum.empty?(profiles) do
        {:error, :no_profiles}
      else
        centroid = compute_centroid(profiles)
        {:ok, centroid, length(profiles)}
      end
    end
  end

  defp compute_centroid(vectors) do
    n = length(vectors)
    dim = length(hd(vectors))

    Enum.reduce(vectors, List.duplicate(0.0, dim), fn vec, acc ->
      Enum.zip(acc, vec) |> Enum.map(fn {a, v} -> a + v end)
    end)
    |> Enum.map(&(&1 / n))
  end

  defp compute_radius(pattern_id, centroid, repo) do
    assignments =
      from(a in PatternAssignment,
        where: a.pattern_id == ^pattern_id,
        select: a.db_id
      )
      |> repo.all()

    profiles =
      Enum.map(assignments, fn db_id ->
        case get_latest_profile(db_id, repo) do
          {:ok, profile} -> profile.feature_vector
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(profiles) do
      0.0
    else
      profiles
      |> Enum.map(&PatternDiscovery.cosine_distance(&1, centroid))
      |> Enum.max()
    end
  end

  defp delete_assignment(db_id, repo) do
    from(a in PatternAssignment, where: a.db_id == ^db_id)
    |> repo.delete_all()
  end
end
