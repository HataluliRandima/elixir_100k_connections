defmodule Elixir100kConnectionsWeb.MetricsController do
  @moduledoc """
  JSON metrics for the load generator and for humans with `curl`.

      GET  /metrics        connection counters + BEAM/OS/host statistics
      POST /metrics/reset  zero the cumulative counters between runs
  """

  use Elixir100kConnectionsWeb, :controller

  alias Elixir100kConnections.{Metrics, RuntimeStats}

  def show(conn, _params) do
    json(
      conn,
      Map.merge(
        %{timestamp: DateTime.utc_now(), counters: Metrics.snapshot()},
        RuntimeStats.snapshot()
      )
    )
  end

  def reset(conn, _params) do
    :ok = Metrics.reset()
    json(conn, %{ok: true, counters: Metrics.snapshot()})
  end
end
