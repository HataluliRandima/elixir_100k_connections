defmodule LoadGenerator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Every simulated client is a :temporary child here, so a client that
      # fails is counted, not restarted.
      {DynamicSupervisor, name: LoadGenerator.ClientSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LoadGenerator.Supervisor)
  end
end
