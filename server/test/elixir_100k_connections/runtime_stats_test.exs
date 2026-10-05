defmodule Elixir100kConnections.RuntimeStatsTest do
  use ExUnit.Case, async: true

  alias Elixir100kConnections.{RuntimeStats, SchedulerMonitor}

  @moduletag :tmp_dir

  test "beam stats include process and scheduler information" do
    beam = RuntimeStats.beam()

    assert beam.process_count > 0
    assert beam.process_limit >= beam.process_count
    assert beam.schedulers_online > 0
    assert beam.memory.total > 0
  end

  test "parses the TCP line of /proc/net/sockstat", %{tmp_dir: dir} do
    path = Path.join(dir, "sockstat")

    File.write!(path, """
    sockets: used 639
    TCP: inuse 37 orphan 0 tw 2 alloc 81 mem 5
    UDP: inuse 4 mem 0
    """)

    assert RuntimeStats.tcp_sockstat(path) == %{
             "inuse" => 37,
             "orphan" => 0,
             "tw" => 2,
             "alloc" => 81,
             "mem" => 5
           }
  end

  test "missing /proc files yield nil rather than crashing" do
    assert RuntimeStats.tcp_sockstat("/definitely/not/here") == nil
    assert RuntimeStats.read_proc_kv("/definitely/not/here") == %{}
  end

  test "summarizes scheduler utilization samples" do
    utilization = [
      {:total, 0.25, ~c"25.0%"},
      {:weighted, 0.25, ~c"25.0%"},
      {:normal, 2, 0.5, ~c"50.0%"},
      {:normal, 1, 0.0, ~c"0.0%"},
      {:cpu, 13, 0.0, ~c"0.0%"}
    ]

    assert SchedulerMonitor.summarize(utilization, 1_000) == %{
             window_ms: 1_000,
             total: 0.25,
             per_scheduler: [0.0, 0.5]
           }
  end
end
