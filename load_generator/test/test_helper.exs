# Integration tests need a running server (./scripts/start_server.sh) and are
# excluded by default. Run them with: mix test --include integration
ExUnit.start(exclude: [:integration])
