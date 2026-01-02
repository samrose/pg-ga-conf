# DBSCAN: Density-Based Spatial Clustering of Applications with Noise

This document explains the DBSCAN algorithm used in the Workload Pattern Discovery System for clustering database profiles into natural workload patterns.

## Origins and Reference

**DBSCAN** was introduced in 1996 by Martin Ester, Hans-Peter Kriegel, Jorg Sander, and Xiaowei Xu at the University of Munich.

> **Original Paper:**
> Ester, M., Kriegel, H. P., Sander, J., & Xu, X. (1996). *A density-based algorithm for discovering clusters in large spatial databases with noise*. In Proceedings of the 2nd International Conference on Knowledge Discovery and Data Mining (KDD-96), pp. 226-231.

The paper is one of the most cited in data mining literature, with the algorithm becoming a foundational technique for clustering.

---

## Why DBSCAN for Workload Patterns?

Unlike K-means or hierarchical clustering, DBSCAN was chosen because:

| Property | K-means | DBSCAN | Why it matters |
|----------|---------|--------|----------------|
| Cluster count | Must specify K upfront | Discovers automatically | We don't know how many workload patterns exist |
| Cluster shape | Assumes spherical | Arbitrary shapes | Workloads may form non-spherical regions |
| Outliers | Forces into clusters | Explicitly identifies noise | Unusual databases shouldn't pollute patterns |
| Determinism | Random initialization | Deterministic | Same profiles -> same patterns |

---

## Core Concepts

DBSCAN defines clusters based on **density** - regions where points are packed closely together.

### Key Definitions

```
+-----------------------------------------------------------------------+
|                                                                       |
|    epsilon (eps)                                                      |
|    -------------                                                      |
|    Maximum distance between two points to be considered neighbors.    |
|                                                                       |
|    In this implementation: eps = 0.20 (cosine distance)               |
|    Meaning: points with cosine similarity > 0.80 are neighbors        |
|                                                                       |
+-----------------------------------------------------------------------+
|                                                                       |
|    MinPts (min_samples)                                               |
|    --------------------                                               |
|    Minimum number of points required to form a dense region.          |
|                                                                       |
|    In this implementation: min_samples = 15                           |
|    Meaning: need at least 15 similar databases to form a pattern     |
|                                                                       |
+-----------------------------------------------------------------------+
```

### Point Types

```
         Core Point                Border Point              Noise Point
     (>= MinPts neighbors)     (< MinPts neighbors,      (< MinPts neighbors,
                                but near a core point)    not near core point)

            o o                        o
          o * o o                    o *                         o
            o o                      o   o
              o                        o o <- core

     Forms cluster center         Belongs to cluster          Labeled as noise (-1)
```

- **Core point:** Has >= MinPts neighbors within epsilon distance. These are cluster "seeds."
- **Border point:** Has < MinPts neighbors, but is within epsilon of a core point. Belongs to the cluster but can't expand it.
- **Noise point:** Neither core nor border. Doesn't belong to any cluster.

---

## The Algorithm

### Pseudocode (Original)

```
DBSCAN(D, eps, MinPts):
    C = 0                                    // Cluster counter
    for each point P in database D:
        if P is visited:
            continue
        mark P as visited
        NeighborPts = regionQuery(P, eps)    // Find all neighbors within eps
        if |NeighborPts| < MinPts:
            mark P as NOISE
        else:
            C = C + 1                        // Start new cluster
            expandCluster(P, NeighborPts, C, eps, MinPts)

expandCluster(P, NeighborPts, C, eps, MinPts):
    add P to cluster C
    for each point P' in NeighborPts:
        if P' is not visited:
            mark P' as visited
            NeighborPts' = regionQuery(P', eps)
            if |NeighborPts'| >= MinPts:
                NeighborPts = NeighborPts U NeighborPts'  // Expand search
        if P' is not yet member of any cluster:
            add P' to cluster C
```

### Visual Example

```
Step 1: Start with unvisited points       Step 2: Pick point, find neighbors

    o   o                                     o   o
  o   o   o                                 o   *---o  (* = current, has 4 neighbors)
    o o                                         o-o    (4 >= MinPts=3, so core point)
      o   o                                       o   o
          o                                           o


Step 3: Expand cluster from neighbors     Step 4: Continue until no more neighbors

    1   1                                     1   1
  1   1   1                                 1   1   1
    1 1                                       1 1
      o   o                                     2   2  (new cluster found)
          o                                         2


Step 5: Remaining isolated = noise        Final result:

    1   1                                 Cluster 1: 7 points
  1   1   1                               Cluster 2: 3 points
    1 1                                   Noise: 0 points
      2   2
          2
```

---

## Implementation in pg-ga-conf

Located in `lib/pg_ga_conf/pattern_discovery.ex`.

### 1. Build Distance Matrix

```elixir
defp build_distance_matrix(vectors) do
  indexed = Enum.with_index(vectors)

  # Build a flat tuple of all pairwise distances
  distances =
    for {v1, i} <- indexed, {v2, j} <- indexed do
      if i == j, do: 0.0, else: cosine_distance(v1, v2)
    end

  List.to_tuple(distances)
end
```

This precomputes all pairwise distances as a flat tuple. For N profiles, this is N^2 distances. Access is O(1) via `elem(matrix, i * n + j)`.

**Cosine distance** is used instead of Euclidean:

```elixir
def cosine_distance(vec1, vec2) do
  1.0 - cosine_similarity(vec1, vec2)
end

def cosine_similarity(vec1, vec2) do
  dot = Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
  mag1 = :math.sqrt(Enum.map(vec1, &(&1 * &1)) |> Enum.sum())
  mag2 = :math.sqrt(Enum.map(vec2, &(&1 * &1)) |> Enum.sum())

  if mag1 == 0 or mag2 == 0, do: 0.0, else: dot / (mag1 * mag2)
end
```

**Why cosine?** Feature vectors are normalized [0,1] but have different scales. Cosine similarity measures the angle between vectors, making it scale-invariant. Two databases with similar *proportions* of features will have high similarity even if absolute values differ.

### 2. Find Neighbors

```elixir
neighbors =
  Enum.map(0..(n - 1), fn i ->
    Enum.filter(0..(n - 1), fn j ->
      i != j and elem(distance_matrix, i * n + j) <= eps
    end)
  end)
```

For each point, find all other points within epsilon distance. This creates a list of neighbor lists.

### 3. Main DBSCAN Loop

```elixir
# Initialize labels (-1 = noise, -2 = unvisited)
labels = :array.new(n, default: -2)

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
```

Uses Erlang's `:array` module for O(1) label updates. Labels:
- `-2` = unvisited
- `-1` = noise
- `0, 1, 2, ...` = cluster ID

### 4. Cluster Expansion

```elixir
defp expand_cluster(seeds, all_neighbors, labels, cluster_id, min_samples) do
  seeds_set = MapSet.new(seeds)

  Enum.reduce(seeds, {labels, seeds_set}, fn seed, {labels_acc, to_process} ->
    current_label = :array.get(seed, labels_acc)

    cond do
      current_label == -1 ->
        # Was marked as noise, now belongs to cluster (border point)
        {:array.set(seed, cluster_id, labels_acc), to_process}

      current_label == -2 ->
        # Unvisited - add to cluster
        labels_with_seed = :array.set(seed, cluster_id, labels_acc)
        seed_neighbors = Enum.at(all_neighbors, seed)

        if length(seed_neighbors) >= min_samples - 1 do
          # This is also a core point, add its neighbors to process
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
          # Border point - belongs to cluster but doesn't expand it
          {labels_with_seed, to_process}
        end

      true ->
        # Already assigned to a cluster
        {labels_acc, to_process}
    end
  end)
  |> then(fn {final_labels, remaining} ->
    # Recursively process any new seeds added
    new_seeds = MapSet.difference(remaining, seeds_set) |> MapSet.to_list()

    if Enum.empty?(new_seeds) do
      final_labels
    else
      expand_cluster(new_seeds, all_neighbors, final_labels, cluster_id, min_samples)
    end
  end)
end
```

Key insight: A point initially marked as noise (`-1`) can be "rescued" if it's later found to be a neighbor of a core point. It becomes a border point of that cluster.

---

## Parameters in Context

```elixir
@eps 0.20           # Cosine distance threshold
@min_samples 15     # Minimum databases to form a pattern
```

| Parameter | Value | Interpretation |
|-----------|-------|----------------|
| `eps = 0.20` | Cosine distance <= 0.20 | Cosine similarity >= 0.80 (80% similar) |
| `min_samples = 15` | Need 15+ neighbors | Patterns need statistical significance |

### Trade-offs

- **Lower eps:** Tighter clusters, more noise, more patterns
- **Higher eps:** Looser clusters, less noise, fewer patterns
- **Lower min_samples:** More small patterns, less robust
- **Higher min_samples:** Fewer patterns, more robust, more outliers

---

## Complexity

| Operation | Complexity |
|-----------|------------|
| Distance matrix | O(N^2 x D) where D = 59 features |
| Neighbor finding | O(N^2) |
| DBSCAN main loop | O(N x average_neighbors) |
| **Total** | O(N^2 x D) |

For a fleet of 1000 databases: ~1M distance calculations x 59 dimensions. This is computed once and cached.

---

## Output

```elixir
# Returns list of cluster labels, one per input profile
# -1 = noise (outlier)
# 0, 1, 2, ... = cluster IDs

labels = dbscan(vectors, 0.20, 15)
# => [-1, 0, 0, 0, 1, 1, -1, 0, 0, 1, ...]

# Group by label
clustered = Enum.zip(profiles, labels) |> Enum.group_by(fn {_, label} -> label end)

# Cluster 0 members
cluster_0 = clustered[0]  # List of profiles in first pattern

# Outliers
outliers = clustered[-1]  # Databases that don't fit any pattern
```

---

## From Clusters to Patterns

After DBSCAN, each cluster becomes a `WorkloadPattern`:

```elixir
defp create_pattern(members, repo) do
  vectors = Enum.map(members, & &1.feature_vector)

  # Centroid = mean of all member vectors
  centroid = compute_centroid(vectors)

  # Radius = max distance from centroid to any member
  radius = compute_radius(centroid, vectors)

  # Auto-generate description from centroid features
  description = generate_description(centroid)

  # Store pattern
  {:ok, pattern} = %WorkloadPattern{}
    |> WorkloadPattern.changeset(%{
      centroid_vector: centroid,
      radius: radius,
      member_count: length(members),
      description: description
    })
    |> repo.insert()

  # Assign all members to this pattern
  Enum.each(members, fn member ->
    similarity = 1.0 - cosine_distance(member.feature_vector, centroid)
    # ... create PatternAssignment
  end)

  pattern
end
```

### Centroid Calculation

The centroid is the element-wise mean of all member vectors:

```elixir
defp compute_centroid(vectors) do
  n = length(vectors)
  dim = length(hd(vectors))

  Enum.reduce(vectors, List.duplicate(0.0, dim), fn vec, acc ->
    Enum.zip(acc, vec) |> Enum.map(fn {a, v} -> a + v end)
  end)
  |> Enum.map(&(&1 / n))
end
```

### Radius Calculation

The radius is the maximum cosine distance from the centroid to any member:

```elixir
defp compute_radius(centroid, vectors) do
  vectors
  |> Enum.map(&cosine_distance(&1, centroid))
  |> Enum.max(fn -> 0.0 end)
end
```

---

## Usage

### Discover Patterns

```elixir
# Discover patterns from all stored profiles
{:ok, result} = PatternDiscovery.discover_patterns(Repo)

result.patterns   # List of WorkloadPattern structs
result.outliers   # List of db_ids that didn't fit any cluster
result.assignments # Count of databases assigned to patterns
```

### With Custom Parameters

```elixir
# Tighter clusters, require more members
{:ok, result} = PatternDiscovery.discover_patterns(Repo,
  eps: 0.15,        # Require 85% similarity
  min_samples: 20   # Need 20+ similar databases
)
```

### Re-cluster from Scratch

```elixir
# Clear existing patterns and re-run discovery
{:ok, result} = PatternDiscovery.recluster(Repo)
```

---

## Practical Considerations

### When to Re-cluster

- After significant fleet changes (many new databases)
- Periodically (e.g., weekly) to discover emerging patterns
- When drift detection shows many databases have moved

### Handling Outliers

Databases labeled as outliers (noise) don't match any pattern. Options:

1. **Run direct Sobol analysis** - Validate knobs specifically for this database
2. **Wait for more data** - May form a new pattern with future similar databases
3. **Lower min_samples** - Accept smaller patterns (trade-off: less robust)

### Scaling

For very large fleets (10,000+ databases):

1. **Sample profiles** - Use representative sample for initial clustering
2. **Approximate neighbors** - Use locality-sensitive hashing (LSH)
3. **Incremental updates** - Assign new databases to existing patterns without full re-cluster

---

## References

1. **Original DBSCAN Paper (1996)**
   Ester, M., Kriegel, H. P., Sander, J., & Xu, X.
   *A density-based algorithm for discovering clusters in large spatial databases with noise*
   KDD-96 Proceedings, pp. 226-231
   https://www.aaai.org/Papers/KDD/1996/KDD96-037.pdf

2. **Revisiting DBSCAN (2017)**
   Schubert, E., Sander, J., Ester, M., Kriegel, H. P., & Xu, X.
   *DBSCAN Revisited, Revisited: Why and How You Should (Still) Use DBSCAN*
   ACM Transactions on Database Systems, 42(3), 1-21
   https://doi.org/10.1145/3068335

3. **Cosine Similarity for High-Dimensional Data**
   Steinbach, M., Karypis, G., & Kumar, V. (2000)
   *A comparison of document clustering techniques*
   KDD Workshop on Text Mining
