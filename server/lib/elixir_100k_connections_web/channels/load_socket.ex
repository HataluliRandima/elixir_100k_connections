defmodule Elixir100kConnectionsWeb.LoadSocket do
  @moduledoc """
  The WebSocket entry point for load-test clients.

  There is no authentication on purpose: the experiment measures how many
  persistent connections the BEAM can hold, not how fast tokens verify. Each
  socket gets a server-assigned client id that is unique for the lifetime of
  the node.
  """

  use Phoenix.Socket

  alias Elixir100kConnections.Metrics

  channel "connections:*", Elixir100kConnectionsWeb.ConnectionChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case params do
      # A client can ask to be rejected so the error path is testable end to end.
      %{"reject" => "true"} ->
        Metrics.socket_rejected()
        :error

      _ ->
        Metrics.socket_accepted()
        {:ok, assign(socket, :client_id, System.unique_integer([:positive, :monotonic]))}
    end
  end

  # Returning nil means no per-socket PubSub topic is created. Naming sockets
  # is useful for force-disconnecting users, but would add one PubSub
  # subscription per connection, which this experiment does not need.
  @impl true
  def id(_socket), do: nil
end
