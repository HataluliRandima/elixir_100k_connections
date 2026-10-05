defmodule LoadGenerator.Stats do
  @moduledoc """
  Shared, lock-free statistics for one load-test run.

  Every client process writes to the same `:counters` array and histograms
  directly. Failure reasons go into an ETS table with `update_counter/4`,
  because the set of reasons isn't known in advance (`:econnrefused`,
  `:eaddrnotavail`, `{:http_status, 503}`, ...).

  Counter meanings:

    * `attempted`  - clients that started connecting
    * `connected`  - clients that completed TCP + WebSocket upgrade + channel join
    * `failed`     - clients that never reached `connected`
    * `open`       - gauge: currently joined clients
    * `disconnected` - joined clients that lost the connection unexpectedly
    * `closed`     - joined clients that closed cleanly on request
    * `messages_sent` / `messages_received` - pings out, replies in
    * `message_timeouts` - pings with no reply before the next ping was due
  """

  @counters [
    :attempted,
    :connected,
    :failed,
    :open,
    :disconnected,
    :closed,
    :messages_sent,
    :messages_received,
    :message_timeouts
  ]

  @indexes @counters |> Enum.with_index(1) |> Map.new()

  alias LoadGenerator.Histogram

  @enforce_keys [:counters, :peak_open, :errors, :connect_latency, :message_rtt]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new do
    %__MODULE__{
      counters: :counters.new(length(@counters), [:write_concurrency]),
      peak_open: :atomics.new(1, signed: true),
      errors: :ets.new(:load_generator_errors, [:set, :public, write_concurrency: true]),
      connect_latency: Histogram.new(),
      message_rtt: Histogram.new()
    }
  end

  def increment(%__MODULE__{counters: ref}, name), do: :counters.add(ref, index(name), 1)

  def get(%__MODULE__{counters: ref}, name), do: :counters.get(ref, index(name))

  @doc "Marks a client as joined and tracks the peak number of open clients."
  def client_opened(%__MODULE__{counters: ref, peak_open: peak} = stats) do
    increment(stats, :connected)
    :counters.add(ref, index(:open), 1)
    open = :counters.get(ref, index(:open))
    raise_peak(peak, open, :atomics.get(peak, 1))
  end

  @doc "Marks a joined client as gone; `how` is `:closed` or `:disconnected`."
  def client_closed(%__MODULE__{counters: ref} = stats, how)
      when how in [:closed, :disconnected] do
    :counters.sub(ref, index(:open), 1)
    increment(stats, how)
  end

  @doc "Records why a client failed or disconnected."
  def record_error(%__MODULE__{errors: table}, reason) do
    :ets.update_counter(table, format_reason(reason), 1, {format_reason(reason), 0})
    :ok
  end

  def peak_open(%__MODULE__{peak_open: peak}), do: :atomics.get(peak, 1)

  def snapshot(%__MODULE__{counters: ref}) do
    Map.new(@indexes, fn {name, index} -> {name, :counters.get(ref, index)} end)
  end

  def errors(%__MODULE__{errors: table}), do: table |> :ets.tab2list() |> Map.new()

  @doc false
  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_reason({tag, detail}) when is_atom(tag), do: "#{tag}:#{format_detail(detail)}"
  def format_reason(reason), do: inspect(reason)

  defp format_detail(detail) when is_atom(detail) or is_integer(detail), do: to_string(detail)
  defp format_detail(detail) when is_binary(detail), do: detail
  defp format_detail(detail), do: inspect(detail)

  defp raise_peak(_peak, value, current) when value <= current, do: :ok

  defp raise_peak(peak, value, current) do
    case :atomics.compare_exchange(peak, 1, current, value) do
      :ok -> :ok
      newer -> raise_peak(peak, value, newer)
    end
  end

  defp index(name), do: Map.fetch!(@indexes, name)
end
