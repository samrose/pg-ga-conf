# Data Generator Design

> **Date:** 2025-11-26
> **Status:** Approved

## Overview

Generate synthetic data matching production database size and patterns for PostgreSQL config tuning benchmarks.

## Goals

1. **Match production size** - Generate same row counts as target database (size matters for tuning)
2. **Always synthetic** - Fake data matching production patterns, never real data (privacy-safe)
3. **Realistic distributions** - Numeric/date columns match PostgreSQL histogram statistics
4. **Referential integrity** - FK relationships maintained via topological insert order
5. **Fast generation** - COPY protocol for bulk inserts at production scale

## Design Decisions

### 1. FK Handling: Topological Order

Sort tables by FK dependencies, generate parent tables first, children reference valid parent IDs.

**Rationale:**
- Guarantees referential integrity at all times
- Simpler to implement and debug
- Natural fit for streaming inserts

### 2. Data Patterns: Hybrid Approach

- **Numeric/date columns:** Statistical sampling with histogram distributions (matches query planner)
- **String columns:** Pattern-based generation (email, UUID, phone, name, etc.)
- **Low-cardinality:** Sample from observed values with frequency matching

**Rationale:**
- Numeric distributions directly affect PostgreSQL query planner decisions
- String patterns mostly need to satisfy constraints and "look right"
- Cardinality matters for selectivity estimates

### 3. Bulk Insert: COPY Protocol

Use PostgreSQL COPY for all data insertion, batched every 50,000 rows.

**Rationale:**
- 5-10x faster than INSERT statements
- Essential for production-scale data (millions of rows)
- Postgrex supports COPY via streaming

### 4. Profiling: During Scan

Extend `DatabaseScanner.scan_database/1` to populate `data_profiles` in single pass.

**Rationale:**
- Single pass over production database is most efficient
- `data_profiles` field already exists in ScanResult
- Simple workflow: scan → generate → benchmark

## Data Profile Structure

```elixir
%{
  schema: "public",
  table: "orders",
  column: "amount",

  # Basic stats
  null_percentage: 0.05,
  distinct_count: 8420,
  total_count: 50000,

  # For numeric/date columns (from pg_stats)
  min: 10.0,
  max: 9999.99,
  mean: 245.50,
  histogram: [0.15, 0.25, 0.35, 0.15, 0.10],

  # For string columns
  pattern: :email,
  min_length: 10,
  max_length: 50,

  # For low-cardinality columns (<100 distinct)
  sample_values: ["active", "pending", "closed"],
  value_frequencies: [0.6, 0.3, 0.1]
}
```

## Profiling Strategy

1. **Query `pg_stats` first** - PostgreSQL already maintains histograms via ANALYZE
   - `most_common_vals`, `most_common_freqs` for low-cardinality
   - `histogram_bounds` for distribution
   - `null_frac`, `n_distinct` for basic stats

2. **Sample for patterns** - Use `TABLESAMPLE BERNOULLI` for string pattern detection
   - Sample up to 10,000 rows per table
   - Run through existing PatternDetector

3. **Detect low-cardinality** - Columns with <100 distinct values store actual values for exact distribution matching

## Generation Flow

```
1. Build dependency graph    - Parse FKs to determine table order
2. Topological sort          - Order tables (parents before children)
3. Create schema             - DDL: tables, constraints (FKs deferred), indexes
4. Generate data             - For each table: stream synthetic rows via COPY
5. Finalize                  - Enable FK constraints, run ANALYZE
```

### FK Reference Handling

Track generated primary keys in ETS during generation:

```elixir
# Structure: %{{"users", "id"} => MapSet.t()} of generated PKs
pk_cache = :ets.new(:pk_cache, [:set, :public])

# When generating child row, sample from parent's key set
parent_keys = :ets.lookup(pk_cache, {"users", "id"})
fk_value = Enum.random(parent_keys)
```

### COPY Streaming

```elixir
def generate_table(conn, table, profile, pk_cache) do
  columns = get_column_order(table)
  row_count = table.row_count

  # Batch every 50k rows
  Enum.chunk_every(1..row_count, 50_000)
  |> Enum.each(fn batch ->
    Postgrex.transaction(conn, fn conn ->
      copy_stream = Postgrex.stream(conn, "COPY #{table.name} (#{columns}) FROM STDIN", [])

      Enum.each(batch, fn _i ->
        row = generate_row(table, profile, pk_cache)
        csv_line = encode_csv_row(row)
        # Stream row to COPY
      end)
    end)
  end)
end
```

## ValueGenerator Module

Generates synthetic values based on column type and profile:

```elixir
defmodule PgGaConf.DataGenerator.ValueGenerator do
  # Main dispatch
  def generate(column_profile, pk_cache)

  # Numeric (histogram-based distribution)
  def generate_integer(min, max, histogram)
  def generate_float(min, max, histogram, precision)
  def generate_decimal(min, max, histogram, scale)

  # Date/time (distribution-based)
  def generate_date(min, max, histogram)
  def generate_timestamp(min, max, histogram)

  # String (pattern-based)
  def generate_email()
  def generate_uuid()
  def generate_phone()
  def generate_url()
  def generate_name()
  def generate_text(min_length, max_length)

  # Low-cardinality (sample from observed)
  def generate_from_values(values, frequencies)

  # FK reference
  def generate_fk_reference(parent_table, parent_column, pk_cache)

  # Special types
  def generate_boolean(null_pct, true_pct)
  def generate_json(sample_structure)
  def generate_array(element_generator, min_len, max_len)
end
```

### Histogram-Based Generation

```elixir
def generate_from_histogram(min, max, histogram) do
  # histogram = [0.15, 0.25, 0.35, 0.15, 0.10] (bucket frequencies)
  bucket = weighted_random(histogram)
  bucket_size = (max - min) / length(histogram)
  bucket_min = min + bucket * bucket_size
  bucket_max = bucket_min + bucket_size
  uniform_random(bucket_min, bucket_max)
end
```

## File Structure

```
lib/pg_ga_conf/
├── core/
│   ├── database_scanner.ex    # Extended: add data profiling
│   └── pattern_detector.ex    # Existing: string pattern detection
├── data_generator/
│   ├── data_generator.ex      # Main orchestrator
│   ├── value_generator.ex     # Type-specific generators
│   ├── schema_builder.ex      # DDL generation
│   └── dependency_graph.ex    # Topological sort for FK ordering
```

## Public API

```elixir
# Full workflow - scan production, generate to target
PgGaConf.generate(source_conn, target_conn, opts \\ [])

# Two-step workflow - reuse existing scan
{:ok, scan} = PgGaConf.scan(source_conn)
PgGaConf.generate_from_scan(scan, target_conn, opts)

# Options
opts = [
  scale: 1.0,               # 1.0 = same size, 0.1 = 10%
  batch_size: 50_000,       # Rows per COPY transaction
  progress_fn: &IO.puts/1,  # Progress callback
  skip_tables: [],          # Tables to exclude
  only_tables: []           # Only generate these tables
]
```

## Integration

```
scan(prod_db) → ScanResult → generate(scan, test_db) → benchmark(test_db, config) → score
     │                              │
     └── data_profiles ─────────────┘
```

## Implementation Order

1. **Extend DatabaseScanner** - Add `scan_data_profiles/1` querying `pg_stats`
2. **DependencyGraph** - Topological sort by FK relationships
3. **SchemaBuilder** - Generate DDL from ScanResult
4. **ValueGenerator** - Implement generators for each type
5. **DataGenerator** - Main orchestrator with COPY streaming
6. **Public API** - Add `generate/3` and `generate_from_scan/3`

## Testing Strategy

- Unit tests for ValueGenerator (each type produces valid output)
- Unit tests for DependencyGraph (correct topological order)
- Integration tests with real PostgreSQL (full scan → generate → verify)
