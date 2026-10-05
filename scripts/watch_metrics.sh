#!/usr/bin/env bash
# Prints a compact line of server metrics every N seconds. Read-only.
#
#   ./scripts/watch_metrics.sh            # every 2s against 127.0.0.1:4000
#   INTERVAL=5 PORT=4100 ./scripts/watch_metrics.sh
set -euo pipefail

URL="http://127.0.0.1:${PORT:-4000}/metrics"
INTERVAL="${INTERVAL:-2}"

command -v jq >/dev/null || { echo "jq is required (sudo apt install jq)" >&2; exit 1; }

while true; do
  curl -sf --max-time 3 "$URL" | jq -r '
    "\(.timestamp[11:19])  active=\(.counters.active_connections)"
    + "  joins=\(.counters.joins) disconnects=\(.counters.disconnects)"
    + "  msgs_in=\(.counters.messages_received)"
    + "  procs=\(.beam.process_count) ports=\(.beam.port_count)"
    + "  beam_mem=\(.beam.memory.total / 1048576 | floor)MB rss=\(.os.rss_bytes / 1048576 | floor)MB"
    + "  sched=\((.beam.scheduler_utilization.total // 0) * 100 | . * 10 | round / 10)%"
    + "  runq=\(.beam.run_queue)  host_free=\(.host.mem_available_bytes / 1048576 | floor)MB"' \
    || echo "$(date +%T)  no response from $URL"
  sleep "$INTERVAL"
done
