defmodule Elixir100kConnectionsWeb.Router do
  use Elixir100kConnectionsWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Elixir100kConnectionsWeb do
    pipe_through :api

    get "/metrics", MetricsController, :show
    post "/metrics/reset", MetricsController, :reset
  end
end
