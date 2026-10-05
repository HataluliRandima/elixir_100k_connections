defmodule LoadGenerator.StatsTest do
  use ExUnit.Case, async: true

  alias LoadGenerator.Stats

  test "tracks open clients and the peak" do
    stats = Stats.new()

    Stats.client_opened(stats)
    Stats.client_opened(stats)
    Stats.client_closed(stats, :closed)
    Stats.client_opened(stats)
    Stats.client_closed(stats, :disconnected)

    snapshot = Stats.snapshot(stats)
    assert snapshot.connected == 3
    assert snapshot.open == 1
    assert snapshot.closed == 1
    assert snapshot.disconnected == 1
    assert Stats.peak_open(stats) == 2
  end

  test "counts error reasons" do
    stats = Stats.new()

    Stats.record_error(stats, :econnrefused)
    Stats.record_error(stats, :econnrefused)
    Stats.record_error(stats, {:http_status, 403})
    Stats.record_error(stats, {:disconnected, :closed})

    assert Stats.errors(stats) == %{
             "econnrefused" => 2,
             "http_status:403" => 1,
             "disconnected:closed" => 1
           }
  end

  test "peak is correct under concurrent opens" do
    stats = Stats.new()

    1..1_000
    |> Task.async_stream(fn _ -> Stats.client_opened(stats) end, max_concurrency: 100)
    |> Stream.run()

    assert Stats.peak_open(stats) == 1_000
  end
end
