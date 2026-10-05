defmodule LoadGenerator.Report do
  @moduledoc """
  Turns the raw data from a run into a result document and writes it as
  JSON (full detail, including the sample timeline) and as one CSV row
  (headline numbers, for graphing across runs).

  Derived values are only computed when their inputs exist. A missing input
  produces `nil`, never an estimate.
  """

  alias LoadGenerator.{Config, Histogram, Stats}

  @schema_version 1

  def build(run) do
    %{stats: stats, config: config} = run
    counters = Stats.snapshot(stats)
    samples = Enum.map(run.samples, &add_cpu(&1))
    samples = cpu_percentages(samples)

    %{
      schema_version: @schema_version,
      status: if(run.abort_reason, do: "aborted", else: "completed"),
      abort_reason: run.abort_reason,
      started_at: run.started_at,
      finished_at: run.finished_at,
      config: Config.to_map(config),
      environment: run.environment,
      summary: %{
        target_connections: config.connections,
        attempted: counters.attempted,
        successfully_connected: counters.connected,
        failed_connections: counters.failed,
        peak_open_connections: Stats.peak_open(stats),
        open_at_end_of_hold: run.open_at_end_of_hold,
        disconnected_unexpectedly: counters.disconnected,
        closed_cleanly: counters.closed,
        forced_shutdowns: run.forced_shutdowns,
        messages_sent: counters.messages_sent,
        messages_received: counters.messages_received,
        message_timeouts: counters.message_timeouts,
        at_end_of_hold:
          Map.take(run.client_at_end_of_hold, [
            :messages_sent,
            :messages_received,
            :message_timeouts,
            :open,
            :failed,
            :disconnected
          ]),
        errors: Stats.errors(stats),
        ramp_up_ms: run.ramp_finished_ms,
        test_duration_ms: run.duration_ms,
        teardown_ms: run.teardown_ms,
        connect_latency: Histogram.summary(stats.connect_latency),
        message_rtt: Histogram.summary(stats.message_rtt),
        server: server_summary(run, samples),
        loadgen: loadgen_summary(run)
      },
      samples: samples
    }
  end

  defp server_summary(run, samples) do
    %{
      baseline: run.server_baseline,
      at_peak: run.server_at_peak,
      after_teardown: run.server_after,
      per_connection:
        per_connection(run.server_baseline, run.server_at_peak, run.open_at_end_of_hold),
      hold_cpu_percent_of_one_core: hold_cpu(samples),
      max_scheduler_utilization: max_of(samples, & &1.server[:scheduler_utilization]),
      max_run_queue: max_of(samples, & &1.server[:run_queue])
    }
  end

  defp loadgen_summary(run) do
    open = run.open_at_end_of_hold
    base = run.loadgen_baseline
    peak = run.loadgen_at_peak

    %{
      baseline: base,
      at_peak: peak,
      per_connection:
        if open > 0 do
          %{
            beam_memory_bytes: per(peak.memory_total_bytes, base.memory_total_bytes, open),
            beam_process_memory_bytes:
              per(peak.memory_processes_bytes, base.memory_processes_bytes, open),
            rss_bytes: per(peak.rss_bytes, base.rss_bytes, open),
            processes: per_float(peak.process_count, base.process_count, open)
          }
        end
    }
  end

  @doc false
  def per_connection(%{memory_total_bytes: _} = base, %{memory_total_bytes: _} = peak, open)
      when open > 0 do
    %{
      beam_memory_bytes: per(peak.memory_total_bytes, base.memory_total_bytes, open),
      beam_process_memory_bytes:
        per(peak.memory_processes_bytes, base.memory_processes_bytes, open),
      rss_bytes: per(peak.rss_bytes, base.rss_bytes, open),
      processes: per_float(peak.process_count, base.process_count, open),
      ports: per_float(peak.port_count, base.port_count, open)
    }
  end

  def per_connection(_base, _peak, _open), do: nil

  defp per(a, b, n) when is_integer(a) and is_integer(b), do: round((a - b) / n)
  defp per(_, _, _), do: nil

  defp per_float(a, b, n) when is_integer(a) and is_integer(b), do: Float.round((a - b) / n, 3)
  defp per_float(_, _, _), do: nil

  # Server CPU% between consecutive samples, as a percentage of one core
  # (so 250.0 means two and a half cores busy).
  defp add_cpu(sample), do: Map.put(sample, :server_cpu_percent_of_one_core, nil)

  defp cpu_percentages(samples) do
    {samples, _prev} =
      Enum.map_reduce(samples, nil, fn sample, prev ->
        cpu = sample.server && sample.server[:cpu_time_ms]

        pct =
          with {prev_t, prev_cpu} when is_integer(prev_cpu) <- prev,
               true <- is_integer(cpu) and sample.t_ms > prev_t do
            Float.round((cpu - prev_cpu) / (sample.t_ms - prev_t) * 100, 1)
          else
            _ -> nil
          end

        next = if is_integer(cpu), do: {sample.t_ms, cpu}, else: prev
        {%{sample | server_cpu_percent_of_one_core: pct}, next}
      end)

    samples
  end

  defp hold_cpu(samples) do
    samples
    |> Enum.filter(&(&1.phase == :hold))
    |> Enum.map(& &1.server_cpu_percent_of_one_core)
    |> Enum.filter(&is_number/1)
    |> case do
      [] -> nil
      values -> Float.round(Enum.sum(values) / length(values), 1)
    end
  end

  defp max_of(samples, fun) do
    samples
    |> Enum.filter(&is_map(&1.server))
    |> Enum.map(fun)
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> nil end)
  end

  ## Writing

  def write_json(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(report, pretty: true))
  end

  @csv_columns [
    {"timestamp", [:started_at]},
    {"label", [:config, :label]},
    {"status", [:status]},
    {"target_connections", [:summary, :target_connections]},
    {"successfully_connected", [:summary, :successfully_connected]},
    {"failed_connections", [:summary, :failed_connections]},
    {"peak_open_connections", [:summary, :peak_open_connections]},
    {"open_at_end_of_hold", [:summary, :open_at_end_of_hold]},
    {"disconnected_unexpectedly", [:summary, :disconnected_unexpectedly]},
    {"closed_cleanly", [:summary, :closed_cleanly]},
    {"messages_sent", [:summary, :messages_sent]},
    {"messages_received", [:summary, :messages_received]},
    {"message_timeouts", [:summary, :message_timeouts]},
    {"connect_p50_ms", [:summary, :connect_latency, :p50_ms]},
    {"connect_p99_ms", [:summary, :connect_latency, :p99_ms]},
    {"rtt_p50_ms", [:summary, :message_rtt, :p50_ms]},
    {"rtt_p99_ms", [:summary, :message_rtt, :p99_ms]},
    {"rtt_max_ms", [:summary, :message_rtt, :max_ms]},
    {"server_beam_bytes_per_conn", [:summary, :server, :per_connection, :beam_memory_bytes]},
    {"server_process_bytes_per_conn",
     [:summary, :server, :per_connection, :beam_process_memory_bytes]},
    {"server_rss_bytes_per_conn", [:summary, :server, :per_connection, :rss_bytes]},
    {"server_processes_per_conn", [:summary, :server, :per_connection, :processes]},
    {"server_peak_rss_bytes", [:summary, :server, :at_peak, :rss_bytes]},
    {"server_peak_processes", [:summary, :server, :at_peak, :process_count]},
    {"server_hold_cpu_pct_one_core", [:summary, :server, :hold_cpu_percent_of_one_core]},
    {"server_max_scheduler_util", [:summary, :server, :max_scheduler_utilization]},
    {"loadgen_beam_bytes_per_conn", [:summary, :loadgen, :per_connection, :beam_memory_bytes]},
    {"ramp_up_ms", [:summary, :ramp_up_ms]},
    {"test_duration_ms", [:summary, :test_duration_ms]}
  ]

  def csv_header, do: Enum.map_join(@csv_columns, ",", &elem(&1, 0))

  def csv_row(report) do
    Enum.map_join(@csv_columns, ",", fn {_name, path} -> report |> dig(path) |> csv_value() end)
  end

  def append_csv(report, path) do
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, csv_header() <> "\n")
    File.write!(path, csv_row(report) <> "\n", [:append])
  end

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: map |> Map.get(key) |> dig(rest)
  defp dig(_other, _path), do: nil

  defp csv_value(nil), do: ""
  defp csv_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp csv_value(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end

  defp csv_value(value), do: to_string(value)
end
