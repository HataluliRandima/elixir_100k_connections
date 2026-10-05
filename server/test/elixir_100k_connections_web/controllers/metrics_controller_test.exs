defmodule Elixir100kConnectionsWeb.MetricsControllerTest do
  use Elixir100kConnectionsWeb.ConnCase, async: false

  test "GET /metrics returns counters and runtime statistics", %{conn: conn} do
    body = conn |> get("/metrics") |> json_response(200)

    assert %{"counters" => counters, "beam" => beam, "os" => os, "host" => _host} = body
    assert Map.has_key?(counters, "active_connections")
    assert Map.has_key?(counters, "messages_received")
    assert beam["process_count"] > 0
    assert beam["schedulers_online"] > 0
    assert os["pid"] == System.pid()
  end

  test "POST /metrics/reset zeroes cumulative counters", %{conn: conn} do
    Elixir100kConnections.Metrics.message_received()

    body = conn |> post("/metrics/reset") |> json_response(200)

    assert body["ok"] == true
    assert body["counters"]["messages_received"] == 0
  end
end
