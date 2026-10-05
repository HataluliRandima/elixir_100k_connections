defmodule Elixir100kConnections.RuntimeStats do
  @moduledoc """
  Point-in-time view of the BEAM and (on Linux) the host.

  Everything here is cheap to collect: `:erlang.system_info/1`,
  `:erlang.memory/0`, `:erlang.statistics/1`, and a few small files under
  `/proc`. Linux-only fields are `nil` on other platforms instead of failing.
  """

  alias Elixir100kConnections.SchedulerMonitor

  @spec snapshot() :: map()
  def snapshot do
    %{
      beam: beam(),
      os: os(),
      host: host()
    }
  end

  @doc "BEAM-level statistics."
  def beam do
    {runtime_ms, _} = :erlang.statistics(:runtime)
    {wall_ms, _} = :erlang.statistics(:wall_clock)

    %{
      otp_release: to_string(:erlang.system_info(:otp_release)),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      # Every open TCP socket is a port, so this is an independent check on
      # how many connections the VM really holds.
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers_online: :erlang.system_info(:dirty_cpu_schedulers_online),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      # CPU time summed over all VM threads; can exceed wall time.
      cpu_time_ms: runtime_ms,
      uptime_ms: wall_ms,
      memory: :erlang.memory() |> Map.new(),
      scheduler_utilization: SchedulerMonitor.latest()
    }
  end

  @doc "Statistics for this OS process."
  def os do
    status = read_proc_kv("/proc/self/status")

    %{
      pid: System.pid(),
      rss_bytes: kb_to_bytes(status["VmRSS"]),
      threads: parse_int(status["Threads"]),
      open_fds: count_fds()
    }
  end

  @doc "Host-wide memory and TCP socket statistics."
  def host do
    meminfo = read_proc_kv("/proc/meminfo")

    %{
      mem_total_bytes: kb_to_bytes(meminfo["MemTotal"]),
      mem_available_bytes: kb_to_bytes(meminfo["MemAvailable"]),
      tcp: tcp_sockstat()
    }
  end

  @doc """
  Parses the TCP line of `/proc/net/sockstat`, e.g.

      TCP: inuse 37 orphan 0 tw 0 alloc 81 mem 3

  `mem` is in pages and is the kernel memory used by TCP socket buffers.
  """
  def tcp_sockstat(path \\ "/proc/net/sockstat") do
    with {:ok, contents} <- File.read(path),
         "TCP: " <> rest <-
           contents |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "TCP: ")) do
      rest
      |> String.split()
      |> Enum.chunk_every(2)
      |> Map.new(fn [key, value] -> {key, String.to_integer(value)} end)
    else
      _ -> nil
    end
  end

  defp count_fds do
    case File.ls("/proc/self/fd") do
      {:ok, fds} -> length(fds)
      _ -> nil
    end
  end

  @doc false
  def read_proc_kv(path) do
    case File.read(path) do
      {:ok, contents} ->
        for line <- String.split(contents, "\n"),
            [key, value] <- [String.split(line, ":", parts: 2)],
            into: %{},
            do: {key, String.trim(value)}

      _ ->
        %{}
    end
  end

  defp kb_to_bytes(nil), do: nil
  defp kb_to_bytes(value), do: parse_int(value) * 1024

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    {int, _} = Integer.parse(value)
    int
  end
end
