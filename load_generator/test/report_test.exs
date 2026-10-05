defmodule LoadGenerator.ReportTest do
  use ExUnit.Case, async: true

  alias LoadGenerator.{Config, Report, Stats}

  defp run_data(overrides \\ %{}) do
    {:ok, config, _} = Config.parse(["--connections", "10", "--label", "unit, test"])

    Map.merge(
      %{
        config: config,
        environment: %{},
        stats: Stats.new(),
        started_at: ~U[2026-01-01 00:00:00Z],
        finished_at: ~U[2026-01-01 00:01:00Z],
        duration_ms: 60_000,
        ramp_finished_ms: 1_000,
        teardown_ms: 100,
        forced_shutdowns: 0,
        abort_reason: nil,
        open_at_end_of_hold: 0,
        client_at_end_of_hold: %{
          messages_sent: 0,
          messages_received: 0,
          message_timeouts: 0,
          open: 0,
          failed: 0,
          disconnected: 0
        },
        server_baseline: nil,
        server_at_peak: nil,
        server_after: nil,
        loadgen_baseline: %{
          memory_total_bytes: 0,
          memory_processes_bytes: 0,
          rss_bytes: 0,
          process_count: 0
        },
        loadgen_at_peak: %{
          memory_total_bytes: 0,
          memory_processes_bytes: 0,
          rss_bytes: 0,
          process_count: 0
        },
        samples: []
      },
      overrides
    )
  end

  test "a run with no connections has no latency or per-connection numbers" do
    report = Report.build(run_data())

    assert report.status == "completed"
    assert report.summary.message_rtt == %{count: 0}
    assert report.summary.connect_latency == %{count: 0}
    assert report.summary.server.per_connection == nil
    assert report.summary.loadgen.per_connection == nil
  end

  test "an aborted run says why" do
    report = Report.build(run_data(%{abort_reason: "low_memory"}))
    assert report.status == "aborted"
    assert report.abort_reason == "low_memory"
  end

  test "per-connection server cost is the delta from baseline divided by open connections" do
    base = %{
      memory_total_bytes: 1_000,
      memory_processes_bytes: 500,
      rss_bytes: 10_000,
      process_count: 400,
      port_count: 4
    }

    peak = %{
      memory_total_bytes: 11_000,
      memory_processes_bytes: 5_500,
      rss_bytes: 30_000,
      process_count: 420,
      port_count: 14
    }

    assert Report.per_connection(base, peak, 10) == %{
             beam_memory_bytes: 1_000,
             beam_process_memory_bytes: 500,
             rss_bytes: 2_000,
             processes: 2.0,
             ports: 1.0
           }

    assert Report.per_connection(nil, peak, 10) == nil
  end

  test "CSV rows have one value per header column and escape commas" do
    report = Report.build(run_data())
    header = Report.csv_header() |> String.split(",")
    row = Report.csv_row(report)

    assert row =~ ~s("unit, test")
    # Remove the quoted label before counting separators.
    plain = String.replace(row, ~s("unit, test"), "label")
    assert length(String.split(plain, ",")) == length(header)
  end

  test "JSON output round-trips" do
    path = Path.join(System.tmp_dir!(), "report_#{System.unique_integer([:positive])}.json")
    Report.build(run_data()) |> Report.write_json(path)

    assert %{"status" => "completed", "summary" => %{"target_connections" => 10}} =
             path |> File.read!() |> Jason.decode!()

    File.rm!(path)
  end
end
