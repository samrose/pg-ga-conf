defmodule PgGaConf.GA.Fitness do
  @moduledoc """
  Fitness function for evaluating PostgreSQL configurations.

  Combines throughput and latency metrics with penalties for:
  - Constraint violations (e.g., effective_cache_size < shared_buffers)
  - Operational issues (temp files, deadlocks, timeouts)
  """

  alias PgGaConf.Core.{ConfigChromosome, Metrics}

  # Weights for fitness components
  @throughput_weight 0.4
  @latency_weight 0.4
  @stability_weight 0.2

  # Penalties
  @constraint_violation_penalty 0.5
  @temp_file_penalty_per_file 0.001
  @deadlock_penalty_per_event 0.01
  @timeout_penalty_per_event 0.01

  @doc """
  Calculate fitness score for a chromosome given benchmark metrics.

  Higher fitness is better. Fitness is a combination of:
  - Throughput score (transactions per second)
  - Latency score (inverse of latency percentiles)
  - Stability score (cache hit ratio, penalties for issues)

  ## Returns

  A float fitness score. Typically ranges from 0.0 to 100.0+, but can be higher
  for exceptional configurations.
  """
  @spec calculate(ConfigChromosome.t(), Metrics.t()) :: float()
  def calculate(chromosome, metrics) do
    base_score =
      @throughput_weight * throughput_score(metrics) +
        @latency_weight * latency_score(metrics) +
        @stability_weight * stability_score(metrics)

    # Apply penalties
    penalties =
      constraint_penalty(chromosome) +
        temp_file_penalty(metrics) +
        deadlock_penalty(metrics) +
        timeout_penalty(metrics)

    max(base_score - penalties, 0.0)
  end

  @doc """
  Calculate throughput score from transactions per second.

  Uses logarithmic scaling to handle wide range of TPS values.
  """
  @spec throughput_score(Metrics.t()) :: float()
  def throughput_score(%Metrics{transactions_per_sec: tps}) when tps > 0 do
    # Log scale: ln(tps) normalized to roughly 0-50 range
    # 100 TPS → ~4.6, 1000 TPS → ~6.9, 10000 TPS → ~9.2
    :math.log(tps) * 10.0
  end

  def throughput_score(_), do: 0.0

  @doc """
  Calculate latency score from percentile latencies.

  Lower latency = higher score. Weighted average of p50, p95, p99.
  """
  @spec latency_score(Metrics.t()) :: float()
  def latency_score(%Metrics{
        p50_latency_ms: p50,
        p95_latency_ms: p95,
        p99_latency_ms: p99
      })
      when not is_nil(p50) and not is_nil(p95) and not is_nil(p99) do
    # Inverse latency with weights: p50 (50%), p95 (30%), p99 (20%)
    # Normalized to roughly 0-50 range
    weighted_latency = 0.5 * p50 + 0.3 * p95 + 0.2 * p99

    # Inverse and scale: 1ms → ~50, 10ms → ~35, 100ms → ~20
    if weighted_latency > 0 do
      1000.0 / (weighted_latency + 10.0)
    else
      0.0
    end
  end

  def latency_score(_), do: 0.0

  @doc """
  Calculate stability score from cache hit ratio and operational metrics.
  """
  @spec stability_score(Metrics.t()) :: float()
  def stability_score(%Metrics{cache_hit_ratio: ratio}) when not is_nil(ratio) do
    # Cache hit ratio scaled to 0-50 range
    ratio * 50.0
  end

  def stability_score(_), do: 0.0

  # Private penalty functions

  defp constraint_penalty(chromosome) do
    violations = count_constraint_violations(chromosome)
    violations * @constraint_violation_penalty
  end

  defp count_constraint_violations(chromosome) do
    violations = []

    # effective_cache_size should be >= shared_buffers
    violations =
      if chromosome.effective_cache_size != nil and chromosome.shared_buffers != nil and
           chromosome.effective_cache_size < chromosome.shared_buffers do
        [:effective_cache_size_too_small | violations]
      else
        violations
      end

    # max_parallel_workers should be >= max_parallel_workers_per_gather
    violations =
      if chromosome.max_parallel_workers != nil and
           chromosome.max_parallel_workers_per_gather != nil and
           chromosome.max_parallel_workers < chromosome.max_parallel_workers_per_gather do
        [:max_parallel_workers_too_small | violations]
      else
        violations
      end

    # max_worker_processes should be >= max_parallel_workers
    violations =
      if chromosome.max_worker_processes != nil and chromosome.max_parallel_workers != nil and
           chromosome.max_worker_processes < chromosome.max_parallel_workers do
        [:max_worker_processes_too_small | violations]
      else
        violations
      end

    length(violations)
  end

  defp temp_file_penalty(%Metrics{temp_files: temp_files}) when is_integer(temp_files) do
    temp_files * @temp_file_penalty_per_file
  end

  defp temp_file_penalty(_), do: 0.0

  defp deadlock_penalty(%Metrics{deadlocks: deadlocks}) when is_integer(deadlocks) do
    deadlocks * @deadlock_penalty_per_event
  end

  defp deadlock_penalty(_), do: 0.0

  defp timeout_penalty(%Metrics{timeouts: timeouts}) when is_integer(timeouts) do
    timeouts * @timeout_penalty_per_event
  end

  defp timeout_penalty(_), do: 0.0
end
