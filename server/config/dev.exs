import Config

# Loopback only: this server is for local experiments and must not be
# reachable from other machines.
config :elixir_100k_connections, Elixir100kConnectionsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "5KyMion6aj5cn2X0GxoB/dRZFnYLzVFom5ZGEf926Sz5mXBNNkdEc6axEzZ2HzDW",
  watchers: []

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
