import Config

if System.get_env("PHX_SERVER") do
  config :elixir_100k_connections, Elixir100kConnectionsWeb.Endpoint, server: true
end

config :elixir_100k_connections, Elixir100kConnectionsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # Nothing is signed or encrypted by this app (no sessions, no cookies), but
  # Phoenix still requires a secret. scripts/start_server.sh generates a
  # throwaway one per run so no secret is ever committed.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Start the server with scripts/start_server.sh, or generate one with: mix phx.gen.secret
      """

  # Bind to loopback by default. Set BIND_IP=0.0.0.0 only if you are running
  # the load generator on a second machine that you control.
  bind_ip =
    case :inet.parse_address(String.to_charlist(System.get_env("BIND_IP", "127.0.0.1"))) do
      {:ok, ip} -> ip
      {:error, _} -> raise "BIND_IP is not a valid IP address"
    end

  config :elixir_100k_connections, Elixir100kConnectionsWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST", "localhost"), port: 4000, scheme: "http"],
    http: [ip: bind_ip],
    secret_key_base: secret_key_base
end
