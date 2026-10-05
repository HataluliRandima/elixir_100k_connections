import Config

config :elixir_100k_connections, Elixir100kConnectionsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Elixir100kConnectionsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Elixir100kConnections.PubSub

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
