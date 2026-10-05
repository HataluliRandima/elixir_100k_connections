defmodule LoadGenerator.SystemInfo do
  @moduledoc """
  Reads the local machine's environment and limits, so every result file
  records the conditions it was produced under.

  Everything is read-only, from `/proc` and the BEAM. On non-Linux systems
  the Linux-specific fields are `nil`.
  """

  @doc "Static facts about the machine, recorded once per run."
  def environment do
    %{
      elixir: System.version(),
      otp_release: to_string(:erlang.system_info(:otp_release)),
      erts: to_string(:erlang.system_info(:version)),
      os: os_name(),
      kernel: read_trimmed("/proc/sys/kernel/osrelease"),
      cpu_model: cpu_model(),
      logical_cpus: :erlang.system_info(:logical_processors_available),
      mem_total_bytes: meminfo()["MemTotal"],
      limits: limits()
    }
  end

  @doc "Kernel and process limits that bound how many connections are possible."
  def limits do
    %{
      open_files_soft: open_files_limit(),
      fs_nr_open: read_int("/proc/sys/fs/nr_open"),
      ip_local_port_range: read_trimmed("/proc/sys/net/ipv4/ip_local_port_range"),
      somaxconn: read_int("/proc/sys/net/core/somaxconn"),
      tcp_max_syn_backlog: read_int("/proc/sys/net/ipv4/tcp_max_syn_backlog"),
      loadgen_process_limit: :erlang.system_info(:process_limit),
      loadgen_port_limit: :erlang.system_info(:port_limit)
    }
  end

  @doc "Dynamic statistics for the load generator's own VM."
  def loadgen_stats do
    %{
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      memory_total_bytes: :erlang.memory(:total),
      memory_processes_bytes: :erlang.memory(:processes),
      rss_bytes: status_bytes("VmRSS")
    }
  end

  @doc "MemAvailable in bytes, or nil if unknown."
  def mem_available_bytes, do: meminfo()["MemAvailable"]

  @doc "Parses /proc/meminfo into a map of byte values."
  def meminfo(path \\ "/proc/meminfo") do
    case File.read(path) do
      {:ok, contents} ->
        for line <- String.split(contents, "\n"),
            [key, rest] <- [String.split(line, ":", parts: 2)],
            {kb, _} <- [Integer.parse(String.trim(rest))],
            into: %{},
            do: {key, kb * 1024}

      _ ->
        %{}
    end
  end

  @doc "Parses the soft 'Max open files' limit out of /proc/self/limits."
  def open_files_limit(path \\ "/proc/self/limits") do
    with {:ok, contents} <- File.read(path),
         "Max open files" <> rest <-
           contents
           |> String.split("\n")
           |> Enum.find("", &String.starts_with?(&1, "Max open files")),
         [soft | _] <- String.split(rest),
         {value, ""} <- Integer.parse(soft) do
      value
    else
      _ -> nil
    end
  end

  defp status_bytes(key) do
    with {:ok, contents} <- File.read("/proc/self/status"),
         line when is_binary(line) <-
           contents |> String.split("\n") |> Enum.find(&String.starts_with?(&1, key <> ":")),
         [_, value | _] <- String.split(line),
         {kb, ""} <- Integer.parse(value) do
      kb * 1024
    else
      _ -> nil
    end
  end

  defp os_name do
    with {:ok, contents} <- File.read("/etc/os-release"),
         "PRETTY_NAME=" <> name <-
           contents
           |> String.split("\n")
           |> Enum.find("", &String.starts_with?(&1, "PRETTY_NAME=")) do
      String.trim(name, "\"")
    else
      _ ->
        {family, name} = :os.type()
        "#{family}/#{name}"
    end
  end

  defp cpu_model do
    with {:ok, contents} <- File.read("/proc/cpuinfo"),
         "model name" <> rest <-
           contents
           |> String.split("\n")
           |> Enum.find("", &String.starts_with?(&1, "model name")) do
      rest |> String.split(":", parts: 2) |> List.last() |> String.trim()
    else
      _ -> nil
    end
  end

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> String.split() |> Enum.join(" ")
      _ -> nil
    end
  end

  defp read_int(path) do
    with value when is_binary(value) <- read_trimmed(path),
         {int, ""} <- Integer.parse(value) do
      int
    else
      _ -> nil
    end
  end
end
