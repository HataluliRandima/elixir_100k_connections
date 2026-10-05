#!/usr/bin/env bash
# Runs one benchmark step against a server you have already started with
# ./scripts/start_server.sh, and saves the result under results/.
#
#   ./scripts/run_benchmark.sh 1000
#   ./scripts/run_benchmark.sh 25000 --yes          # skip the confirmation prompt
#   DURATION=120 ./scripts/run_benchmark.sh 10000
#   ./scripts/run_benchmark.sh 5000 -- --message-interval 5000   # extra load_test flags
#
# Environment overrides (defaults in brackets):
#   URL [ws://127.0.0.1:4000/socket/websocket]   target; must be loopback
#   RAMP_RATE [1000]          connections started per second
#   DURATION [60]             seconds to hold all connections open
#   MESSAGE_INTERVAL [30000]  ms between pings per client
#   SAMPLE_INTERVAL [2000]    ms between metric samples
#   SOURCE_IPS [auto]         comma-separated loopback source IPs
#   MIN_FREE_MB [512]         abort if host MemAvailable drops below this
#   LABEL [""]                free-form label stored in the result
#
# There is deliberately no "run everything" mode: every step is an explicit
# command with an explicit connection count.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

[[ $# -ge 1 ]] || usage
CONNECTIONS="$1"; shift
[[ "$CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || { echo "error: connection count must be a positive integer" >&2; usage; }

ASSUME_YES=0
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "error: unknown argument $1 (pass load_test flags after --)" >&2; usage ;;
  esac
done

URL="${URL:-ws://127.0.0.1:4000/socket/websocket}"
RAMP_RATE="${RAMP_RATE:-1000}"
DURATION="${DURATION:-60}"
MESSAGE_INTERVAL="${MESSAGE_INTERVAL:-30000}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-2000}"
MIN_FREE_MB="${MIN_FREE_MB:-512}"
LABEL="${LABEL:-}"

# --- Safety: target must be this machine -------------------------------------
HOST="$(echo "$URL" | sed -E 's#^ws://([^/:]+).*#\1#')"
case "$HOST" in
  127.*|localhost|"[::1]") ;;
  *) echo "error: refusing non-loopback target '$HOST'. This script only benchmarks localhost." >&2; exit 1 ;;
esac
METRICS_URL="$(echo "$URL" | sed -E 's#^ws://([^/]+).*#http://\1/metrics#')"

if ! curl -sf -o /dev/null --max-time 3 "$METRICS_URL"; then
  echo "error: no server answering at $METRICS_URL" >&2
  echo "       start it first in another terminal: ./scripts/start_server.sh" >&2
  exit 1
fi

# --- Derived settings ---------------------------------------------------------
RAMP_UP=$(( (CONNECTIONS + RAMP_RATE - 1) / RAMP_RATE ))
(( RAMP_UP < 5 )) && RAMP_UP=5

# One source IP can open at most (port range size) connections to one
# destination. Use one extra loopback address per 25k connections; on Linux
# all of 127.0.0.0/8 is routed to the loopback interface already.
if [[ -z "${SOURCE_IPS:-}" ]]; then
  if (( CONNECTIONS > 25000 )); then
    COUNT=$(( (CONNECTIONS + 24999) / 25000 ))
    SOURCE_IPS="$(seq -s, -f '127.0.0.%g' 1 "$COUNT")"
  fi
fi

NOFILE="$(ulimit -n)"
if [[ "$NOFILE" != "unlimited" ]] && (( NOFILE < CONNECTIONS + 1000 )); then
  echo "error: open files limit is $NOFILE; need at least $((CONNECTIONS + 1000))." >&2
  echo "       see BENCHMARKING.md (System limits) for how to raise it safely." >&2
  exit 1
fi

# --- Confirmation for big runs ------------------------------------------------
cat <<INFO
==> benchmark step: $CONNECTIONS connections
    target:            $URL (loopback)
    ramp-up:           ${RAMP_UP}s (~${RAMP_RATE}/s)
    hold:              ${DURATION}s
    ping interval:     ${MESSAGE_INTERVAL}ms
    source IPs:        ${SOURCE_IPS:-kernel default}
    safety stop below: ${MIN_FREE_MB}MB MemAvailable
    host MemAvailable: $(awk '/MemAvailable/ {printf "%d MB", $2/1024}' /proc/meminfo)
INFO

if (( CONNECTIONS >= 25000 )) && (( ASSUME_YES == 0 )); then
  echo
  echo "WARNING: $CONNECTIONS connections will use significant memory and CPU on this machine"
  echo "         (client and server share it). Close other heavy programs first."
  read -r -p "Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || { echo "aborted"; exit 1; }
fi

# --- Run ----------------------------------------------------------------------
mkdir -p "$ROOT/results/runs"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_JSON="$ROOT/results/runs/${CONNECTIONS}-${STAMP}.json"
RUN_LOG="$ROOT/results/runs/${CONNECTIONS}-${STAMP}.log"

ARGS=(
  --connections "$CONNECTIONS"
  --url "$URL"
  --ramp-up "$RAMP_UP"
  --duration "$DURATION"
  --message-interval "$MESSAGE_INTERVAL"
  --sample-interval "$SAMPLE_INTERVAL"
  --min-free-mb "$MIN_FREE_MB"
  --output "$RUN_JSON"
  --csv "$ROOT/results/summary.csv"
)
[[ -n "${SOURCE_IPS:-}" ]] && ARGS+=(--source-ips "$SOURCE_IPS")
[[ -n "$LABEL" ]] && ARGS+=(--label "$LABEL")
ARGS+=("${EXTRA[@]}")

cd "$ROOT/load_generator"
mix deps.get >/dev/null
# Each simulated client is one BEAM process; raise the default 262k limit.
ERL_FLAGS="${ERL_FLAGS:-+P 2000000}" mix load_test "${ARGS[@]}" 2>&1 | tee "$RUN_LOG"

# The latest result for each step is kept at results/<N>.json for graphing;
# every run (with its console log) stays in results/runs/.
cp "$RUN_JSON" "$ROOT/results/${CONNECTIONS}.json"
echo "==> saved results/${CONNECTIONS}.json (history: ${RUN_JSON#$ROOT/})"
