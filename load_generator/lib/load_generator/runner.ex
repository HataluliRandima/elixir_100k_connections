defmodule LoadGenerator.Runner do
  @moduledoc """
  Drives one load-test run:

      baseline -> ramp_up -> hold -> teardown -> report

    * **baseline**: record server metrics before any client exists.
    * **ramp_up**: start clients at a steady rate so that all
      `connections` have been *started* after `ramp_up_s` seconds.
    * **hold**: keep every connection open for `duration_s` seconds while
      clients ping and the runner samples both sides.
    * **teardown**: ask every client to close cleanly, wait, then record the
      server again to check that its gauges return to zero.

  A safety guard stops the ramp and tears down early if the machine's
  `MemAvailable` drops below `min_free_mb`, so an over-ambitious target ends
  in a recorded "aborted" result instead of an out-of-memory machine.

  The runner is a single process with a `receive ... after` loop. It never
  sits in the path of client traffic; clients write their own statistics.
  """

  alias LoadGenerator.{Client, Config, Report, ServerMetrics, Stats, SystemInfo}

  @tick_ms 10
  @teardown_timeout_ms 60_000

  @spec run(Config.t(), keyword()) :: map()
  def run(%Config{} = config, opts \\ []) do
    log = Keyword.get(opts, :log, &IO.puts/1)
    supervisor = Keyword.get(opts, :supervisor, LoadGenerator.ClientSupervisor)

    preload_modules()
    stats = Stats.new()
    environment = SystemInfo.environment()
    started_at = DateTime.utc_now()
    t0 = now_ms()

    server_baseline = server_baseline(config, log)
    loadgen_baseline = SystemInfo.loadgen_stats()

    state = %{
      config: config,
      stats: stats,
      supervisor: supervisor,
      log: log,
      t0: t0,
      phase: :ramp_up,
      started: 0,
      ramp_finished_ms: nil,
      hold_until: nil,
      next_sample_at: t0,
      sample_index: 0,
      samples: %{},
      server_request: nil,
      last_server: nil,
      abort_reason: nil
    }

    log.(
      "ramping up #{config.connections} connections over #{config.ramp_up_s}s, " <>
        "then holding for #{config.duration_s}s"
    )

    state = loop(state)

    open_at_end_of_hold = Stats.get(stats, :open)
    # Counters before teardown: pings in flight when clients start closing
    # can legitimately go unanswered, so steady-state numbers come from here.
    client_at_end_of_hold = Stats.snapshot(stats)
    server_at_peak = fetch_server(config)
    loadgen_at_peak = SystemInfo.loadgen_stats()
    log.("hold finished with #{open_at_end_of_hold} open connections; closing all clients")

    {state, teardown_ms, forced} = teardown(state)
    # Give the server a moment to process the last close frames.
    Process.sleep(1_000)
    server_after = fetch_server(config)

    Report.build(%{
      config: config,
      environment: environment,
      stats: stats,
      started_at: started_at,
      finished_at: DateTime.utc_now(),
      duration_ms: now_ms() - t0,
      ramp_finished_ms: state.ramp_finished_ms,
      teardown_ms: teardown_ms,
      forced_shutdowns: forced,
      abort_reason: state.abort_reason,
      open_at_end_of_hold: open_at_end_of_hold,
      client_at_end_of_hold: client_at_end_of_hold,
      server_baseline: server_baseline,
      server_at_peak: server_at_peak,
      server_after: server_after,
      loadgen_baseline: loadgen_baseline,
      loadgen_at_peak: loadgen_at_peak,
      samples: state.samples |> Map.values() |> Enum.sort_by(& &1.t_ms)
    })
  end

  ## Baseline

  # Modules load lazily on first use. Loading them before the baseline keeps
  # code memory out of the per-connection memory figures.
  defp preload_modules do
    for app <- [:mint, :mint_web_socket, :jason, :load_generator],
        {:ok, modules} <- [:application.get_key(app, :modules)],
        module <- modules do
      Code.ensure_loaded(module)
    end
  end

  defp server_baseline(%Config{server_metrics: false}, _log), do: nil

  defp server_baseline(%Config{metrics_url: url}, log) do
    case ServerMetrics.reset(url) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log.("warning: could not reset server counters at #{url}/reset: #{inspect(reason)}")
    end

    fetch_server(%Config{server_metrics: true, metrics_url: url})
  end

  defp fetch_server(%Config{server_metrics: false}), do: nil

  defp fetch_server(%Config{metrics_url: url}) do
    case ServerMetrics.fetch(url) do
      {:ok, metrics} -> ServerMetrics.compact(metrics)
      {:error, reason} -> %{error: Stats.format_reason(reason)}
    end
  end

  ## Main loop

  defp loop(%{phase: :done} = state), do: state

  defp loop(state) do
    now = now_ms()

    state
    |> advance(now)
    |> maybe_sample(now)
    |> wait()
    |> loop()
  end

  defp advance(%{phase: :ramp_up, config: config} = state, now) do
    due = due_started(config, now - state.t0)
    state = start_clients(state, due - state.started)

    if state.started >= config.connections do
      log_phase(state, "ramp-up finished: #{state.started} clients started")

      %{
        state
        | phase: :hold,
          ramp_finished_ms: now - state.t0,
          hold_until: now + round(config.duration_s * 1000)
      }
    else
      state
    end
  end

  defp advance(%{phase: :hold, hold_until: hold_until} = state, now) when now >= hold_until do
    %{state | phase: :done}
  end

  defp advance(state, _now), do: state

  @doc false
  # How many clients should have been started `elapsed_ms` into the ramp.
  def due_started(%Config{connections: n, ramp_up_s: ramp_s}, elapsed_ms) do
    ramp_ms = ramp_s * 1000
    if ramp_ms <= 0, do: n, else: min(n, ceil(n * elapsed_ms / ramp_ms))
  end

  defp start_clients(state, count) when count <= 0, do: state

  defp start_clients(%{config: config, stats: stats, supervisor: sup} = state, count) do
    started =
      Enum.reduce(state.started..(state.started + count - 1)//1, state.started, fn index, acc ->
        settings = client_settings(config, index)
        {:ok, _pid} = DynamicSupervisor.start_child(sup, {Client, {stats, settings}})
        acc + 1
      end)

    %{state | started: started}
  end

  defp client_settings(config, index) do
    %{
      host: config.host,
      port: config.port,
      path: Config.request_path(config),
      source_ip: Config.source_ip(config, index),
      connect_timeout_ms: config.connect_timeout_ms,
      message_interval_ms: config.message_interval_ms,
      connection_duration_ms:
        config.connection_duration_s && round(config.connection_duration_s * 1000)
    }
  end

  ## Sampling

  defp maybe_sample(%{next_sample_at: next} = state, now) when now < next, do: state

  defp maybe_sample(state, now) do
    %{config: config, stats: stats} = state
    index = state.sample_index
    mem_available = SystemInfo.mem_available_bytes()

    sample = %{
      t_ms: now - state.t0,
      phase: state.phase,
      client: Map.put(Stats.snapshot(stats), :started, state.started),
      loadgen: SystemInfo.loadgen_stats(),
      host_mem_available_bytes: mem_available,
      server: nil
    }

    state = %{
      state
      | samples: Map.put(state.samples, index, sample),
        sample_index: index + 1,
        next_sample_at: now + config.sample_interval_ms
    }

    print_progress(state, sample, state.last_server)

    state
    |> request_server_sample(index)
    |> check_memory(mem_available)
  end

  # Server metrics are fetched in a separate process so a slow /metrics
  # response never stalls the ramp-up schedule. At most one request is in
  # flight; if the server is too slow to answer, samples simply lack server
  # data rather than piling up requests.
  defp request_server_sample(%{config: %{server_metrics: false}} = state, _index), do: state
  defp request_server_sample(%{server_request: pid} = state, _index) when is_pid(pid), do: state

  defp request_server_sample(%{config: config} = state, index) do
    parent = self()

    pid =
      spawn_link(fn ->
        send(parent, {:server_sample, self(), index, fetch_server(config)})
      end)

    %{state | server_request: pid}
  end

  defp check_memory(%{abort_reason: nil, config: config} = state, available)
       when is_integer(available) do
    if available < config.min_free_mb * 1024 * 1024 do
      log_phase(
        state,
        "SAFETY STOP: MemAvailable #{div(available, 1024 * 1024)}MB < --min-free-mb " <>
          "#{config.min_free_mb}MB; stopping ramp-up and tearing down"
      )

      %{state | phase: :done, abort_reason: "low_memory"}
    else
      state
    end
  end

  defp check_memory(state, _available), do: state

  defp wait(state) do
    receive do
      {:server_sample, pid, index, server} when pid == state.server_request ->
        samples = Map.update!(state.samples, index, &%{&1 | server: server})
        %{state | samples: samples, server_request: nil, last_server: server}
    after
      @tick_ms -> state
    end
  end

  ## Teardown

  defp teardown(%{supervisor: sup} = state) do
    started = now_ms()

    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
      Client.close(pid)
    end

    remaining = await_clients(sup, started + @teardown_timeout_ms)

    forced =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
        DynamicSupervisor.terminate_child(sup, pid)
      end
      |> length()

    if remaining > 0 do
      log_phase(state, "teardown timed out; force-stopped #{forced} clients")
    end

    {state, now_ms() - started, forced}
  end

  defp await_clients(sup, deadline) do
    active = DynamicSupervisor.count_children(sup).active

    cond do
      active == 0 ->
        0

      now_ms() >= deadline ->
        active

      true ->
        Process.sleep(100)
        await_clients(sup, deadline)
    end
  end

  ## Output

  # `server` is the most recent completed server sample (one interval old).
  defp print_progress(%{log: log, config: config}, sample, server) do
    c = sample.client
    s = server

    server =
      case s do
        %{counters: counters} when is_map(counters) ->
          " | server active #{counters["active_connections"]} procs #{s.process_count}" <>
            " mem #{mb(s.memory_total_bytes)} rss #{mb(s.rss_bytes)}"

        _ ->
          ""
      end

    log.(
      "[#{pad(Float.round(sample.t_ms / 1000, 1), 7)}s #{pad(sample.phase, 7)}] " <>
        "open #{c.open}/#{config.connections} failed #{c.failed} " <>
        "disconnected #{c.disconnected} msgs #{c.messages_sent}/#{c.messages_received}" <>
        server <>
        " | loadgen mem #{mb(sample.loadgen.memory_total_bytes)}" <>
        " | host free #{mb(sample.host_mem_available_bytes)}"
    )
  end

  defp log_phase(%{log: log, t0: t0}, message) do
    log.("[#{pad(Float.round((now_ms() - t0) / 1000, 1), 7)}s] #{message}")
  end

  defp mb(nil), do: "?"
  defp mb(bytes), do: "#{div(bytes, 1024 * 1024)}MB"

  defp pad(value, width), do: value |> to_string() |> String.pad_leading(width)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
