defmodule PgGaConf.PatternDiscovery do
  @moduledoc """
  Discovers natural workload patterns via DBSCAN clustering.

  DBSCAN (Density-Based Spatial Clustering of Applications with Noise) is used because:

  1. **No predefined cluster count** - We don't know how many natural patterns exist
  2. **Outlier detection** - Unusual workloads are explicitly identified, not forced into wrong clusters
  3. **Arbitrary cluster shapes** - Workload patterns may not be spherical in feature space
  4. **Deterministic** - Same input produces same output

  ## Usage

      # Discover patterns from all stored profiles
      {:ok, result} = PatternDiscovery.discover_patterns(repo)
      result.patterns  # List of WorkloadPattern structs
      result.outliers  # List of profiles that didn't fit any cluster

  ## Configuration

  - `eps`: Maximum cosine distance for points to be neighbors (default: 0.20 = similarity > 0.80)
  - `min_samples`: Minimum points to form a cluster (default: 15)
  """

  require Logger

  import Ecto.Query

  alias PgGaConf.Schema.{DatabaseProfile, WorkloadPattern, PatternAssignment}

  @eps 0.20
  @min_samples 15

  @doc """
  Discover patterns from all stored database profiles.

  Returns a map with:
  - `patterns`: List of created WorkloadPattern records
  - `outliers`: List of profile db_ids that didn't fit any cluster
  - `assignments`: Number of database assignments created
  """
  @spec discover_patterns(Ecto.Repo.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover_patterns(repo, opts \\ []) do
    eps = Keyword.get(opts, :eps, @eps)
    min_samples = Keyword.get(opts, :min_samples, @min_samples)

    Logger.info("Starting pattern discovery with eps=#{eps}, min_samples=#{min_samples}")

    # Get aggregated profiles (latest per database)
    profiles = get_latest_profiles(repo)

    if length(profiles) < min_samples do
      Logger.warning("Not enough profiles for clustering: #{length(profiles)} < #{min_samples}")
      {:ok, %{patterns: [], outliers: Enum.map(profiles, & &1.db_id), assignments: 0}}
    else
      # Run DBSCAN clustering
      vectors = Enum.map(profiles, & &1.feature_vector)
      labels = dbscan(vectors, eps, min_samples)

      # Group by cluster label
      clustered =
        profiles
        |> Enum.zip(labels)
        |> Enum.group_by(fn {_profile, label} -> label end, fn {profile, _} -> profile end)

      # Create patterns for each cluster (excluding noise labeled -1)
      patterns =
        clustered
        |> Enum.reject(fn {label, _} -> label == -1 end)
        |> Enum.map(fn {_label, members} ->
          create_pattern(members, repo)
        end)

      # Get outliers
      outliers =
        Map.get(clustered, -1, [])
        |> Enum.map(& &1.db_id)

      # Count assignments
      assignment_count =
        patterns
        |> Enum.map(& &1.member_count)
        |> Enum.sum()

      Logger.info(
        "Pattern discovery complete: #{length(patterns)} patterns, " <>
          "#{assignment_count} assignments, #{length(outliers)} outliers"
      )

      {:ok, %{patterns: patterns, outliers: outliers, assignments: assignment_count}}
    end
  end

  @doc """
  Re-cluster all profiles and update patterns.

  This is a destructive operation that replaces all existing patterns.
  """
  @spec recluster(Ecto.Repo.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recluster(repo, opts \\ []) do
    Logger.info("Starting full recluster - clearing existing patterns")

    # Clear existing patterns and assignments
    repo.delete_all(PatternAssignment)
    repo.delete_all(WorkloadPattern)

    # Run discovery
    discover_patterns(repo, opts)
  end

  # ============================================================================
  # DBSCAN Implementation
  # ============================================================================

  defp dbscan(vectors, eps, min_samples) do
    n = length(vectors)

    if n == 0 do
      []
    else
      # Build distance matrix
      distance_matrix = build_distance_matrix(vectors)

      # Find neighbors for each point
      neighbors =
        Enum.map(0..(n - 1), fn i ->
          Enum.filter(0..(n - 1), fn j ->
            i != j and elem(distance_matrix, i * n + j) <= eps
          end)
        end)

      # Initialize labels (-1 = noise, -2 = unvisited)
      labels = :array.new(n, default: -2)

      # Run DBSCAN
      {final_labels, _} =
        Enum.reduce(0..(n - 1), {labels, 0}, fn point, {labels_acc, cluster_id} ->
          if :array.get(point, labels_acc) != -2 do
            # Already visited
            {labels_acc, cluster_id}
          else
            point_neighbors = Enum.at(neighbors, point)

            if length(point_neighbors) < min_samples - 1 do
              # Mark as noise (for now - may be claimed by a cluster later)
              {:array.set(point, -1, labels_acc), cluster_id}
            else
              # Start a new cluster
              labels_with_point = :array.set(point, cluster_id, labels_acc)
              expanded_labels = expand_cluster(point_neighbors, neighbors, labels_with_point, cluster_id, min_samples)
              {expanded_labels, cluster_id + 1}
            end
          end
        end)

      :array.to_list(final_labels)
    end
  end

  defp expand_cluster(seeds, all_neighbors, labels, cluster_id, min_samples) do
    seeds_set = MapSet.new(seeds)

    Enum.reduce(seeds, {labels, seeds_set}, fn seed, {labels_acc, to_process} ->
      current_label = :array.get(seed, labels_acc)

      cond do
        current_label == -1 ->
          # Was marked as noise, now belongs to cluster
          {:array.set(seed, cluster_id, labels_acc), to_process}

        current_label == -2 ->
          # Unvisited - add to cluster
          labels_with_seed = :array.set(seed, cluster_id, labels_acc)
          seed_neighbors = Enum.at(all_neighbors, seed)

          if length(seed_neighbors) >= min_samples - 1 do
            # This is also a core point, add its neighbors
            new_to_process =
              Enum.reduce(seed_neighbors, to_process, fn n, acc ->
                if :array.get(n, labels_acc) in [-1, -2] do
                  MapSet.put(acc, n)
                else
                  acc
                end
              end)

            {labels_with_seed, new_to_process}
          else
            {labels_with_seed, to_process}
          end

        true ->
          # Already assigned to a cluster
          {labels_acc, to_process}
      end
    end)
    |> then(fn {final_labels, remaining} ->
      # Process any new seeds added
      new_seeds = MapSet.difference(remaining, seeds_set) |> MapSet.to_list()

      if Enum.empty?(new_seeds) do
        final_labels
      else
        expand_cluster(new_seeds, all_neighbors, final_labels, cluster_id, min_samples)
      end
    end)
  end

  defp build_distance_matrix(vectors) do
    indexed = Enum.with_index(vectors)

    # Build a flat tuple of all pairwise distances
    distances =
      for {v1, i} <- indexed, {v2, j} <- indexed do
        if i == j, do: 0.0, else: cosine_distance(v1, v2)
      end

    List.to_tuple(distances)
  end

  # ============================================================================
  # Pattern Creation
  # ============================================================================

  defp create_pattern(members, repo) do
    vectors = Enum.map(members, & &1.feature_vector)

    centroid = compute_centroid(vectors)
    radius = compute_radius(centroid, vectors)
    description = generate_description(centroid)

    # Create the pattern
    {:ok, pattern} =
      %WorkloadPattern{}
      |> WorkloadPattern.changeset(%{
        centroid_vector: centroid,
        radius: radius,
        member_count: length(members),
        description: description
      })
      |> repo.insert()

    # Create assignments for all members
    Enum.each(members, fn member ->
      similarity = 1.0 - cosine_distance(member.feature_vector, centroid)

      repo.insert!(
        %PatternAssignment{
          db_id: member.db_id,
          pattern_id: pattern.id,
          similarity: similarity,
          assigned_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        on_conflict: {:replace, [:pattern_id, :similarity, :assigned_at]},
        conflict_target: :db_id
      )
    end)

    pattern
  end

  defp compute_centroid(vectors) do
    n = length(vectors)
    dim = length(hd(vectors))

    Enum.reduce(vectors, List.duplicate(0.0, dim), fn vec, acc ->
      Enum.zip(acc, vec) |> Enum.map(fn {a, v} -> a + v end)
    end)
    |> Enum.map(&(&1 / n))
  end

  defp compute_radius(centroid, vectors) do
    vectors
    |> Enum.map(&cosine_distance(&1, centroid))
    |> Enum.max(fn -> 0.0 end)
  end

  defp generate_description(centroid) do
    traits = []

    # Query patterns (features 11-14, 0-indexed: 10-13)
    select_ratio = Enum.at(centroid, 10, 0)
    insert_ratio = Enum.at(centroid, 11, 0)
    update_ratio = Enum.at(centroid, 12, 0)

    traits =
      cond do
        select_ratio > 0.8 -> ["read-heavy" | traits]
        insert_ratio > 0.3 -> ["insert-heavy" | traits]
        update_ratio > 0.3 -> ["update-heavy" | traits]
        true -> traits
      end

    # Complexity (features 15-18, 0-indexed: 14-17)
    join_ratio = Enum.at(centroid, 14, 0)
    aggregate_ratio = Enum.at(centroid, 15, 0)

    traits = if join_ratio > 0.3, do: ["join-heavy" | traits], else: traits
    traits = if aggregate_ratio > 0.2, do: ["analytical" | traits], else: traits

    # JSON usage (feature 19, 0-indexed: 18)
    json_ratio = Enum.at(centroid, 18, 0)
    traits = if json_ratio > 0.2, do: ["json-heavy" | traits], else: traits

    # Scale (feature 54, 0-indexed: 53)
    db_size = Enum.at(centroid, 53, 0)

    traits =
      cond do
        db_size > 0.7 -> ["large-scale" | traits]
        db_size < 0.2 -> ["small-scale" | traits]
        true -> traits
      end

    # Concurrency (features 44, 48, 0-indexed: 43, 47)
    connections = Enum.at(centroid, 45, 0)
    active_ratio = Enum.at(centroid, 47, 0)

    traits = if connections > 0.5 or active_ratio > 0.5, do: ["high-concurrency" | traits], else: traits

    case traits do
      [] -> "mixed workload"
      _ -> Enum.join(Enum.reverse(traits), ", ")
    end
  end

  # ============================================================================
  # Profile Queries
  # ============================================================================

  defp get_latest_profiles(repo) do
    # Get the most recent profile for each database
    subquery =
      from(p in DatabaseProfile,
        select: %{db_id: p.db_id, max_captured: max(p.captured_at)},
        group_by: p.db_id
      )

    query =
      from(p in DatabaseProfile,
        join: latest in subquery(subquery),
        on: p.db_id == latest.db_id and p.captured_at == latest.max_captured,
        select: %{db_id: p.db_id, feature_vector: p.feature_vector}
      )

    repo.all(query)
  end

  # ============================================================================
  # Distance Functions
  # ============================================================================

  @doc """
  Computes cosine distance between two vectors.

  Cosine distance = 1 - cosine_similarity
  Returns 0.0 for identical vectors, 1.0 for orthogonal, 2.0 for opposite.
  """
  @spec cosine_distance([float()], [float()]) :: float()
  def cosine_distance(vec1, vec2) do
    1.0 - cosine_similarity(vec1, vec2)
  end

  @doc """
  Computes cosine similarity between two vectors.

  Returns a value between -1 and 1, where 1 means identical direction.
  """
  @spec cosine_similarity([float()], [float()]) :: float()
  def cosine_similarity(vec1, vec2) do
    dot = Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    mag1 = :math.sqrt(Enum.map(vec1, &(&1 * &1)) |> Enum.sum())
    mag2 = :math.sqrt(Enum.map(vec2, &(&1 * &1)) |> Enum.sum())

    if mag1 == 0 or mag2 == 0, do: 0.0, else: dot / (mag1 * mag2)
  end
end
