defmodule LoadGenerator.Config do
  @moduledoc """
  Command-line options for a load-test run, with validation.

  Safety rules enforced here:

    * `--connections` has no default: the target is always explicit.
    * The target host must be a loopback address unless `--allow-remote` is
      given, and even then it should be a machine you control.
    * Only plain `ws://` is supported, to keep TLS cost out of Part 1.
  """

  @switches [
    connections: :integer,
    url: :string,
    ramp_up: :float,
    duration: :float,
    message_interval: :integer,
    message_rate: :float,
    connection_duration: :float,
    source_ips: :string,
    metrics_url: :string,
    server_metrics: :boolean,
    sample_interval: :integer,
    output: :string,
    csv: :string,
    min_free_mb: :integer,
    connect_timeout: :integer,
    allow_remote: :boolean,
    label: :string
  ]

  @max_connections 1_000_000
  # Phoenix's default WebSocket idle timeout. A client that is silent for
  # longer than this is disconnected by the server.
  @server_idle_timeout_ms 60_000

  defstruct connections: nil,
            url: "ws://127.0.0.1:4000/socket/websocket",
            host: nil,
            port: nil,
            path: nil,
            query: nil,
            ramp_up_s: 10.0,
            duration_s: 60.0,
            message_interval_ms: 30_000,
            message_rate: nil,
            connection_duration_s: nil,
            source_ips: [],
            metrics_url: nil,
            server_metrics: true,
            sample_interval_ms: 2_000,
            output: nil,
            csv: nil,
            min_free_mb: 512,
            connect_timeout_ms: 10_000,
            allow_remote: false,
            label: nil

  @type t :: %__MODULE__{}

  @doc """
  Parses and validates argv.

  Returns `{:ok, config, warnings}` or `{:error, message}`.
  """
  @spec parse([String.t()]) :: {:ok, t(), [String.t()]} | {:error, String.t()}
  def parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> build(opts)
      {_opts, extra, []} -> {:error, "unexpected arguments: #{Enum.join(extra, " ")}"}
      {_opts, _extra, invalid} -> {:error, "invalid options: #{format_invalid(invalid)}"}
    end
  end

  defp build(opts) do
    defaults = %__MODULE__{}

    config = %__MODULE__{
      defaults
      | connections: opts[:connections],
        url: Keyword.get(opts, :url, defaults.url),
        ramp_up_s: Keyword.get(opts, :ramp_up, defaults.ramp_up_s),
        duration_s: Keyword.get(opts, :duration, defaults.duration_s),
        message_interval_ms: Keyword.get(opts, :message_interval, defaults.message_interval_ms),
        message_rate: opts[:message_rate],
        connection_duration_s: opts[:connection_duration],
        metrics_url: opts[:metrics_url],
        server_metrics: Keyword.get(opts, :server_metrics, true),
        sample_interval_ms: Keyword.get(opts, :sample_interval, defaults.sample_interval_ms),
        output: opts[:output],
        csv: opts[:csv],
        min_free_mb: Keyword.get(opts, :min_free_mb, defaults.min_free_mb),
        connect_timeout_ms: Keyword.get(opts, :connect_timeout, defaults.connect_timeout_ms),
        allow_remote: Keyword.get(opts, :allow_remote, false),
        label: opts[:label]
    }

    with :ok <- validate_connections(config.connections),
         {:ok, config} <- parse_url(config),
         :ok <- validate_target(config),
         {:ok, config} <- parse_source_ips(config, opts[:source_ips]),
         :ok <- validate_source_ips(config),
         :ok <- validate_timing(config) do
      config = config |> apply_message_rate() |> default_metrics_url()
      {:ok, config, warnings(config)}
    end
  end

  defp validate_connections(nil),
    do: {:error, "--connections is required (the target is always explicit)"}

  defp validate_connections(n) when n < 1, do: {:error, "--connections must be at least 1"}

  defp validate_connections(n) when n > @max_connections,
    do: {:error, "--connections is capped at #{@max_connections}"}

  defp validate_connections(_n), do: :ok

  defp parse_url(config) do
    case URI.parse(config.url) do
      %URI{scheme: "ws", host: host, port: port, path: path, query: query}
      when is_binary(host) and host != "" ->
        {:ok, %{config | host: host, port: port || 80, path: path || "/", query: query}}

      %URI{scheme: "wss"} ->
        {:error, "wss:// is not supported in Part 1; use ws:// against a local server"}

      _ ->
        {:error, "--url must look like ws://127.0.0.1:4000/socket/websocket"}
    end
  end

  defp validate_target(%{allow_remote: true}), do: :ok

  defp validate_target(%{host: host}) do
    if loopback_host?(host) do
      :ok
    else
      {:error,
       "refusing to load-test #{host}: only loopback targets are allowed by default. " <>
         "Pass --allow-remote only for a server you own and control."}
    end
  end

  @doc "True if `host` resolves only to loopback addresses."
  def loopback_host?(host) do
    charhost = String.to_charlist(host)

    addresses =
      for family <- [:inet, :inet6],
          {:ok, addrs} <- [:inet.getaddrs(charhost, family)],
          addr <- addrs,
          do: addr

    addresses != [] and Enum.all?(addresses, &loopback_address?/1)
  end

  def loopback_address?({127, _, _, _}), do: true
  def loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback_address?(_), do: false

  defp parse_source_ips(config, nil), do: {:ok, config}

  defp parse_source_ips(config, value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn ip, {:ok, acc} ->
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, addr} -> {:cont, {:ok, [addr | acc]}}
        {:error, _} -> {:halt, {:error, "invalid --source-ips entry: #{ip}"}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "--source-ips is empty"}
      {:ok, ips} -> {:ok, %{config | source_ips: Enum.reverse(ips)}}
      error -> error
    end
  end

  # Binding to a non-loopback source address would send the traffic out of a
  # real interface, which is never what a local experiment wants.
  defp validate_source_ips(%{allow_remote: true}), do: :ok

  defp validate_source_ips(%{source_ips: ips}) do
    case Enum.reject(ips, &loopback_address?/1) do
      [] ->
        :ok

      bad ->
        {:error,
         "--source-ips must be loopback addresses, got: #{Enum.map_join(bad, ", ", &to_string(:inet.ntoa(&1)))}"}
    end
  end

  defp validate_timing(config) do
    cond do
      config.ramp_up_s < 0 ->
        {:error, "--ramp-up must be >= 0 seconds"}

      config.duration_s < 0 ->
        {:error, "--duration must be >= 0 seconds"}

      config.message_interval_ms < 0 ->
        {:error, "--message-interval must be >= 0 ms (0 disables pings)"}

      config.message_rate != nil and config.message_rate <= 0 ->
        {:error, "--message-rate must be > 0"}

      config.sample_interval_ms < 100 ->
        {:error, "--sample-interval must be >= 100 ms"}

      config.connection_duration_s != nil and config.connection_duration_s <= 0 ->
        {:error, "--connection-duration must be > 0 seconds"}

      true ->
        :ok
    end
  end

  # --message-rate is the total pings/second across all clients; it is turned
  # into the per-client interval that produces that rate once fully ramped.
  defp apply_message_rate(%{message_rate: nil} = config), do: config

  defp apply_message_rate(%{message_rate: rate, connections: n} = config) do
    %{config | message_interval_ms: max(1, round(n / rate * 1000))}
  end

  defp default_metrics_url(%{metrics_url: nil, host: host, port: port} = config) do
    %{config | metrics_url: "http://#{host}:#{port}/metrics"}
  end

  defp default_metrics_url(config), do: config

  defp warnings(config) do
    [
      idle_timeout_warning(config),
      ephemeral_port_warning(config)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp idle_timeout_warning(%{message_interval_ms: interval}) do
    cond do
      interval == 0 ->
        "pings are disabled; the server closes idle WebSockets after " <>
          "#{div(@server_idle_timeout_ms, 1000)}s, so runs longer than that will see disconnects"

      interval >= @server_idle_timeout_ms ->
        "--message-interval #{interval}ms is not below the server idle timeout " <>
          "(#{@server_idle_timeout_ms}ms); expect disconnects"

      true ->
        nil
    end
  end

  # Each TCP connection from one source IP to one destination ip:port needs a
  # distinct ephemeral port. On loopback, client and server share the same
  # machine, so the local port range is a hard ceiling per source IP.
  defp ephemeral_port_warning(config) do
    with {:ok, {low, high}} <- local_port_range() do
      per_source = high - low + 1
      sources = max(length(config.source_ips), 1)
      capacity = per_source * sources

      if config.connections > capacity do
        "#{config.connections} connections exceed the ephemeral port capacity of " <>
          "#{capacity} (#{per_source} ports x #{sources} source IP(s)); expect eaddrnotavail. " <>
          "Add more loopback source IPs with --source-ips 127.0.0.1,127.0.0.2,..."
      end
    else
      _ -> nil
    end
  end

  @doc "Reads the kernel's ephemeral port range on Linux."
  def local_port_range(path \\ "/proc/sys/net/ipv4/ip_local_port_range") do
    with {:ok, contents} <- File.read(path),
         [low, high] <- String.split(contents),
         {low, ""} <- Integer.parse(low),
         {high, ""} <- Integer.parse(high) do
      {:ok, {low, high}}
    else
      _ -> :error
    end
  end

  @doc "Source IP for the client with the given index (round-robin)."
  def source_ip(%__MODULE__{source_ips: []}, _index), do: nil

  def source_ip(%__MODULE__{source_ips: ips}, index),
    do: Enum.at(ips, rem(index, length(ips)))

  @doc "The request path, with any query from --url plus the serializer version."
  def request_path(%__MODULE__{path: path, query: query}) do
    vsn = LoadGenerator.Protocol.vsn_query()
    if query in [nil, ""], do: path <> "?" <> vsn, else: path <> "?" <> query <> "&" <> vsn
  end

  @doc "A JSON-friendly view of the configuration for result files."
  def to_map(%__MODULE__{} = config) do
    %{
      label: config.label,
      url: config.url,
      connections: config.connections,
      ramp_up_s: config.ramp_up_s,
      duration_s: config.duration_s,
      message_interval_ms: config.message_interval_ms,
      message_rate: config.message_rate,
      connection_duration_s: config.connection_duration_s,
      source_ips: Enum.map(config.source_ips, &(&1 |> :inet.ntoa() |> to_string())),
      server_metrics: config.server_metrics,
      sample_interval_ms: config.sample_interval_ms,
      min_free_mb: config.min_free_mb,
      connect_timeout_ms: config.connect_timeout_ms
    }
  end

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn
      {name, nil} -> name
      {name, value} -> "#{name}=#{value}"
    end)
  end
end
