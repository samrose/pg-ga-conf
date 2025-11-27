# PostgreSQL Configuration Optimizer Selection Guide

This guide helps you choose the right optimizer for your PostgreSQL tuning scenario.

## Overview

pg-ga-conf provides three optimization algorithms, each with distinct strengths:

| Optimizer | Algorithm Type | Best For | Sample Efficiency |
|-----------|---------------|----------|-------------------|
| **TPE** | Bayesian | Low budgets, general use | Excellent (<30 iterations) |
| **GA** | Evolutionary | Categorical params, exploration | Moderate (40-100 iterations) |
| **CMA-ES** | Evolution Strategy | Correlated continuous params | Good (30-80 iterations) |

---

## Quick Decision Tree

```
                    ┌─────────────────────────────────────┐
                    │  How many benchmark iterations      │
                    │  can you afford?                    │
                    └─────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
               < 20            20-50            > 50
                 │               │                │
                 ▼               ▼                ▼
              ┌─────┐    ┌──────────────┐   ┌──────────────┐
              │ TPE │    │ What params? │   │ What params? │
              └─────┘    └──────────────┘   └──────────────┘
                               │                   │
                    ┌──────────┴──────────┐       │
                    ▼                     ▼       ▼
              >30% categorical    Mostly numeric  │
                    │                     │       │
                    ▼                     ▼       ▼
                ┌────┐                ┌─────┐  ┌────────┐
                │ GA │                │ TPE │  │ CMA-ES │
                └────┘                └─────┘  └────────┘
```

---

## Optimizer Deep Dives

### TPE (Tree-structured Parzen Estimator)

**How it works:**
- Models the parameter space as two distributions: "good" configurations (`l(x)`) and "bad" configurations (`g(x)`)
- Suggests new configurations by maximizing `l(x)/g(x)` — preferring parameters likely to be good and unlikely to be bad
- Uses Optuna's implementation with multivariate modeling enabled

**Configuration:**
```elixir
PgGaConf.Optimizer.TPE.init(knob_space,
  n_startup_trials: 5,  # Random exploration before TPE kicks in
  seed: 42
)
```

**Strengths:**
- Most sample-efficient — learns quickly from few observations
- Handles mixed parameter types (continuous, integer, categorical) natively
- Good default choice when unsure

**Weaknesses:**
- Can get stuck in local optima with very small budgets
- Doesn't explicitly model parameter correlations (though multivariate mode helps)

**Best PostgreSQL scenarios:**

| Scenario | Why TPE Works |
|----------|---------------|
| Quick tuning session (10-20 iterations) | Maximum learning per benchmark run |
| Mixed workloads with unknown bottlenecks | Efficiently explores diverse configurations |
| Resuming from prior tuning sessions | Warm-start integrates previous observations seamlessly |
| Cloud instances with per-minute billing | Minimizes total benchmark time |

**Example knob spaces for TPE:**
```elixir
# Good for TPE: Mixed types, moderate size
%{
  shared_buffers: {:continuous, 128.0, 8192.0},
  work_mem: {:continuous, 4.0, 512.0},
  effective_cache_size: {:continuous, 512.0, 32768.0},
  random_page_cost: {:continuous, 1.0, 4.0},
  max_parallel_workers_per_gather: {:integer, 0, 4}
}
```

---

### GA (Genetic Algorithm)

**How it works:**
- Maintains a population of configurations (default: 20 individuals)
- Evolves through generations using:
  - **Tournament selection**: Picks parents from random subsets
  - **Crossover**: Combines parent configurations (smart crossover keeps related params together)
  - **Mutation**: Randomly perturbs values (15% mutation rate)
- Preserves elite individuals across generations (default: 2)

**Configuration:**
```elixir
PgGaConf.Optimizer.GA.init(knob_space,
  population_size: 20,
  elitism_count: 2,
  mutation_rate: 0.15,
  crossover_strategy: :smart,  # Keeps memory/WAL/parallel params together
  seed: 42
)
```

**Strengths:**
- Handles categorical parameters naturally — no encoding tricks needed
- "Smart crossover" understands PostgreSQL parameter relationships:
  - Memory group: `shared_buffers`, `work_mem`, `maintenance_work_mem`, `effective_cache_size`
  - WAL group: `wal_buffers`, `checkpoint_completion_target`, `max_wal_size`, `min_wal_size`
  - Parallelism group: `max_parallel_workers`, `max_parallel_workers_per_gather`, `parallel_tuple_cost`
- Good at escaping local optima through mutation
- Population-based: can run evaluations in parallel

**Weaknesses:**
- Requires more iterations (at least 2-3 generations × population size)
- Less sample-efficient than Bayesian methods
- Random initialization may waste early iterations

**Best PostgreSQL scenarios:**

| Scenario | Why GA Works |
|----------|--------------|
| Many categorical knobs (>30% of space) | Native support for discrete choices |
| Tuning `huge_pages`, `wal_level`, `synchronous_commit` | No awkward integer encoding |
| Exploring fundamentally different configurations | Population diversity prevents tunnel vision |
| Parallel benchmark infrastructure | Evaluate entire population concurrently |
| Unknown search space topology | Mutation helps escape local optima |

**Example knob spaces for GA:**
```elixir
# Good for GA: Heavy categorical presence
%{
  shared_buffers: {:continuous, 128.0, 8192.0},
  huge_pages: {:categorical, ["off", "on", "try"]},
  wal_level: {:categorical, ["minimal", "replica", "logical"]},
  synchronous_commit: {:categorical, ["off", "local", "on", "remote_write", "remote_apply"]},
  checkpoint_completion_target: {:continuous, 0.5, 0.9},
  full_page_writes: {:categorical, ["on", "off"]}
}
```

---

### CMA-ES (Covariance Matrix Adaptation Evolution Strategy)

**How it works:**
- Maintains a multivariate Gaussian distribution over the parameter space
- Learns the **covariance matrix** — understanding which parameters are correlated
- Adapts the search direction based on successful configurations
- Uses Optuna's implementation with configurable step size (`sigma0`)

**Configuration:**
```elixir
PgGaConf.Optimizer.CmaEs.init(knob_space,
  sigma0: 0.5,           # Initial step size (0.0-1.0 normalized)
  n_startup_trials: 10,  # Random exploration before CMA-ES
  seed: 42
)
```

**Strengths:**
- Learns parameter correlations automatically:
  - `shared_buffers` ↔ `effective_cache_size` (both scale with available RAM)
  - `work_mem` ↔ `max_parallel_workers_per_gather` (memory per query)
  - `checkpoint_completion_target` ↔ `max_wal_size` (WAL management)
- Excellent for continuous parameter spaces
- Adapts search strategy as it learns the landscape

**Weaknesses:**
- Requires more samples to build accurate covariance model (10+ startup trials)
- Categorical parameters must be integer-encoded (loses semantic meaning)
- Can be slow to converge in high dimensions

**Best PostgreSQL scenarios:**

| Scenario | Why CMA-ES Works |
|----------|------------------|
| Memory tuning only (buffers, caches, work_mem) | All continuous, highly correlated |
| Planner cost parameters | Continuous values with subtle interactions |
| Large iteration budget (50+) | Time to learn correlations pays off |
| Fine-tuning after initial exploration | Exploits learned structure for precision |
| OLAP workloads with parallel query tuning | Continuous parallelism costs are correlated |

**Example knob spaces for CMA-ES:**
```elixir
# Ideal for CMA-ES: All continuous, known correlations
%{
  shared_buffers: {:continuous, 128.0, 16384.0},
  work_mem: {:continuous, 4.0, 2048.0},
  maintenance_work_mem: {:continuous, 64.0, 4096.0},
  effective_cache_size: {:continuous, 512.0, 65536.0},
  random_page_cost: {:continuous, 1.0, 4.0},
  seq_page_cost: {:continuous, 0.5, 2.0},
  parallel_tuple_cost: {:continuous, 0.001, 0.1},
  parallel_setup_cost: {:continuous, 100.0, 10000.0}
}
```

---

## Workload-Specific Recommendations

### OLTP (Online Transaction Processing)

**Characteristics:** High concurrency, short queries, write-heavy, latency-sensitive

**Important knobs:**
- `shared_buffers` — Buffer pool for frequently accessed data
- `work_mem` — Per-operation memory (keep low for high concurrency)
- `checkpoint_completion_target` — Spread checkpoint I/O
- `max_wal_size` — WAL before checkpoint trigger
- `autovacuum_vacuum_cost_limit` — Autovacuum aggressiveness
- `bgwriter_lru_maxpages` — Background writer throughput

**Recommended optimizer:** **TPE**

**Why:** OLTP tuning is typically time-constrained (production systems). TPE's sample efficiency means you can find good configurations in 15-25 iterations. The knobs are mostly continuous with minimal categoricals.

```elixir
knob_space = PgGaConf.KnobSpace.oltp_knobs()
{:ok, optimizer} = PgGaConf.Optimizer.TPE.init(knob_space, n_startup_trials: 5)
```

---

### OLAP (Online Analytical Processing)

**Characteristics:** Complex queries, large scans, read-heavy, throughput-focused

**Important knobs:**
- `shared_buffers` — Large buffer pool for scan data
- `work_mem` — High values for sorts and hash joins
- `maintenance_work_mem` — Fast index builds
- `max_parallel_workers_per_gather` — Query parallelism
- `max_parallel_workers` — Total parallel workers
- `parallel_tuple_cost` / `parallel_setup_cost` — Planner parallelism thresholds
- `effective_cache_size` — Planner's cache assumption
- `random_page_cost` — Index vs scan preference

**Recommended optimizer:** **CMA-ES** (if budget allows) or **TPE**

**Why:** OLAP knobs are predominantly continuous and highly correlated (memory settings scale together, parallelism settings interact). CMA-ES excels at learning these correlations. If budget is limited, TPE is a strong fallback.

```elixir
knob_space = PgGaConf.KnobSpace.olap_knobs()

# With sufficient budget (50+ iterations)
{:ok, optimizer} = PgGaConf.Optimizer.CmaEs.init(knob_space,
  sigma0: 0.5,
  n_startup_trials: 10
)

# With limited budget
{:ok, optimizer} = PgGaConf.Optimizer.TPE.init(knob_space, n_startup_trials: 5)
```

---

### Mixed Workloads

**Characteristics:** Combined OLTP and OLAP, variable query patterns, balance required

**Important knobs:** Combination of OLTP and OLAP knobs

**Recommended optimizer:** **TPE** or **GA**

**Why:** Mixed workloads often have unpredictable bottlenecks. TPE's exploration-exploitation balance works well. If you need to tune categorical settings like `huge_pages` or replication parameters, GA handles the mixed space better.

```elixir
knob_space = PgGaConf.KnobSpace.mixed_knobs()
{:ok, optimizer} = PgGaConf.Optimizer.TPE.init(knob_space)
```

---

### Replication/HA Tuning

**Characteristics:** Durability settings, WAL configuration, synchronous replication

**Important knobs:**
- `wal_level`: `{:categorical, ["minimal", "replica", "logical"]}`
- `synchronous_commit`: `{:categorical, ["off", "local", "on", "remote_write", "remote_apply"]}`
- `wal_compression`: `{:categorical, ["off", "on", "lz4", "zstd"]}`
- `max_wal_senders`: `{:integer, 0, 10}`
- `wal_keep_size`: `{:integer, 0, 10240}`

**Recommended optimizer:** **GA**

**Why:** Heavy categorical presence. GA handles discrete choices without encoding artifacts. The population-based approach also helps explore the discrete space more thoroughly.

```elixir
replication_knobs = %{
  wal_level: {:categorical, ["replica", "logical"]},
  synchronous_commit: {:categorical, ["off", "local", "on", "remote_write"]},
  max_wal_size: {:integer, 1024, 16384},
  checkpoint_completion_target: {:continuous, 0.5, 0.9}
}

{:ok, optimizer} = PgGaConf.Optimizer.GA.init(replication_knobs,
  population_size: 16,
  crossover_strategy: :smart
)
```

---

## Advanced Strategies

### Two-Phase Optimization

For complex tuning with large budgets:

1. **Phase 1: Exploration with GA** (20-30 iterations)
   - Use GA to explore diverse configurations
   - Identify promising regions of the parameter space

2. **Phase 2: Exploitation with CMA-ES or TPE** (30-50 iterations)
   - Warm-start with best configurations from Phase 1
   - Fine-tune within the promising region

```elixir
# Phase 1: Explore with GA
{:ok, ga} = PgGaConf.Optimizer.GA.init(knob_space, population_size: 15)
# ... run 30 iterations, collect observations ...

# Phase 2: Exploit with CMA-ES
{:ok, cma} = PgGaConf.Optimizer.CmaEs.init(knob_space)
{:ok, cma} = PgGaConf.Optimizer.CmaEs.warm_start(cma, top_observations)
```

### Sobol → Optimizer Pipeline

Always run Sobol sensitivity analysis first to reduce dimensionality:

```elixir
# Step 1: Identify important knobs
{:ok, indices} = PgGaConf.Sobol.analyze(PgGaConf.KnobSpace.all(), benchmark_fn)
reduced_space = PgGaConf.Sobol.reduce_knob_space(PgGaConf.KnobSpace.all(), indices)

# Step 2: Let the system recommend an optimizer
optimizer_type = PgGaConf.Optimizer.recommend(reduced_space, budget: 30)
optimizer_module = PgGaConf.Optimizer.get_optimizer(optimizer_type)

# Step 3: Optimize the reduced space
{:ok, optimizer} = optimizer_module.init(reduced_space)
```

### Automatic Optimizer Selection

Use the built-in recommendation function:

```elixir
# Automatically picks based on knob space composition and budget
optimizer_type = PgGaConf.Optimizer.recommend(knob_space, budget: 30)

# Returns:
# - :tpe if budget < 20
# - :ga if >30% categorical knobs
# - :cma_es if <10% categorical and budget >= 30
# - :tpe otherwise (safe default)
```

---

## Summary Table

| Factor | TPE | GA | CMA-ES |
|--------|-----|-----|--------|
| **Sample efficiency** | ★★★★★ | ★★☆☆☆ | ★★★☆☆ |
| **Categorical handling** | ★★★★☆ | ★★★★★ | ★★☆☆☆ |
| **Continuous optimization** | ★★★★☆ | ★★★☆☆ | ★★★★★ |
| **Correlation learning** | ★★★☆☆ | ★★☆☆☆ | ★★★★★ |
| **Escaping local optima** | ★★★☆☆ | ★★★★☆ | ★★★☆☆ |
| **Parallel evaluation** | ★★☆☆☆ | ★★★★★ | ★★☆☆☆ |
| **Warm-start support** | ★★★★★ | ★★★★☆ | ★★★★☆ |
| **Minimum useful budget** | 10 | 40 | 30 |
| **Ideal budget range** | 15-40 | 60-150 | 40-100 |

---

## TL;DR

- **Don't know what to pick?** → Use **TPE**
- **Many on/off or enum settings?** → Use **GA**
- **All numeric, large budget, want precision?** → Use **CMA-ES**
- **Always run Sobol first** to reduce from 27 knobs to 5-10 important ones
