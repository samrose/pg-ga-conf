# PgGaConf Demo Walkthrough

This document provides a complete end-to-end description of what happens when you run the e-commerce demo.

## Quick Start

```bash
# Basic run
mix run demo_ecommerce.exs

# Full-featured run with Sobol analysis and parallel workers
USE_SOBOL=true SOBOL_SAMPLES=16 PARALLEL_WORKERS=4 \
PGBENCH_DURATION=30 TPE_ITERATIONS=30 \
mix run demo_ecommerce.exs
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ECOMMERCE_SCALE` | 1.0 | Data scale factor (~100k rows at 1.0) |
| `PGBENCH_DURATION` | 15 | Benchmark duration in seconds |
| `PGBENCH_CLIENTS` | 8 | Number of concurrent clients |
| `TPE_ITERATIONS` | 15 | Number of optimization iterations |
| `USE_SOBOL` | false | Run Sobol sensitivity analysis first |
| `SOBOL_SAMPLES` | 16 | Number of Sobol samples (if enabled) |
| `PARALLEL_WORKERS` | 1 | Parallel PostgreSQL instances for Sobol |
| `VALIDATION_DURATION` | 60 | Final validation benchmark duration |
| `SKIP_VALIDATION` | false | Skip the validation phase |
| `DEMO_CLONE` | false | Demonstrate scan/clone workflow |
| `CLEANUP` | true | Drop demo database after completion |
| `STOP_DBS` | true | Stop PostgreSQL instances after demo |

## The 11 Steps

### Step 0: Start PostgreSQL Instances

```
0. Starting PostgreSQL instances...
   App DB (port 5432) already running
   Target DB (port 5433) already running
```

**What happens:**
- Checks if App DB (port 5432) is running - starts it if not
- Checks if Target DB (port 5433) is running - starts it if not
- App DB stores application state (sessions, observations, cache)
- Target DB is where tuning benchmarks run (may be restarted)

### Step 1: Initialize Python/Optuna

```
1. Initializing Python/Optuna...
   Python initialized
```

**What happens:**
- Loads the Pythonx library (embedded Python for Elixir)
- Imports Optuna for TPE (Tree-structured Parzen Estimator) optimization
- Sets up the optimization sampler with multivariate=true for correlated parameters

### Step 2: Create E-commerce Database

```
2. Creating e-commerce database...
   Database 'ecommerce_demo' created
```

**What happens:**
- Connects to Target DB (port 5433)
- Drops existing `ecommerce_demo` database if present
- Creates fresh `ecommerce_demo` database

### Step 3: Create Schema and Data

```
3. Creating e-commerce schema and data...
   Populating e-commerce data (scale=1.0)...
     Generating 50 categories...
     Generating 10000 users...
     Generating 15000 addresses...
     Generating 5000 products...
     Generating inventory records...
     Generating 50000 orders...
     Generating 150000 order items...
     Generating 20000 reviews...
     Generating 30000 wishlist items...
     Generating 5000 cart items...
     Generating 100000 audit log entries...
   E-commerce data populated successfully

   Schema summary:
   - Total rows: 395430
```

**What happens:**
- Creates 12 interconnected tables:
  - `categories` - Product categories with hierarchy
  - `users` - Customer accounts with timestamps
  - `addresses` - Shipping/billing addresses (FK to users)
  - `products` - Items for sale (FK to categories)
  - `inventory` - Stock levels (FK to products)
  - `orders` - Purchase records (FK to users, addresses)
  - `order_items` - Line items (FK to orders, products)
  - `reviews` - Product reviews (FK to users, products)
  - `wishlists` - Saved items (FK to users, products)
  - `cart_items` - Shopping cart (FK to users, products)
  - `audit_log` - Activity tracking
  - `product_views` - Analytics data

- Creates constraints:
  - Foreign keys between related tables
  - Check constraints (e.g., rating 1-5, quantity > 0)
  - Unique constraints (e.g., one review per user per product)

- Creates triggers:
  - `update_inventory_on_order` - Decrements stock when order placed
  - `update_product_rating` - Recalculates average rating on new review

- Row counts scale linearly with `ECOMMERCE_SCALE`

### Step 4: Scan and Clone (Optional)

```
4. Scanning source database...
   Analyzing schema and data patterns...
   Clone complete: ecommerce_demo_clone
```

**What happens (only if `DEMO_CLONE=true`):**
- **Schema Scanning**: Extracts table definitions, columns, types, constraints
- **Data Profiling**: Analyzes value distributions, patterns, ranges
- **Dependency Analysis**: Builds foreign key graph for insert ordering
- **Clone Creation**: Generates synthetic data matching original patterns
- **Benchmark Target**: Uses clone instead of original for optimization

This demonstrates safe tuning without touching production data.

### Step 5: Apply Baseline Config

```
5. Applying conservative baseline config...
   Baseline config applied
```

**What happens:**
- Applies intentionally conservative PostgreSQL settings:
  ```sql
  ALTER SYSTEM SET shared_buffers = '128MB';
  ALTER SYSTEM SET effective_cache_size = '512MB';
  ALTER SYSTEM SET work_mem = '4MB';
  ALTER SYSTEM SET random_page_cost = '4.0';
  ALTER SYSTEM SET checkpoint_completion_target = '0.5';
  ```
- Reloads configuration with `SELECT pg_reload_conf()`
- These settings are suboptimal to give the optimizer room to improve

### Step 6: Create Benchmark Workload

```
6. Creating custom benchmark workload...
   Custom workload created
```

**What happens:**
- Generates a pgbench custom script file with realistic queries:
  ```sql
  -- Product browsing
  SELECT * FROM products WHERE category_id = :category LIMIT 20;

  -- Order history
  SELECT o.*, oi.* FROM orders o
  JOIN order_items oi ON o.id = oi.order_id
  WHERE o.user_id = :user;

  -- Product search
  SELECT * FROM products
  WHERE name ILIKE '%' || :search || '%'
  LIMIT 10;

  -- Cart operations
  INSERT INTO cart_items (user_id, product_id, quantity)
  VALUES (:user, :product, 1)
  ON CONFLICT DO UPDATE SET quantity = quantity + 1;
  ```
- Weights queries to simulate realistic e-commerce traffic

### Step 7: Run Baseline Benchmark

```
7. Running baseline benchmark...
   Baseline TPS: 2269.22
```

**What happens:**
- Runs pgbench with the custom workload:
  ```bash
  pgbench -h localhost -p 5433 -U postgres \
    -c 8 -j 2 -T 15 \
    -f workload.sql \
    ecommerce_demo
  ```
- Captures baseline TPS (transactions per second)
- This is the "before" measurement to compare against

### Step 8: Determine Knob Space (with optional Sobol)

#### Without Sobol (`USE_SOBOL=false`):

```
8. Determining knob space...
   Using default knobs: [:shared_buffers, :effective_cache_size, :work_mem,
                         :random_page_cost, :checkpoint_completion_target]
```

#### With Sobol (`USE_SOBOL=true`):

```
8. Determining knob space...
   Starting Sobol sensitivity analysis...
   Using 4 parallel workers for Sobol analysis
   Generated 112 Sobol samples for parallel evaluation

   Worker 0: Initializing PostgreSQL on port 5434
   Worker 1: Initializing PostgreSQL on port 5435
   Worker 2: Initializing PostgreSQL on port 5436
   Worker 3: Initializing PostgreSQL on port 5437

   [... samples evaluated in parallel ...]

   Sensitivity indices:
     work_mem: 5.778
     effective_cache_size: 2.898
     shared_buffers: 1.429
     random_page_cost: 1.224
     checkpoint_completion_target: 0.415

   Optimizing knobs: [:shared_buffers, :effective_cache_size, :work_mem,
                      :random_page_cost, :checkpoint_completion_target]
```

**What happens with Sobol:**

1. **Generate Sobol Sequence**: Creates quasi-random samples covering the parameter space uniformly
   - More uniform than random sampling
   - Better coverage with fewer samples

2. **Parallel Worker Setup** (if `PARALLEL_WORKERS > 1`):
   - Spins up N independent PostgreSQL instances on ports 5434+
   - Each worker has its own PGDATA directory
   - Workers clone the demo database from the target

3. **Batch by Restart Parameters**:
   - Groups samples by `shared_buffers` value (requires restart)
   - Each batch shares the same `shared_buffers` to minimize restarts
   - Non-restart parameters vary within each batch

4. **Evaluate Samples**:
   - Each worker processes its assigned batches
   - For each sample: apply config → run benchmark → record TPS
   - Results collected from all workers

5. **Call Julia for Sensitivity Analysis**:
   - Sends sample results to Julia sensitivity server
   - Julia computes Sobol sensitivity indices (S1, ST)
   - S1 = first-order effect (parameter alone)
   - ST = total effect (including interactions)

6. **Rank Knobs**:
   - Orders parameters by sensitivity (most impactful first)
   - Filters to top N knobs for optimization
   - Caches results for future runs with same workload fingerprint

### Step 9: TPE Optimization

```
9. Running TPE optimization (30 iterations)...
   Iter | TPS      | Score    | Config highlights
   -----|----------|----------|------------------
      1 |   2135.3 |  4.68e-4 | shared_buffers=1072.2, effective_cache_size=39439.2
      2 |   2107.5 |  4.74e-4 | shared_buffers=3083.7, effective_cache_size=63579.4
      3 |   2072.9 |  4.82e-4 | shared_buffers=4877.1, effective_cache_size=19448.9
     ...
     30 |   2367.1 |  4.22e-4 | shared_buffers=483.0, effective_cache_size=3273.6
```

**What happens each iteration:**

```
┌─────────────────────────────────────────────────────────────┐
│  1. OPTUNA SUGGESTS NEXT CONFIG                             │
│     TPE uses probabilistic model to pick promising values   │
│     Early iterations: mostly random exploration             │
│     Later iterations: exploit promising regions             │
│                                                             │
│  2. APPLY CONFIG TO POSTGRESQL                              │
│     ALTER SYSTEM SET shared_buffers = 'XMB';                │
│     ALTER SYSTEM SET work_mem = 'YMB';                      │
│     ... (all selected knobs)                                │
│     SELECT pg_reload_conf();                                │
│     (Restart if shared_buffers changed)                     │
│                                                             │
│  3. RUN BENCHMARK                                           │
│     pgbench -T <duration> -c <clients> database             │
│     Parse TPS from output                                   │
│                                                             │
│  4. REPORT SCORE TO OPTUNA                                  │
│     score = 1/TPS (minimization problem)                    │
│     Optuna updates its model of good vs bad regions         │
│                                                             │
│  5. TRACK BEST                                              │
│     If this TPS > best so far, save config                  │
└─────────────────────────────────────────────────────────────┘
```

**TPE Algorithm Details:**
- Maintains two distributions: good configs (top 25%) and bad configs
- Samples from good distribution, rejects if likely in bad distribution
- Multivariate mode considers parameter correlations
- Non-deterministic: different runs explore different paths

### Step 10: Analyze Results

```
10. Analyzing results...

   ┌─────────────────────────────────────────────────┐
   │           OPTIMIZATION RESULTS                  │
   ├─────────────────────────────────────────────────┤
   │ Metric        │ Baseline    │ Optimized   │ Δ   │
   ├───────────────┼─────────────┼─────────────┼─────┤
   │ TPS           │      2269.2 │      2367.1 │ 4.3% │
   └─────────────────────────────────────────────────┘

   Recommended PostgreSQL settings:
   ----------------------------------------
   ALTER SYSTEM SET shared_buffers = '483MB';
   ALTER SYSTEM SET effective_cache_size = '3274MB';
   ALTER SYSTEM SET work_mem = '38MB';
   ALTER SYSTEM SET random_page_cost = '2.76';
   ALTER SYSTEM SET checkpoint_completion_target = '0.67';
   SELECT pg_reload_conf();
   ----------------------------------------
```

**What happens:**
- Compares best found TPS against baseline
- Calculates improvement percentage
- Formats recommended settings as copy-paste SQL
- Stores observation in database for transfer learning

### Step 11: Validation Benchmark

```
11. Running validation benchmark (120s)...

   ┌─────────────────────────────────────────────────────────────┐
   │                  VALIDATION RESULTS                         │
   ├─────────────────────────────────────────────────────────────┤
   │ Metric        │ Baseline    │ Optimized   │ Validated      │
   ├───────────────┼─────────────┼─────────────┼────────────────┤
   │ TPS           │      2269.2 │      2367.1 │         2340.5 │
   │ vs Baseline   │           - │        4.3% │           3.1% │
   └─────────────────────────────────────────────────────────────┘

   ✓ Validation passed: Results consistent (1.1% variance)
```

**What happens:**
- Applies the best config found
- Runs a longer benchmark (default 120s vs 15s)
- Longer duration reduces variance, confirms improvement is real
- Compares validated TPS to both baseline and optimization result
- Passes if variance is acceptable (improvement holds up)

### Cleanup

```
=== Cleanup ===
   Resetting Target DB config...
   Dropping demo database...
   Cleanup complete!

=== Stopping PostgreSQL ===
   Stopping Target DB (port 5433)...
   Stopping App DB (port 5432)...
   PostgreSQL stopped.
```

**What happens:**
- Resets Target DB to default configuration
- Drops demo database (if `CLEANUP=true`)
- Stops PostgreSQL instances (if `STOP_DBS=true`)

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        DEMO EXECUTION FLOW                          │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────┐     ┌──────────┐     ┌──────────┐
  │ App DB   │     │ Target DB│     │ Workers  │
  │ (5432)   │     │ (5433)   │     │(5434-543N│
  └────┬─────┘     └────┬─────┘     └────┬─────┘
       │                │                │
       │  Store state   │  Benchmark     │  Parallel
       │  & cache       │  & tune        │  Sobol eval
       │                │                │
       ▼                ▼                ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │                                                                 │
  │  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐         │
  │  │ Create  │──▶│ Baseline│──▶│ Sobol   │──▶│ TPE     │         │
  │  │ Schema  │   │ Bench   │   │ Analysis│   │ Optimize│         │
  │  └─────────┘   └─────────┘   └─────────┘   └─────────┘         │
  │       │             │             │             │               │
  │       ▼             ▼             ▼             ▼               │
  │  ┌─────────────────────────────────────────────────────────┐   │
  │  │                    pgbench                              │   │
  │  │  Runs workload against Target DB, measures TPS          │   │
  │  └─────────────────────────────────────────────────────────┘   │
  │                                                                 │
  │  ┌─────────┐   ┌─────────┐   ┌─────────┐                       │
  │  │ Optuna  │   │ Julia   │   │ Ecto    │                       │
  │  │ (Python)│   │ Server  │   │ (Elixir)│                       │
  │  │         │   │         │   │         │                       │
  │  │ TPE     │   │ Sobol   │   │ Sessions│                       │
  │  │ Sampling│   │ Indices │   │ Cache   │                       │
  │  └─────────┘   └─────────┘   └─────────┘                       │
  │                                                                 │
  └─────────────────────────────────────────────────────────────────┘
```

## Recommended Configurations

### Quick Test (~5 minutes)
```bash
PGBENCH_DURATION=10 TPE_ITERATIONS=10 SKIP_VALIDATION=true mix run demo_ecommerce.exs
```

### Balanced (~15 minutes)
```bash
USE_SOBOL=true SOBOL_SAMPLES=16 PARALLEL_WORKERS=4 \
PGBENCH_DURATION=20 TPE_ITERATIONS=20 \
VALIDATION_DURATION=60 mix run demo_ecommerce.exs
```

### Production Quality (~45 minutes)
```bash
USE_SOBOL=true SOBOL_SAMPLES=32 PARALLEL_WORKERS=4 \
PGBENCH_DURATION=30 TPE_ITERATIONS=50 \
VALIDATION_DURATION=120 mix run demo_ecommerce.exs
```

### Large Dataset (stress test)
```bash
ECOMMERCE_SCALE=50.0 PGBENCH_CLIENTS=32 \
USE_SOBOL=true SOBOL_SAMPLES=16 PARALLEL_WORKERS=4 \
PGBENCH_DURATION=60 TPE_ITERATIONS=30 \
mix run demo_ecommerce.exs
```

## Understanding Results

### Good Improvement Scenarios
- Dataset larger than RAM → shared_buffers tuning helps
- Complex queries → work_mem tuning reduces disk spills
- SSD storage → random_page_cost optimization improves plans
- Write-heavy → checkpoint tuning reduces I/O spikes

### When Improvements Are Small
- Dataset fits in memory → defaults are already good
- Simple CRUD operations → less optimization opportunity
- Already well-tuned → PostgreSQL defaults are reasonable

### Interpreting Sensitivity Indices
```
work_mem: 5.778          # Most impactful for this workload
effective_cache_size: 2.898
shared_buffers: 1.429
random_page_cost: 1.224
checkpoint_completion_target: 0.415  # Least impactful
```

Higher values = more impact on performance. Focus optimization on high-sensitivity knobs.

## Troubleshooting

### "relation does not exist" errors
Tables are auto-created on first app start. Ensure App DB is running:
```bash
pg_isready -h localhost -p 5432
```

### Workers crash during Sobol
Check if ports 5434+ are available. Kill any stray PostgreSQL processes:
```bash
pkill -f "postgres.*5434"
```

### Low/negative improvement
- Increase `PGBENCH_DURATION` (reduces variance)
- Increase `TPE_ITERATIONS` (more exploration)
- Try larger `ECOMMERCE_SCALE` (creates real bottlenecks)
