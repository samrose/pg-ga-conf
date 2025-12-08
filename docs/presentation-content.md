# PgGaConf: Automated PostgreSQL Configuration Tuning

## Presentation Content for Slides

---

## Slide 1: The Problem

**PostgreSQL has 300+ configuration parameters**

- Most DBAs use default settings or copy-paste from blog posts
- Manual tuning requires deep expertise and extensive testing
- Optimal settings depend on:
  - Hardware (RAM, CPU, storage type)
  - Workload characteristics (read-heavy, write-heavy, mixed)
  - Data size and access patterns
- Wrong settings can cause 10x performance degradation
- Right settings can provide 2-10x improvement

---

## Slide 2: Our Solution

**PgGaConf: ML-Powered PostgreSQL Auto-Tuning**

A complete pipeline that:
1. Analyzes your database structure and workload
2. Identifies which parameters matter most for YOUR workload
3. Uses Bayesian optimization to find optimal values
4. Validates improvements before recommending changes

**Key differentiator:** We don't guess - we measure and learn.

---

## Slide 3: Architecture Overview

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Source DB     │────▶│   Clone DB      │────▶│  Tuned Config   │
│  (Production)   │     │  (Safe Testing) │     │  (Validated)    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        ▼                       ▼                       ▼
   ┌─────────┐           ┌─────────────┐         ┌──────────┐
   │  Scan   │           │   Optimize  │         │  Apply   │
   │ Schema  │           │   & Test    │         │  Config  │
   └─────────┘           └─────────────┘         └──────────┘
```

**Two-Database Architecture:**
- App DB (port 5432): Stores tuning state, never restarted
- Target DB (port 5433): Where benchmarks run, may be restarted

---

## Slide 4: Step 1 - Database Scanning

**What we capture:**

| Category | Information |
|----------|-------------|
| Schema | Tables, columns, types, constraints |
| Statistics | Row counts, data distribution, index usage |
| Relationships | Foreign keys, dependency graph |
| Current Config | All PostgreSQL settings |

**Output:** Complete database fingerprint for workload classification

```elixir
# Example scan output
%{
  tables: 12,
  total_rows: 3_975_006,
  indexes: 24,
  foreign_keys: 15,
  estimated_size: "1.2 GB"
}
```

---

## Slide 5: Step 2 - Database Cloning

**Why clone?**

- Never risk production data
- Can restart PostgreSQL freely (required for some settings)
- Isolated benchmarking environment
- Reproducible tests

**Process:**
1. `pg_dump` captures schema + data
2. Stream to new PostgreSQL instance
3. Verify data integrity
4. Ready for benchmarking in minutes

```
Source DB ──pg_dump──▶ ──pg_restore──▶ Target DB
   (5432)                                (5433)
```

---

## Slide 6: Step 3 - Sobol Sensitivity Analysis

**The Key Innovation: Know What Matters**

Not all 300+ PostgreSQL parameters affect your workload equally.

**Sobol Sensitivity Analysis tells us:**
- Which parameters have the biggest impact
- Which parameters we can ignore
- How parameters interact with each other

```
Parameter                    | Sensitivity (S1)
-----------------------------|------------------
shared_buffers               | 0.42  ████████████
effective_cache_size         | 0.28  ████████
work_mem                     | 0.15  ████
random_page_cost             | 0.08  ██
checkpoint_completion_target | 0.04  █
```

**Result:** Focus optimization on the 5-8 parameters that actually matter.

---

## Slide 7: How Sobol Works

**Parallel Worker Architecture:**

```
┌──────────────────────────────────────────────────────┐
│                   Coordinator                         │
│  Generates Sobol sequence (quasi-random sampling)    │
└──────────────────────────────────────────────────────┘
            │           │           │           │
            ▼           ▼           ▼           ▼
      ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
      │Worker 1 │ │Worker 2 │ │Worker 3 │ │Worker 4 │
      │ PG:5434 │ │ PG:5435 │ │ PG:5436 │ │ PG:5437 │
      └─────────┘ └─────────┘ └─────────┘ └─────────┘
            │           │           │           │
            └───────────┴───────────┴───────────┘
                              │
                              ▼
                   ┌─────────────────────┐
                   │  Julia GSA Library  │
                   │  Compute S1/ST      │
                   └─────────────────────┘
```

- 4 parallel PostgreSQL instances
- Each evaluates different parameter combinations
- Julia computes variance-based sensitivity indices
- Results cached for future sessions

---

## Slide 8: Step 4 - TPE Optimization

**Tree-structured Parzen Estimator (TPE)**

A Bayesian optimization algorithm that:
- Learns from every benchmark result
- Balances exploration vs exploitation
- Focuses search on promising regions
- Handles parameter interactions

```
Iteration | TPS      | Best So Far | Exploring
----------|----------|-------------|------------------
    1     | 275.08   | 275.08      | shared_buffers
    5     | 312.45   | 312.45      | work_mem impact
   10     | 298.12   | 312.45      | random_page_cost
   15     | 341.22   | 341.22      | NEW BEST!
   20     | 338.91   | 341.22      | Refining region
   25     | 356.78   | 356.78      | NEW BEST!
   30     | 354.23   | 356.78      | Converging
```

**Why TPE over Grid Search?**
- Grid search: 10^8 combinations to test
- TPE: Finds optimum in 20-50 iterations

---

## Slide 9: Step 5 - Validation

**Trust but Verify**

After optimization, we run extended validation:

| Phase | Duration | Purpose |
|-------|----------|---------|
| Optimization | 60s per iteration | Quick feedback |
| Validation | 120s | Confirm stability |

**What we check:**
- Performance improvement holds under longer load
- No regression in edge cases
- Memory usage stays bounded
- No increase in errors/deadlocks

```
==========================================
VALIDATION RESULTS
==========================================
Baseline TPS:    275.08
Optimized TPS:   356.78
Validated TPS:   352.14

Improvement:     +28.0%
Confidence:      HIGH (variance < 5%)
==========================================
```

---

## Slide 10: The Knob Space

**Parameters We Tune:**

| Parameter | Range | Impact |
|-----------|-------|--------|
| shared_buffers | 128MB - 8GB | Buffer cache size |
| effective_cache_size | 1GB - 24GB | Planner's cache estimate |
| work_mem | 4MB - 256MB | Per-operation memory |
| random_page_cost | 1.0 - 4.0 | SSD vs HDD assumption |
| checkpoint_completion_target | 0.5 - 0.9 | Write smoothing |
| max_wal_size | 1GB - 8GB | WAL before checkpoint |
| autovacuum_vacuum_cost_limit | 200 - 2000 | Vacuum aggressiveness |
| bgwriter_lru_maxpages | 100 - 1000 | Background write rate |

**Dynamically selected** based on Sobol analysis results.

---

## Slide 11: Real Results - E-commerce Demo

**Test Setup:**
- 12 tables (users, orders, products, reviews, etc.)
- 4 million rows
- Mixed read/write workload
- 16 concurrent clients

**Results:**

```
┌────────────────────────────────────────┐
│           BEFORE        AFTER          │
│                                        │
│  TPS:      275    ───▶   357          │
│                                        │
│         +30% IMPROVEMENT               │
└────────────────────────────────────────┘
```

**Key changes found:**
- shared_buffers: 128MB → 1GB
- work_mem: 4MB → 64MB
- random_page_cost: 4.0 → 1.1 (SSD detected)

---

## Slide 12: Technology Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Core | Elixir/OTP | Concurrent, fault-tolerant |
| Optimization | Python/Optuna | TPE implementation |
| Sensitivity | Julia/GlobalSensitivity.jl | Sobol analysis |
| Database | PostgreSQL | Target system |
| Persistence | Ecto/PostgreSQL | State management |

**Why this stack?**
- Elixir: Perfect for coordinating parallel workers
- Optuna: Battle-tested Bayesian optimization
- Julia: Fastest scientific computing for sensitivity analysis

---

## Slide 13: Key Features

**Production-Ready Design:**

- **Safe by default** - Never touches production, works on clones
- **Resumable sessions** - Pause and continue optimization
- **Transfer learning** - Learn from similar workloads
- **Cached analysis** - Don't repeat expensive Sobol runs
- **Parallel execution** - 4x faster sensitivity analysis
- **Validation gate** - Only recommend verified improvements

**Observability:**
- Real-time progress tracking
- Detailed metrics collection
- Full audit trail of all tests

---

## Slide 14: Workflow Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  1. SCAN        2. CLONE       3. ANALYZE      4. OPTIMIZE     │
│  ┌─────┐        ┌─────┐        ┌─────┐         ┌─────┐         │
│  │ DB  │───────▶│Clone│───────▶│Sobol│────────▶│ TPE │         │
│  └─────┘        └─────┘        └─────┘         └─────┘         │
│     │              │              │               │             │
│     ▼              ▼              ▼               ▼             │
│  Schema &      Safe test      Identify        Bayesian         │
│  Statistics    environment    important       optimization     │
│                               parameters      (20-50 iters)    │
│                                                                 │
│                                    5. VALIDATE                  │
│                                    ┌─────┐                      │
│                               ────▶│Bench│────▶ Tuned Config   │
│                                    └─────┘                      │
│                                       │                         │
│                                       ▼                         │
│                                  Extended test                  │
│                                  Confirm gains                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Slide 15: Getting Started

**Run the Demo:**

```bash
# Enter development environment
nix develop

# Start PostgreSQL instances
pg_start_all

# Run the e-commerce demo
ECOMMERCE_SCALE=10.0 \
USE_SOBOL=true \
SOBOL_SAMPLES=16 \
TPE_ITERATIONS=30 \
mix run demo_ecommerce.exs
```

**Expected output:**
- ~4M row e-commerce database created
- Sobol analysis identifies key parameters
- TPE finds optimal configuration
- Validation confirms improvement

---

## Slide 16: Future Roadmap

**Planned Enhancements:**

1. **Web UI** - Visual progress and configuration
2. **Cloud Integration** - AWS RDS, GCP Cloud SQL support
3. **Workload Recording** - Capture and replay production queries
4. **Multi-objective** - Balance throughput vs latency vs cost
5. **Continuous Tuning** - Adapt as workload changes

**Research Directions:**
- Transfer learning across database types
- Predictive performance modeling
- Automated index recommendations

---

## Slide 17: Questions?

**Resources:**

- GitHub: `pg-ga-conf`
- Demo: `mix run demo_ecommerce.exs`
- Docs: `docs/demo-walkthrough.md`

**Contact:**
- [Your contact info]

---

## Appendix: Technical Deep Dive Slides

### A1: Sobol Indices Explained

**First-order index (S1):** Direct effect of parameter
**Total-order index (ST):** Direct + all interaction effects

```
If S1 ≈ ST: Parameter acts independently
If S1 << ST: Parameter has strong interactions
```

**Example:**
```
shared_buffers:    S1=0.42, ST=0.48  (mostly independent)
work_mem:          S1=0.15, ST=0.31  (interacts with others)
```

### A2: TPE Algorithm

```
TPE models P(x|y) instead of P(y|x)

For each parameter:
  l(x) = density of x where y < y*  (good region)
  g(x) = density of x where y >= y* (bad region)

Select x that maximizes: l(x) / g(x)
```

### A3: Benchmark Methodology

**pgbench custom workload:**
```sql
-- 40% simple reads
\set user_id random(1, :scale * 10000)
SELECT * FROM users WHERE id = :user_id;

-- 30% complex joins
SELECT o.*, u.email FROM orders o
JOIN users u ON o.user_id = u.id
WHERE o.id = :order_id;

-- 20% writes
INSERT INTO audit_log (action, entity_type, ...)
VALUES ('view', 'product', ...);

-- 10% aggregations
SELECT COUNT(*), SUM(total) FROM orders
WHERE created_at > now() - interval '1 day';
```
