# Parallel Sobol Workers Design

## Overview

Run multiple PostgreSQL instances locally to evaluate Sobol sensitivity samples in parallel, reducing wall-clock time from ~14 minutes to ~4 minutes with 4 workers.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Coordinator (Sobol.Parallel)             │
│  1. Generate all Sobol samples                              │
│  2. Group into batches by shared_buffers value              │
│  3. Assign batches to workers (static round-robin)          │
│  4. Start workers, wait for all to complete                 │
│  5. Collect results, compute sensitivity via Julia          │
└─────────────────────────────────────────────────────────────┘
         │              │              │              │
         ▼              ▼              ▼              ▼
   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │ Worker 1 │   │ Worker 2 │   │ Worker 3 │   │ Worker 4 │
   │ Port 5434│   │ Port 5435│   │ Port 5436│   │ Port 5437│
   │ Batches  │   │ Batches  │   │ Batches  │   │ Batches  │
   │  1, 5    │   │  2, 6    │   │  3, 7    │   │  4, 8    │
   └──────────┘   └──────────┘   └──────────┘   └──────────┘
```

## Worker Lifecycle

```
1. INIT
   - Create PGDATA directory (.postgres-worker-N)
   - initdb with unique port (5434 + N)
   - Start PostgreSQL

2. FOR EACH ASSIGNED BATCH:
   a. Clone database from source (pg_dump | pg_restore)
   b. Apply batch's shared_buffers config
   c. Restart PostgreSQL
   d. FOR EACH SAMPLE in batch:
      - Apply non-restart config (work_mem, etc.)
      - pg_reload_conf()
      - Run pgbench, record score
   e. Report batch results to coordinator

3. CLEANUP
   - Stop PostgreSQL
   - Remove PGDATA directory
```

## Module Structure

```
lib/pg_ga_conf/sobol/
├── parallel.ex          # Coordinator - orchestrates parallel evaluation
└── worker.ex            # Worker - manages single PostgreSQL instance
```

### Sobol.Parallel (coordinator)
- `evaluate_parallel(samples, knob_space, source_db, opts)` - main entry point
- Groups samples into batches by `shared_buffers`
- Spawns worker Tasks, assigns batches round-robin
- Collects results, maintains original sample ordering

### Sobol.Worker (worker)
- `start(worker_id, port, pgdata_dir)` - initialize PostgreSQL instance
- `run_batch(batch, source_db, benchmark_spec)` - clone DB, run samples
- `stop()` - cleanup PostgreSQL and data directory

### Changes to existing Sobol
- Add `:parallel_workers` option to `analyze/3`
- When `parallel_workers > 1`, delegate to `Sobol.Parallel`
- When `parallel_workers == 1`, use existing sequential code

## Database Cloning

Uses streaming pg_dump | pg_restore (no intermediate file):

```elixir
System.cmd("bash", ["-c", """
  pg_dump -h #{source_host} -p #{source_port} -U #{source_user} -Fc #{source_db} | \
  pg_restore -h localhost -p #{target_port} -U postgres -d #{target_db_name}
"""])
```

Clone happens once per batch (when shared_buffers changes), not per sample.

## Error Handling

| Scenario | Handling |
|----------|----------|
| Worker PostgreSQL fails to start | Log error, mark worker as failed, continue with remaining workers |
| pg_dump/pg_restore fails | Retry once, then mark batch as failed (score = 1.0e10) |
| pgbench times out | Kill process, record failure score, continue to next sample |
| Worker crashes mid-batch | Other workers continue, failed samples get penalty score |

Cleanup is guaranteed via try/after - all worker PostgreSQL instances and data directories are removed even on crash.

## Usage

### Environment variable
```bash
PARALLEL_WORKERS=4 USE_SOBOL=true mix run demo_ecommerce.exs
```

### Programmatic API
```elixir
Sobol.analyze(knob_space, benchmark_fn,
  n_samples: 16,
  parallel_workers: 4,
  source_db: "ecommerce_demo",
  source_port: 5433
)
```

## Port Allocation

- App DB: 5432 (untouched)
- Target DB: 5433 (untouched)
- Worker 1: 5434
- Worker 2: 5435
- Worker 3: 5436
- Worker 4: 5437

## Expected Performance

| Workers | Sobol Time (56 samples) | Speedup |
|---------|-------------------------|---------|
| 1       | ~14 min                 | 1x      |
| 4       | ~4 min                  | 3.5x    |

## Design Decisions

1. **Clone per batch** (not per sample) - balances isolation with speed
2. **Static assignment** (not work queue) - simpler, same-machine workers have similar performance
3. **Environment variable control** - explicit, matches existing pattern
4. **Partial results accepted** - failed workers don't abort entire analysis
