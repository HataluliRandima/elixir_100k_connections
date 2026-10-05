defmodule Elixir100kConnections.Metrics do
  @moduledoc """
  Lock-free connection and message counters for the server.

  Every connection process updates these counters concurrently, so they are
  backed by a single `:counters` array (atomic, with `:write_concurrency`)
  whose reference lives in `:persistent_term`. Reading or updating a counter
  never sends a message and never goes through a single process, which keeps
  the instrumentation from becoming the bottleneck it is trying to measure.

  Counters are cumulative since boot (or since the last `reset/0`), except
  `:active_connections`, which is a gauge and is never reset.
  """

  @counters [
    :sockets_accepted,
    :socket_errors,
    :active_connections,
    :joins,
    :join_errors,
    :disconnects,
    :messages_received,
    :messages_sent
  ]

  @gauges [:active_connections]

  @indexes @counters |> Enum.with_index(1) |> Map.new()

  @key {__MODULE__, :counters}

  @type name ::
          :sockets_accepted
          | :socket_errors
          | :active_connections
          | :joins
          | :join_errors
          | :disconnects
          | :messages_received
          | :messages_sent

  @doc "Creates the counter array. Called once from the application supervisor."
  @spec setup() :: :ok
  def setup do
    :persistent_term.put(@key, :counters.new(length(@counters), [:write_concurrency]))
  end

  @doc "Returns the list of tracked counter names."
  @spec names() :: [name()]
  def names, do: @counters

  @spec increment(name(), integer()) :: :ok
  def increment(name, by \\ 1), do: :counters.add(ref(), Map.fetch!(@indexes, name), by)

  @spec decrement(name()) :: :ok
  def decrement(name), do: :counters.sub(ref(), Map.fetch!(@indexes, name), 1)

  @spec get(name()) :: integer()
  def get(name), do: :counters.get(ref(), Map.fetch!(@indexes, name))

  @doc "Returns all counters as a map."
  @spec snapshot() :: %{name() => integer()}
  def snapshot do
    ref = ref()
    Map.new(@indexes, fn {name, index} -> {name, :counters.get(ref, index)} end)
  end

  @doc """
  Resets cumulative counters to zero so consecutive benchmark runs can share
  one server. The active connection gauge is left alone because the
  connections it counts still exist.
  """
  @spec reset() :: :ok
  def reset do
    ref = ref()

    for {name, index} <- @indexes, name not in @gauges do
      :counters.put(ref, index, 0)
    end

    :ok
  end

  ## Connection lifecycle helpers used by the socket and channel

  def socket_accepted, do: increment(:sockets_accepted)
  def socket_rejected, do: increment(:socket_errors)
  def join_rejected, do: increment(:join_errors)

  def connection_joined do
    increment(:joins)
    increment(:active_connections)
  end

  def connection_closed do
    increment(:disconnects)
    decrement(:active_connections)
  end

  def message_received, do: increment(:messages_received)
  def message_sent, do: increment(:messages_sent)

  defp ref, do: :persistent_term.get(@key)
end
