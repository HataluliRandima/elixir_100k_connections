defmodule Elixir100kConnections.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Counters must exist before the endpoint accepts its first connection.
    :ok = Elixir100kConnections.Metrics.setup()

    children = [
      Elixir100kConnections.SchedulerMonitor,
      # Phoenix requires a PubSub server for channels, even though this
      # experiment never broadcasts.
      {Phoenix.PubSub, name: Elixir100kConnections.PubSub},
      Elixir100kConnectionsWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Elixir100kConnections.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Elixir100kConnectionsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
