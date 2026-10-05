defmodule Elixir100kConnections.MetricsTest do
  use ExUnit.Case, async: false

  alias Elixir100kConnections.Metrics

  test "snapshot contains every counter" do
    assert Metrics.snapshot() |> Map.keys() |> Enum.sort() == Enum.sort(Metrics.names())
  end

  test "joined and closed connections move the gauge and the disconnect counter" do
    active = Metrics.get(:active_connections)
    disconnects = Metrics.get(:disconnects)

    Metrics.connection_joined()
    assert Metrics.get(:active_connections) == active + 1

    Metrics.connection_closed()
    assert Metrics.get(:active_connections) == active
    assert Metrics.get(:disconnects) == disconnects + 1
  end

  test "reset zeroes cumulative counters but keeps the active gauge" do
    Metrics.connection_joined()
    Metrics.message_received()
    active = Metrics.get(:active_connections)

    :ok = Metrics.reset()

    assert Metrics.get(:messages_received) == 0
    assert Metrics.get(:joins) == 0
    assert Metrics.get(:active_connections) == active

    Metrics.connection_closed()
  end

  test "counters are safe under concurrent updates" do
    before = Metrics.get(:messages_received)

    1..50
    |> Task.async_stream(fn _ -> for _ <- 1..1_000, do: Metrics.message_received() end)
    |> Stream.run()

    assert Metrics.get(:messages_received) == before + 50_000
  end
end
