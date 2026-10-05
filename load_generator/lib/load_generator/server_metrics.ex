defmodule LoadGenerator.ServerMetrics do
  @moduledoc """
  Fetches the server's `/metrics` JSON over plain HTTP using OTP's built-in
  `:httpc`, so the load generator needs no extra HTTP client dependency.
  """

  @timeout_ms 3_000

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(url), do: request(:get, url)

  @doc "Zeroes the server's cumulative counters before a run."
  @spec reset(String.t()) :: {:ok, map()} | {:error, term()}
  def reset(url), do: request(:post, url <> "/reset")

  defp request(method, url) do
    request =
      case method do
        :get -> {String.to_charlist(url), []}
        :post -> {String.to_charlist(url), [], ~c"application/json", "{}"}
      end

    http_opts = [timeout: @timeout_ms, connect_timeout: @timeout_ms]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> Jason.decode(body)
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Extracts the handful of fields worth keeping in every sample."
  def compact(metrics) do
    beam = metrics["beam"] || %{}
    memory = beam["memory"] || %{}

    %{
      counters: metrics["counters"],
      process_count: beam["process_count"],
      process_limit: beam["process_limit"],
      port_count: beam["port_count"],
      run_queue: beam["run_queue"],
      cpu_time_ms: beam["cpu_time_ms"],
      scheduler_utilization: get_in(beam, ["scheduler_utilization", "total"]),
      memory_total_bytes: memory["total"],
      memory_processes_bytes: memory["processes"],
      memory_binary_bytes: memory["binary"],
      rss_bytes: get_in(metrics, ["os", "rss_bytes"]),
      open_fds: get_in(metrics, ["os", "open_fds"]),
      host_tcp: get_in(metrics, ["host", "tcp"])
    }
  end
end
