# Sobol Sensitivity Analysis

Sobol sensitivity analysis is a variance-based global sensitivity analysis method that identifies which PostgreSQL configuration parameters have the most impact on performance—**for any workload**.

## Overview

Instead of relying on domain expertise to guess which knobs matter, Sobol analysis **measures** how much each parameter contributes to performance variance through systematic experimentation.

| Approach | Method | Adaptability |
|----------|--------|--------------|
| Traditional | "OLTP workloads need these 5 knobs" | Static rules, may miss workload-specific bottlenecks |
| **Sobol** | "Let me measure which knobs matter for YOUR workload" | Data-driven, adapts to any workload pattern |

---

## How It Works

### The Core Process

1. **Generate Sobol Sequences**: Create quasi-random samples that uniformly cover the parameter space (via Julia's `Sobol.jl`)

2. **Run Benchmarks**: Evaluate each sample configuration against the actual workload using pgbench

3. **Compute Sensitivity Indices**: Calculate two metrics per parameter:
   - **S1 (First-order)**: Direct effect of the parameter alone
   - **ST (Total-order)**: Total effect including interactions with other parameters

### Mathematical Foundation

The analysis works by systematically varying each parameter while holding others constant, then analyzing the resulting variance in benchmark scores.

With `n_samples=128` and 4 knobs, this creates approximately `2 × (n+1) × n_samples ≈ 1280` benchmark evaluations—enough to statistically measure each parameter's contribution.

```elixir
# Generate Sobol samples via Julia
{:ok, %{"samples" => samples, "matrices" => matrices}} =
  Julia.generate_sobol_samples(knobs, n_samples)

# Run benchmarks for all samples
results = evaluate_samples(samples, knob_space, benchmark_fn)

# Compute sensitivity indices
{:ok, indices} = Julia.compute_sensitivity(results, matrices, knobs)
```

### Sensitivity Indices Explained

| Index | Meaning | Interpretation |
|-------|---------|----------------|
| **S1** | First-order index | Direct, independent contribution of this parameter |
| **ST** | Total-order index | All contributions including interactions with other parameters |
| **ST - S1** | Interaction effect | How much this parameter's effect depends on other parameters |

**Key insight**: A high ST - S1 gap indicates the parameter interacts strongly with others. For example, `work_mem`'s effect may depend heavily on `max_parallel_workers_per_gather`.

---

## Why It's Workload-Agnostic

Sobol analysis is **empirically emergent** rather than rule-based:

1. **Measures actual performance impact** on *your specific workload*
2. **Detects parameter interactions** (e.g., `work_mem` matters more when `shared_buffers` is small)
3. **Ranks by contribution to variance** — parameters that don't affect your workload get low ST scores

### Example Output

```
Sensitivity indices (higher = more important):
effective_cache_size           S1=10.972 ST=2.667 ████████████████████████████████████████
random_page_cost               S1=10.503 ST=1.777 ████████████████████████████████████████
work_mem                       S1=7.714 ST=1.164 ████████████████████████████████████████
checkpoint_completion_target   S1=2.995 ST=0.692 ████████████████████████████░░░░░░░░░░░░

Important knobs (ST > 0.05): [:effective_cache_size, :random_page_cost, :work_mem, :checkpoint_completion_target]
```

For this OLTP workload, `effective_cache_size` and `random_page_cost` dominate. For a different workload (OLAP with large scans), the ranking would shift automatically.

---

## Usage

### Basic Analysis

```elixir
alias PgGaConf.{Sobol, KnobSpace}

# Define the knob space to analyze
knob_space = %{
  shared_buffers: {:continuous, 128.0, 8192.0},
  work_mem: {:continuous, 4.0, 512.0},
  effective_cache_size: {:continuous, 512.0, 32768.0},
  random_page_cost: {:continuous, 1.0, 4.0}
}

# Run Sobol analysis
{:ok, indices} = Sobol.analyze(knob_space, benchmark_fn,
  n_samples: 128,           # Number of Sobol samples
  use_cache: true,          # Cache results for similar workloads
  similarity_threshold: 0.95 # Cache hit threshold
)

# Filter to important knobs only
important = Sobol.filter_important(indices, threshold: 0.05)
# => [:effective_cache_size, :random_page_cost, :work_mem]

# Get reduced knob space for optimization
reduced_space = Sobol.reduce_knob_space(knob_space, indices, threshold: 0.05)
```

### With Restart-Required Parameters

For parameters like `shared_buffers` that require PostgreSQL restarts, provide a restart function to enable batched evaluation:

```elixir
{:ok, indices} = Sobol.analyze(knob_space, benchmark_fn,
  n_samples: 64,
  restart_fn: fn restart_params ->
    # Apply restart-required params and restart PostgreSQL
    apply_config(restart_params)
    restart_postgres()
  end,
  on_batch_start: fn batch_idx, total_batches, params ->
    IO.puts "Batch #{batch_idx}/#{total_batches}: #{inspect(params)}"
  end
)
```

This groups samples by restart-required parameter values, reducing hundreds of potential restarts to ~10-20 batches.

### Quick Reduce (Skip Analysis)

For time-constrained scenarios, use domain knowledge shortcuts:

```elixir
# Skip Sobol, use predefined knob sets
oltp_knobs = Sobol.quick_reduce(:oltp)
olap_knobs = Sobol.quick_reduce(:olap)
mixed_knobs = Sobol.quick_reduce(:mixed)
```

---

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `n_samples` | 128 | Number of Sobol samples. Creates `2*(n+1)*n_samples` evaluations |
| `use_cache` | true | Check/store results in cache for similar workloads |
| `similarity_threshold` | 0.95 | Minimum fingerprint similarity for cache hit |
| `fingerprint` | auto | Pre-computed workload fingerprint (optional) |
| `repo` | `PgGaConf.Repo` | Ecto repo for cache storage |
| `restart_fn` | nil | Function to call when restart-required params change |
| `on_batch_start` | nil | Progress callback for batched evaluation |

### Sample Size Guidelines

| n_samples | Evaluations (4 knobs) | Evaluations (8 knobs) | Use Case |
|-----------|----------------------|----------------------|----------|
| 32 | ~320 | ~576 | Quick screening |
| 64 | ~640 | ~1152 | Standard analysis |
| 128 | ~1280 | ~2304 | Thorough analysis |
| 256 | ~2560 | ~4608 | High-precision research |

---

## Caching with Workload Fingerprints

Sobol analysis is expensive, but similar workloads often have similar sensitivity profiles. The caching system uses workload fingerprints to reuse results:

```elixir
# Fingerprint captures workload characteristics:
# - Transaction commit/rollback ratio
# - Buffer hit ratio
# - Tuple operations mix (select/insert/update/delete)
# - Index vs sequential scan ratio
# - Temp file usage
# - WAL activity

# If a cached analysis exists with fingerprint similarity > 0.95,
# the cached indices are returned immediately
```

### Cache Lookup Flow

```
1. Extract workload fingerprint from pg_stat_* views
2. Search cache for entries with matching knob set
3. Compare fingerprint similarity (cosine similarity)
4. If similarity >= threshold: return cached indices
5. Otherwise: run full Sobol analysis, cache results
```

---

## Integration with Optimizers

Sobol analysis is the recommended first step before optimization:

```elixir
# Step 1: Analyze full knob space
full_space = KnobSpace.all()  # 27 knobs
{:ok, indices} = Sobol.analyze(full_space, benchmark_fn)

# Step 2: Reduce to important knobs (typically 4-8)
reduced_space = Sobol.reduce_knob_space(full_space, indices, threshold: 0.05)

# Step 3: Optimize the reduced space
{:ok, optimizer} = PgGaConf.Optimizer.TPE.init(reduced_space)

# Result: Faster optimization, better results
# - Fewer dimensions = faster convergence
# - Focus on knobs that actually matter
# - No wasted iterations on irrelevant parameters
```

### Why Reduce Before Optimizing?

| Knob Space | TPE Iterations Needed | Optimization Quality |
|------------|----------------------|---------------------|
| 27 knobs (full) | 100+ | Poor (curse of dimensionality) |
| 8 knobs (reduced) | 30-50 | Good |
| 4 knobs (reduced) | 15-25 | Excellent |

---

## Batched Evaluation for Restart-Required Parameters

PostgreSQL parameters like `shared_buffers`, `max_connections`, and `wal_buffers` require a server restart to take effect. Naively, this would mean restarting PostgreSQL for each of the ~1280 Sobol samples.

The batched evaluation system solves this:

```
Normal evaluation:
Sample 1 → Apply config → Restart → Benchmark
Sample 2 → Apply config → Restart → Benchmark
Sample 3 → Apply config → Restart → Benchmark
... (1280 restarts!)

Batched evaluation:
Batch 1 (shared_buffers=128MB):
  Sample 1 → Apply → Benchmark
  Sample 7 → Apply → Benchmark
  Sample 23 → Apply → Benchmark
  ... (no restarts within batch)

Restart PostgreSQL

Batch 2 (shared_buffers=256MB):
  Sample 2 → Apply → Benchmark
  Sample 14 → Apply → Benchmark
  ...

(~20 restarts total)
```

### How Batching Works

1. Decode all Sobol samples to configuration maps
2. Group samples by restart-required parameter values
3. Sort batches for deterministic ordering
4. Process each batch:
   - Restart PostgreSQL only when restart-required values change
   - Run all samples in batch without restarting
5. Reconstruct results in original sample order

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Elixir (Orchestration)                    │
├─────────────────────────────────────────────────────────────────┤
│  PgGaConf.Sobol                                                  │
│  ├── analyze/3           Coordinate full analysis                │
│  ├── filter_important/2  Extract important knobs                 │
│  ├── reduce_knob_space/3 Create reduced space                    │
│  └── quick_reduce/1      Domain knowledge shortcut               │
├─────────────────────────────────────────────────────────────────┤
│  PgGaConf.Julia                                                  │
│  ├── generate_sobol_samples/2  Create quasi-random samples       │
│  └── compute_sensitivity/3     Calculate S1/ST indices           │
├─────────────────────────────────────────────────────────────────┤
│  PgGaConf.Fingerprint                                            │
│  ├── extract/1           Capture workload characteristics        │
│  ├── similarity/2        Compare fingerprints                    │
│  └── classify/1          Determine workload type                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Julia (Numerical Computing)                  │
├─────────────────────────────────────────────────────────────────┤
│  priv/julia/server.jl                                            │
│  ├── Sobol.jl           Generate Sobol sequences                 │
│  └── GlobalSensitivity  Compute variance-based indices           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Technical Deep Dive: Elixir ↔ Julia Communication

This section explains the complete data flow from Elixir parameter definitions through Julia's Sobol sequence generation.

### Step 1: Elixir Encodes the Parameter Space

The parameter space starts in Elixir as a map with typed bounds:

```elixir
%{
  shared_buffers: {:continuous, 128.0, 8192.0},
  work_mem: {:continuous, 4.0, 512.0},
  random_page_cost: {:continuous, 1.0, 4.0},
  max_parallel_workers: {:integer, 0, 8}
}
```

The `PgGaConf.Julia` module encodes this to a Julia-friendly JSON format:

```elixir
# lib/pg_ga_conf/julia.ex
defp encode_knobs(knobs) when is_map(knobs) do
  Map.new(knobs, fn {name, def} ->
    {to_string(name), encode_knob_def(def)}
  end)
end

defp encode_knob_def({:continuous, min, max}), do: [min, max]
defp encode_knob_def({:integer, min, max}), do: [min, max]
defp encode_knob_def({:categorical, choices}), do: [0, length(choices) - 1]
```

Result sent to Julia:
```json
{
  "shared_buffers": [128.0, 8192.0],
  "work_mem": [4.0, 512.0],
  "random_page_cost": [1.0, 4.0],
  "max_parallel_workers": [0, 8]
}
```

### Step 2: JSON Over Stdin/Stdout

Elixir sends requests via the LocalBackend (using `erlexec`):

```json
{
  "id": 1,
  "type": "generate_sobol",
  "payload": {
    "knobs": {"shared_buffers": [128, 8192], "work_mem": [4, 512], ...},
    "n": 128
  }
}
```

### Step 3: Julia Parses the Parameter Space

In `priv/julia/server.jl`, the `handle_generate_sobol` function receives the request:

```julia
function handle_generate_sobol(request_id::Int, payload)
    knobs = payload["knobs"]
    n_samples = get(payload, "n", 128)

    # Convert to Dict{String, Vector{Float64}}
    knobs_dict = Dict{String, Vector{Float64}}()
    for (name, def) in knobs
        if isa(def, AbstractVector)
            knobs_dict[string(name)] = Float64[def[1], def[2]]
        elseif isa(def, AbstractDict)
            knobs_dict[string(name)] = Float64[def["min"], def["max"]]
        end
    end

    samples, matrices = generate_sobol_samples(knobs_dict, n_samples)
    ...
end
```

### Step 4: Sobol Sequence Generation

The core algorithm in `priv/julia/sensitivity.jl`:

```julia
function generate_sobol_samples(knobs::Dict, n_samples::Int)
    knob_names = collect(keys(knobs))
    n_dims = length(knob_names)

    # Generate Sobol sequence using Julia's Sobol.jl library
    # Need 2*D dimensions for Saltelli's A and B matrices
    seq = SobolSeq(n_dims * 2)

    # Skip initial points for better uniformity (standard practice)
    skip(seq, n_samples)

    # Generate base samples in [0,1]^D unit hypercube
    raw_samples = zeros(n_samples, n_dims * 2)
    for i in 1:n_samples
        raw_samples[i, :] = next!(seq)
    end
    ...
end
```

**Why Sobol sequences?** Unlike pseudo-random numbers that cluster, Sobol sequences are **quasi-random** (low-discrepancy) and fill the parameter space uniformly:

```
Pseudo-random (clusters):        Sobol (uniform coverage):
  ●●  ●                            ●    ●    ●    ●
   ●●●                             ●    ●    ●    ●
      ●  ●●●                       ●    ●    ●    ●
   ●                               ●    ●    ●    ●
```

### Step 5: Saltelli's A, B, AB Matrix Design

For sensitivity analysis, Julia creates special sample matrices:

```julia
# Split raw samples into A and B matrices
A = raw_samples[:, 1:n_dims]
B = raw_samples[:, (n_dims+1):end]

# Generate AB matrices - one per parameter
# AB_i is matrix A with column i replaced by column i from B
AB_matrices = Dict{String, Matrix{Float64}}()
for (j, name) in enumerate(knob_names)
    AB = copy(A)
    AB[:, j] = B[:, j]  # Replace column j with B's column j
    AB_matrices[name] = AB
end
```

This is **Saltelli's extension** of the Sobol method. By comparing benchmark results:
- **Y(A) vs Y(AB_i)**: Measures the effect of parameter i while keeping all others fixed
- The variance decomposition reveals each parameter's contribution

### Step 6: Transform Unit Samples to Parameter Ranges

Sobol sequences generate values in [0,1]. Julia transforms them to actual ranges:

```julia
function transform_sample(unit_sample::Vector{Float64})
    config = Dict{String, Any}()
    for (j, name) in enumerate(knob_names)
        bounds = knobs[name]
        min_val, max_val = bounds[1], bounds[2]
        # Linear transform: [0,1] → [min, max]
        config[name] = min_val + unit_sample[j] * (max_val - min_val)
    end
    return config
end
```

Example for `shared_buffers` with bounds [128, 8192]:
- Unit value 0.0 → 128 MB
- Unit value 0.5 → 4160 MB
- Unit value 1.0 → 8192 MB

### Step 7: Total Samples Generated

The function creates samples for all matrices:

```julia
samples = Vector{Dict{String, Any}}()

# A matrix samples (N samples)
for i in 1:n_samples
    push!(samples, transform_sample(A[i, :]))
end

# B matrix samples (N samples)
for i in 1:n_samples
    push!(samples, transform_sample(B[i, :]))
end

# AB matrix samples for each dimension (D × N samples)
for name in knob_names
    AB = AB_matrices[name]
    for i in 1:n_samples
        push!(samples, transform_sample(AB[i, :]))
    end
end
```

**Total samples**: `N + N + (D × N) = N × (D + 2)`

For `n_samples=128` and `D=4` knobs: `128 × (4 + 2) = 768` configurations.

### Step 8: Response Back to Elixir

Julia returns the samples and matrices as JSON:

```julia
return Dict(
    "samples" => samples,           # Array of config dicts
    "matrices" => matrices_json,    # For later sensitivity computation
    "total_samples" => length(samples),
    "cache_id" => request_id
)
```

Each sample looks like:
```json
{"shared_buffers": 4523.7, "work_mem": 128.3, "random_page_cost": 2.1, "max_parallel_workers": 3}
```

### Step 9: Elixir Runs Benchmarks

Elixir iterates through all samples, applying each configuration to PostgreSQL and running pgbench:

```elixir
results = Enum.map(samples, fn sample ->
  config = decode_sample_to_config(sample, knob_space)

  case benchmark_fn.(config) do
    {:ok, score} -> score
    {:error, _} -> 1.0e10  # Penalty for failed configs
  end
end)
```

### Step 10: Julia Computes Sensitivity Indices

After receiving all benchmark scores, Julia computes the Saltelli estimators:

```julia
function compute_sensitivity_indices(results::Vector{Float64}, matrices::Dict, knobs::Dict)
    N = matrices["n_samples"]
    D = matrices["n_dims"]

    # Split results into A, B, and AB sections
    Y_A = results[1:N]
    Y_B = results[(N+1):(2*N)]

    # Y_AB for each dimension
    Y_AB = Dict{String, Vector{Float64}}()
    offset = 2 * N
    for (j, name) in enumerate(knob_names)
        Y_AB[name] = results[(offset + (j-1)*N + 1):(offset + j*N)]
    end

    # Compute variance
    var_Y = var(vcat(Y_A, Y_B))

    for name in knob_names
        # First-order index (Saltelli 2010)
        # S_i = (1/N) * sum(Y_B .* (Y_AB_i - Y_A)) / Var(Y)
        V_i = mean(Y_B .* (Y_AB[name] .- Y_A))
        first_order[name] = V_i / var_Y

        # Total-order index (Jansen 1999)
        # S_Ti = (1/2N) * sum((Y_A - Y_AB_i).^2) / Var(Y)
        V_Ti = 0.5 * mean((Y_A .- Y_AB[name]).^2)
        total_order[name] = V_Ti / var_Y
    end
    ...
end
```

### Complete Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ELIXIR                                                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. Define parameter space:                                                   │
│    %{shared_buffers: {:continuous, 128, 8192}, work_mem: {:continuous, ...}} │
│                                                                              │
│ 2. Encode to [min, max] format and send JSON via stdin                      │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ JULIA                                                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│ 3. Parse JSON → Dict{String, Vector{Float64}} (bounds per parameter)        │
│                                                                              │
│ 4. Generate Sobol sequence in [0,1]^D space using Sobol.jl                  │
│    - Quasi-random → uniform space coverage                                   │
│    - Create A, B, AB matrices (Saltelli design)                             │
│                                                                              │
│ 5. Transform [0,1] → [min, max] for each parameter                          │
│                                                                              │
│ 6. Return N×(D+2) sample configurations as JSON                             │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ ELIXIR (benchmark loop)                                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│ 7. For each sample: apply config to PostgreSQL, run pgbench, record score   │
│                                                                              │
│ 8. Send scores array back to Julia                                          │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ JULIA                                                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│ 9. Compute Saltelli estimators:                                             │
│    - S1 (first-order): direct contribution                                  │
│    - ST (total-order): contribution + interactions                          │
│                                                                              │
│ 10. Return sensitivity indices per parameter                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Best Practices

### Do

- **Always run Sobol before optimization** — reduces dimensionality dramatically
- **Use caching for repeated analyses** — similar workloads share sensitivity profiles
- **Provide restart_fn for shared_buffers** — enables efficient batched evaluation
- **Set appropriate n_samples** — 64-128 for most cases, 256 for research

### Don't

- **Skip Sobol for "known" workloads** — actual measurements beat assumptions
- **Use very low n_samples** — insufficient statistical power
- **Ignore ST - S1 gaps** — interaction effects matter
- **Cache across very different workloads** — fingerprint similarity threshold exists for a reason

---

## Summary

| Feature | Benefit |
|---------|---------|
| **Variance-based analysis** | Statistically rigorous sensitivity measurement |
| **Workload-agnostic** | Discovers important knobs for ANY workload |
| **Interaction detection** | Captures parameter dependencies via ST - S1 |
| **Fingerprint caching** | Reuse results for similar workloads |
| **Batched restarts** | Efficient handling of restart-required params |
| **Julia backend** | Fast numerical computation |

**Bottom line**: Run Sobol first, optimize the reduced space. This combination delivers better results faster than optimizing blind.
