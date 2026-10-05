import Config

# "prod" here means "the build we benchmark": no code reloader, no debug
# logging, compiled plugs. It is not a deployment configuration, so there is
# no force_ssl; the benchmark talks plain ws:// over loopback.
config :logger, level: :info
