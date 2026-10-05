defmodule LoadGenerator.IntegrationTest do
  @moduledoc """
  End-to-end run against a real server on 127.0.0.1:4000.

      ./scripts/start_server.sh                     # in another terminal
      cd load_generator && mix test --include integration
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  alias LoadGenerator.{Config, Runner}

  test "50 clients connect, ping, and close cleanly" do
    {:ok, config, _} =
      Config.parse([
        "--connections",
        "50",
        "--ramp-up",
        "1",
        "--duration",
        "3",
        "--message-interval",
        "500",
        "--sample-interval",
        "500"
      ])

    report = Runner.run(config, log: fn _ -> :ok end)
    s = report.summary

    assert report.status == "completed"
    assert s.successfully_connected == 50
    assert s.failed_connections == 0
    assert s.open_at_end_of_hold == 50
    assert s.closed_cleanly == 50
    assert s.disconnected_unexpectedly == 0
    assert s.messages_sent > 0
    assert s.messages_received == s.messages_sent
    assert s.message_rtt.count == s.messages_received

    # The server saw the same thing, and its gauge returned to zero.
    assert s.server.at_peak.counters["active_connections"] == 50
    assert s.server.after_teardown.counters["active_connections"] == 0
    assert s.server.after_teardown.counters["joins"] == 50
  end

  test "a rejected socket is recorded as a failure with its reason" do
    {:ok, config, _} =
      Config.parse([
        "--connections",
        "3",
        "--url",
        "ws://127.0.0.1:4000/socket/websocket?reject=true",
        "--ramp-up",
        "0",
        "--duration",
        "1",
        "--no-server-metrics"
      ])

    report = Runner.run(config, log: fn _ -> :ok end)

    assert report.summary.failed_connections == 3
    assert report.summary.errors == %{"http_status:403" => 3}
  end
end
