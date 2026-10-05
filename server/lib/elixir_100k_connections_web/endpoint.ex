defmodule Elixir100kConnectionsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :elixir_100k_connections

  # The socket under test. Clients connect to /socket/websocket?vsn=2.0.0.
  #
  # `timeout` is the server-side idle timeout: a connection that sends nothing
  # for this long is closed. Load-test clients must ping more often than this.
  # It is set explicitly (it is also Phoenix's default) because it directly
  # constrains the benchmark's --message-interval.
  #
  # Long polling is disabled; it is a different transport with a different
  # cost model and would muddy the experiment.
  socket "/socket", Elixir100kConnectionsWeb.LoadSocket,
    websocket: [timeout: 60_000],
    longpoll: false

  plug Plug.RequestId
  plug Plug.Head
  plug Elixir100kConnectionsWeb.Router
end
