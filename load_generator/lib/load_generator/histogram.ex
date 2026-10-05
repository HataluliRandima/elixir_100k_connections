defmodule LoadGenerator.Histogram do
  @moduledoc """
  A lock-free, log-bucketed latency histogram.

  Up to 100k client processes record latencies concurrently. Sending every
  sample to a collector process would make that process the bottleneck, so
  each client instead increments a bucket in a shared `:counters` array.

  Bucket upper bounds grow geometrically (`1.05^k` microseconds), so a bucket
  is never wider than 5% of its value. Percentiles are reported as the upper bound of the bucket
  that contains them, so they over-estimate by at most 5%. `count`, `sum` and
  `max` are exact (`max` lives in an `:atomics` cell so it can be updated
  with compare-and-swap).
  """

  @base 1.05
  @log_base :math.log(@base)
  # 1.05^400 µs is roughly 80 hours: anything we can measure fits.
  @buckets 400

  # Extra slots after the buckets: count and sum (µs).
  @count @buckets + 1
  @sum @buckets + 2

  @enforce_keys [:ref, :max]
  defstruct [:ref, :max]

  @type t :: %__MODULE__{ref: :counters.counters_ref(), max: :atomics.atomics_ref()}

  @spec new() :: t()
  def new do
    %__MODULE__{
      ref: :counters.new(@sum, [:write_concurrency]),
      max: :atomics.new(1, signed: true)
    }
  end

  @doc "Records one value in microseconds. Negative values are clamped to 0."
  @spec record(t(), integer()) :: :ok
  def record(%__MODULE__{ref: ref, max: max_ref}, value_us) when is_integer(value_us) do
    value_us = max(value_us, 0)
    :counters.add(ref, bucket_index(value_us), 1)
    :counters.add(ref, @count, 1)
    :counters.add(ref, @sum, value_us)
    update_max(max_ref, value_us, :atomics.get(max_ref, 1))
  end

  @doc false
  def bucket_index(value_us) when value_us <= 1, do: 1

  def bucket_index(value_us) do
    index = :math.log(value_us) / @log_base

    # Floating point can land a hair above an exact power of the base.
    index = if index - trunc(index) < 1.0e-9, do: trunc(index), else: trunc(index) + 1
    min(index + 1, @buckets)
  end

  defp bucket_upper_bound(1), do: 1
  defp bucket_upper_bound(index), do: :math.pow(@base, index - 1)

  # There is no atomic "max" instruction, so this is a compare-and-swap loop.
  # Only writers that actually raise the max contend, which is rare after
  # warm-up.
  defp update_max(_max_ref, value, current) when value <= current, do: :ok

  defp update_max(max_ref, value, current) do
    case :atomics.compare_exchange(max_ref, 1, current, value) do
      :ok -> :ok
      newer -> update_max(max_ref, value, newer)
    end
  end

  @doc """
  Summarizes the histogram in milliseconds.

  Returns `%{count: 0}` when nothing was recorded, so that results never
  contain made-up latency numbers.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{ref: ref, max: max_ref} = histogram) do
    count = :counters.get(ref, @count)

    if count == 0 do
      %{count: 0}
    else
      max_us = :atomics.get(max_ref, 1)

      %{
        count: count,
        mean_ms: to_ms(:counters.get(ref, @sum) / count),
        p50_ms: to_ms(percentile(histogram, 50, count, max_us)),
        p90_ms: to_ms(percentile(histogram, 90, count, max_us)),
        p99_ms: to_ms(percentile(histogram, 99, count, max_us)),
        p999_ms: to_ms(percentile(histogram, 99.9, count, max_us)),
        max_ms: to_ms(max_us)
      }
    end
  end

  @doc "Returns the value (µs) at or below which `pct` percent of samples fall."
  @spec percentile(t(), number()) :: number() | nil
  def percentile(%__MODULE__{ref: ref, max: max_ref} = histogram, pct) do
    case :counters.get(ref, @count) do
      0 -> nil
      count -> percentile(histogram, pct, count, :atomics.get(max_ref, 1))
    end
  end

  # Buckets are read one by one while writers keep recording, so the bucket
  # total can briefly disagree with `count`. Falling back to the max keeps the
  # answer bounded either way.
  defp percentile(%__MODULE__{ref: ref}, pct, count, max_us) do
    rank = max(1, ceil(count * pct / 100))

    result =
      Enum.reduce_while(1..@buckets, 0, fn index, seen ->
        seen = seen + :counters.get(ref, index)
        if seen >= rank, do: {:halt, {:found, index}}, else: {:cont, seen}
      end)

    case result do
      {:found, index} -> min(bucket_upper_bound(index), max_us)
      _seen -> max_us
    end
  end

  defp to_ms(us), do: Float.round(us / 1000, 3)
end
