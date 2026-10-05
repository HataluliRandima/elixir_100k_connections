defmodule Mix.Tasks.LoadTest do
  @shortdoc "Opens N concurrent WebSocket connections to a local Phoenix server"

  @moduledoc """
  Opens a controlled number of persistent WebSocket connections against the
  experiment server and records what happened.

      mix load_test --connections 1000

  The BEAM's default process limit is 262,144. Above roughly 200k clients,
  raise it: `ERL_FLAGS="+P 2000000" mix load_test ...` (scripts/run_benchmark.sh
  does this for you).

  ## Options

    * `--connections N` (required) - number of concurrent clients
    * `--url URL` - default `ws://127.0.0.1:4000/socket/websocket`
    * `--ramp-up SECONDS` - spread connection starts over this window (default 10)
    * `--duration SECONDS` - hold all connections open this long after ramp-up (default 60)
    * `--message-interval MS` - ping interval per client, 0 disables (default 30000)
    * `--message-rate N` - total pings/second across all clients; overrides `--message-interval`
    * `--connection-duration SECONDS` - each client closes itself after this long (default: never)
    * `--source-ips IP,IP,...` - round-robin local source addresses (e.g. 127.0.0.1,127.0.0.2)
      to get past the ~28k ephemeral ports available per source address
    * `--sample-interval MS` - how often to sample both sides (default 2000)
    * `--no-server-metrics` - don't poll the server's /metrics endpoint
    * `--metrics-url URL` - default derived from `--url`
    * `--min-free-mb MB` - abort if host MemAvailable drops below this (default 512)
    * `--connect-timeout MS` - TCP connect timeout (default 10000)
    * `--output PATH` - write the full JSON result here
    * `--csv PATH` - append a one-line summary to this CSV file
    * `--label TEXT` - free-form label stored in the result
    * `--allow-remote` - permit a non-loopback target (only a server you control)
  """

  use Mix.Task

  alias LoadGenerator.{Config, Report, Runner}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    case Config.parse(argv) do
      {:ok, config, warnings} ->
        Enum.each(warnings, &Mix.shell().error("warning: " <> &1))
        check_process_limit!(config)
        print_banner(config)

        report = Runner.run(config, log: &Mix.shell().info/1)

        if config.output, do: Report.write_json(report, config.output)
        if config.csv, do: Report.append_csv(report, config.csv)

        print_summary(report, config)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  # Each client is one process; leave headroom for the runtime itself.
  defp check_process_limit!(config) do
    limit = :erlang.system_info(:process_limit)

    if config.connections + 1_000 > limit do
      Mix.raise(
        "#{config.connections} clients need more than this VM's process limit (#{limit}). " <>
          "Re-run with ERL_FLAGS=\"+P 2000000\"."
      )
    end
  end

  defp print_banner(config) do
    Mix.shell().info("""
    ==> load test
        target:       #{config.url}
        connections:  #{config.connections}
        ramp-up:      #{config.ramp_up_s}s (~#{rate(config)} connections/s)
        hold:         #{config.duration_s}s
        ping every:   #{if config.message_interval_ms == 0, do: "never", else: "#{config.message_interval_ms}ms"}
        source IPs:   #{source_ips(config)}
        safety stop:  host MemAvailable < #{config.min_free_mb}MB
    """)
  end

  defp print_summary(report, config) do
    s = report.summary

    Mix.shell().info("""

    ==> result: #{report.status}#{if report.abort_reason, do: " (#{report.abort_reason})"}
        connected:        #{s.successfully_connected}/#{s.target_connections}
        failed:           #{s.failed_connections}
        peak open:        #{s.peak_open_connections}
        open at end:      #{s.open_at_end_of_hold}
        disconnected:     #{s.disconnected_unexpectedly}
        closed cleanly:   #{s.closed_cleanly}
        messages:         #{s.messages_sent} sent / #{s.messages_received} received / #{s.message_timeouts} timeouts
          at end of hold: #{s.at_end_of_hold.messages_sent} sent / #{s.at_end_of_hold.messages_received} received (the rest were in flight during teardown)
        connect latency:  #{latency(s.connect_latency)}
        ping RTT:         #{latency(s.message_rtt)}
        server per conn:  #{per_conn(s.server.per_connection)}
        loadgen per conn: #{per_conn(s.loadgen.per_connection)}
        errors:           #{inspect(s.errors)}
    #{if config.output, do: "    written to:       #{config.output}", else: ""}
    """)
  end

  defp rate(%{ramp_up_s: +0.0} = config), do: config.connections
  defp rate(config), do: round(config.connections / config.ramp_up_s)

  defp source_ips(%{source_ips: []}), do: "kernel default"
  defp source_ips(%{source_ips: ips}), do: Enum.map_join(ips, ", ", &to_string(:inet.ntoa(&1)))

  defp latency(%{count: 0}), do: "no samples"

  defp latency(l) do
    "p50 #{l.p50_ms}ms p90 #{l.p90_ms}ms p99 #{l.p99_ms}ms max #{l.max_ms}ms (n=#{l.count})"
  end

  defp per_conn(nil), do: "n/a"

  defp per_conn(p) do
    "#{kb(p[:beam_process_memory_bytes])} process heap, #{kb(p[:beam_memory_bytes])} BEAM total, " <>
      "#{kb(p[:rss_bytes])} RSS, #{p[:processes]} processes"
  end

  defp kb(nil), do: "?"
  defp kb(bytes), do: "#{Float.round(bytes / 1024, 1)}KB"
end
