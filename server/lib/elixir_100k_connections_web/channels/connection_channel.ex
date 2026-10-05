defmodule Elixir100kConnectionsWeb.ConnectionChannel do
  @moduledoc """
  One channel process per connected client.

  Protocol (Phoenix V2 JSON serializer):

    * join `connections:lobby` and get `%{"client_id" => id}` back
    * push `"ping"` with any payload and get the same payload back in the reply,
      plus the server's client id and a server timestamp. The client uses
      its own timestamp from the echoed payload to measure round-trip latency.

  Per-join and per-message logging is disabled: at 100k connections, logging
  each join would turn the Logger into the bottleneck.
  """

  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias Elixir100kConnections.Metrics

  @impl true
  def join("connections:lobby", _payload, socket) do
    Metrics.connection_joined()
    {:ok, %{client_id: socket.assigns.client_id}, socket}
  end

  def join(_topic, _payload, _socket) do
    Metrics.join_rejected()
    {:error, %{reason: "unknown topic"}}
  end

  @impl true
  def handle_in("ping", payload, socket) do
    Metrics.message_received()
    Metrics.message_sent()

    reply = %{
      echo: payload,
      client_id: socket.assigns.client_id,
      server_time_us: System.system_time(:microsecond)
    }

    {:reply, {:ok, reply}, socket}
  end

  def handle_in(_event, _payload, socket) do
    Metrics.message_received()
    Metrics.message_sent()
    {:reply, {:error, %{reason: "unknown event"}}, socket}
  end

  # Called when the client leaves ({:shutdown, :left}) or when the transport
  # process goes away ({:shutdown, :closed}), which covers clean closes,
  # dropped TCP connections and server-side idle timeouts.
  @impl true
  def terminate(_reason, _socket) do
    Metrics.connection_closed()
    :ok
  end
end
