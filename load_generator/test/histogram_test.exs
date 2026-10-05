defmodule LoadGenerator.HistogramTest do
  use ExUnit.Case, async: true

  alias LoadGenerator.Histogram

  test "an empty histogram reports no numbers" do
    assert Histogram.summary(Histogram.new()) == %{count: 0}
    assert Histogram.percentile(Histogram.new(), 50) == nil
  end

  test "count, mean and max are exact" do
    h = Histogram.new()
    for v <- [1_000, 2_000, 3_000, 10_000], do: Histogram.record(h, v)

    summary = Histogram.summary(h)
    assert summary.count == 4
    assert summary.mean_ms == 4.0
    assert summary.max_ms == 10.0
  end

  test "percentiles are within 5% of the true value" do
    h = Histogram.new()
    values = Enum.to_list(1..10_000)
    for v <- values, do: Histogram.record(h, v * 10)

    for {pct, expected} <- [{50, 50_000}, {90, 90_000}, {99, 99_000}] do
      actual = Histogram.percentile(h, pct)
      assert actual >= expected, "p#{pct} #{actual} under-estimates #{expected}"
      assert actual <= expected * 1.05, "p#{pct} #{actual} is more than 5% above #{expected}"
    end
  end

  test "a percentile never exceeds the recorded max" do
    h = Histogram.new()
    Histogram.record(h, 1_234)
    assert Histogram.percentile(h, 99.9) == 1_234
  end

  test "bucket boundaries are monotonic" do
    indexes = Enum.map([0, 1, 2, 10, 100, 1_000, 1_000_000], &Histogram.bucket_index/1)
    assert indexes == Enum.sort(indexes)
  end

  test "concurrent recording loses no samples and keeps the true max" do
    h = Histogram.new()

    1..100
    |> Task.async_stream(fn i -> for j <- 1..1_000, do: Histogram.record(h, i * 1_000 + j) end)
    |> Stream.run()

    summary = Histogram.summary(h)
    assert summary.count == 100_000
    assert summary.max_ms == 101.0
  end
end
