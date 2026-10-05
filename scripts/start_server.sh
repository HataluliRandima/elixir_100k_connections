#!/usr/bin/env bash
# Starts the experiment server in benchmark (prod) mode on 127.0.0.1.
#
#   ./scripts/start_server.sh            # port 4000
#   PORT=4100 ./scripts/start_server.sh
#
# Why prod mode: dev mode runs the code reloader and debug logging, both of
# which would distort connection measurements.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/server"

export MIX_ENV=prod
export PHX_SERVER=true
export PORT="${PORT:-4000}"
export BIND_IP="${BIND_IP:-127.0.0.1}"
# Nothing in this app is signed with it; a fresh throwaway value per run means
# no secret ever lives in the repository.
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(head -c 48 /dev/urandom | base64 | tr -d '\n')}"
# Each connection costs ~2 BEAM processes on the server (socket + channel), so
# the default limit of 262,144 processes would cap us near 130k connections.
export ERL_FLAGS="${ERL_FLAGS:-+P 2000000}"

if [[ "$BIND_IP" != 127.* ]]; then
  echo "WARNING: binding to $BIND_IP, not loopback. Only do this on a network you control." >&2
fi

echo "==> open files limit (ulimit -n): $(ulimit -n)"
echo "==> ERL_FLAGS: $ERL_FLAGS"

mix deps.get --only prod >/dev/null
mix compile

echo "==> starting server on http://$BIND_IP:$PORT (metrics: /metrics, socket: /socket/websocket)"
exec mix phx.server
