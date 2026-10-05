defmodule Elixir100kConnections do
  @moduledoc """
  A deliberately minimal Phoenix server for measuring how many concurrent
  WebSocket connections a single BEAM node can hold.

  See `Elixir100kConnectionsWeb.LoadSocket` and
  `Elixir100kConnectionsWeb.ConnectionChannel` for the connection path, and
  `Elixir100kConnections.Metrics` for the instrumentation.
  """
end
