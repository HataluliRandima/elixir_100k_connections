# Benchmarking methodology

## What is being measured

The question is **how many idle-but-alive WebSocket connections one Phoenix
node can hold, and what each one costs**. "Alive" means: the TCP connection
is open, the WebSocket handshake completed, the client joined a Phoenix
channel, and the client keeps pinging and getting answers.

A connection only counts as *successfully connected* after all four steps
(TCP connect → HTTP 101 upgrade → `phx_join` → `ok` reply). Anything that
fails earlier is a *failed connection*, recorded with its reason.

### Client-side metrics (load generator)

| Metric | Meaning |
|---|---|
| `attempted` | clients that started connecting |
| `successfully_connected` | clients that completed the join |
| `failed_connections` | clients that never got there; `errors` has the reasons (`econnrefused`, `eaddrnotavail`, `http_status:403`, `upgrade_timeout`, …) |
| `peak_open_connections` | highest number of simultaneously joined clients (exact, tracked with an atomic, not sampled) |
| `open_at_end_of_hold` | joined clients right before teardown |
| `disconnected_unexpectedly` | joined clients whose connection dropped without being asked to close |
| `closed_cleanly` | clients that sent a close frame and saw the server close |
| `messages_sent` / `messages_received` | pings sent / replies received |
| `at_end_of_hold` | the same counters frozen right before teardown (see below) |
| `message_timeouts` | pings with no reply by the time the next ping was due |
| `connect_latency` | time from starting TCP connect to receiving the join reply |
| `message_rtt` | ping round-trip time measured with the client's monotonic clock |

Latencies are p50/p90/p99/p99.9/max from a log-bucketed histogram (buckets
5% wide, so percentiles over-estimate by at most 5%; `count`, `mean` and
`max` are exact).

**Why `at_end_of_hold` exists:** pings that are in flight when teardown
starts can lose their reply. The client sends its close frame and the server
transport shuts down before the channel's reply is written. In the first
10k run the server produced 21,691 replies and the client received 21,668;
the 23 missing ones were all in flight during teardown. Steady-state message
numbers should be read from `at_end_of_hold`.

### Server-side metrics (`GET /metrics`)

| Metric | Source | Notes |
|---|---|---|
| `active_connections` | `:counters` gauge | +1 on channel join, −1 in channel `terminate/2` |
| `sockets_accepted` / `socket_errors` | `LoadSocket.connect/3` | |
| `joins` / `join_errors` / `disconnects` | `ConnectionChannel` | |
| `messages_received` / `messages_sent` | `ConnectionChannel.handle_in/3` | "sent" = replies *produced*, which can exceed replies the client actually received (see above) |
| `process_count`, `port_count` | `:erlang.system_info/1` | every TCP socket is a port: an independent cross-check of connections |
| `memory.*` | `:erlang.memory/0` | BEAM's own allocator view |
| `scheduler_utilization` | `:scheduler.utilization/2`, 1s windows | the share of time schedulers do real work |
| `run_queue` | `:erlang.statistics(:total_run_queue_lengths)` | processes waiting for a scheduler |
| `cpu_time_ms` | `:erlang.statistics(:runtime)` | OS CPU time of the VM, **including scheduler busy-waiting** |
| `rss_bytes`, `open_fds` | `/proc/self/status`, `/proc/self/fd` | |
| `host.tcp` | `/proc/net/sockstat` | system-wide (client *and* server sockets) |
| `host.mem_available_bytes` | `/proc/meminfo` | |

**Per-connection cost** is `(value at end of hold − value at baseline) /
open connections`, reported for BEAM total memory, BEAM process memory,
RSS, processes and ports. RSS is the noisiest of these, because the
allocator keeps freed memory between runs, so use BEAM memory as the primary
figure. At small N (≤100), fixed costs such as lazy code loading dominate
and per-connection numbers mean little.

**CPU vs scheduler utilization.** By default an idle BEAM scheduler
*spins* for a short while before going to sleep, so it can react quickly to
new work. That spinning is real OS CPU time, but it isn't work. With many
connections each waking a scheduler occasionally, the spinning adds up:
in the 10k run the VM used ~112% of one core of OS CPU while schedulers
were busy only ~1.4% of the time (≈0.17 of a core). Re-running with
`+sbwt none` cut OS CPU to ~26% at the same latency. Use
`scheduler_utilization` to judge how loaded the BEAM is.

## Why concurrent connections ≠ requests per second

Requests/second measures **throughput**: how fast a server turns work
around. Concurrent connections measures **state**: how many long-lived
sessions it can keep at the same time, most of them idle.

The costs differ:

* An idle connection costs **memory** (process heap, socket buffers in the BEAM
  and in the kernel), a **file descriptor**, a **port** in the VM, and on the
  client side an **ephemeral port**. It costs almost no CPU.
* A server can handle 50k req/s with only a few hundred connections open, or
  hold 100k connections while handling only 3k messages/s. These are
  different limits, and different things break them.
* Connection **setup** is far more expensive than holding: in these runs the
  server used ~3.0–3.7 cores of OS CPU while establishing 1,000 connections/s,
  versus ~1.1 cores (mostly busy-waiting) while holding 10k connections.

That's why the tests ramp up at a controlled rate, then hold, and report
memory per connection as the headline number.

## Methodology

```
baseline ──► ramp-up ──► hold ──► teardown ──► report
```

1. **Baseline.** The load generator resets the server's cumulative counters
   (`POST /metrics/reset`) and records server metrics before any client exists.
   It also preloads its own modules so code loading isn't counted as
   per-connection memory.
2. **Ramp-up.** Clients are started at a steady rate (default 1,000/s, minimum
   5s ramp). Each client is a `:temporary` child of a `DynamicSupervisor` and
   connects inside `handle_continue/2`, so starting a client never blocks the
   ramp schedule.
3. **Hold** (default 60s). Every client pings every 30s, which is the Phoenix
   JavaScript client's default heartbeat. The **first ping is spread
   uniformly over one interval**; without that jitter, every client that
   joined in the same tick would ping in the same tick forever.
   Both sides are sampled every 2s; server metrics are fetched by a separate
   process so a slow `/metrics` response can't stall the runner.
4. **Teardown.** Every client sends a WebSocket close frame and waits for the
   server to close. After a short grace period the server is sampled again:
   `active_connections` must return to 0 (a leak check).
5. **Report.** `results/runs/<N>-<timestamp>.json` (full timeline),
   `results/<N>.json` (latest run for that step) and one row in
   `results/summary.csv`.

### Test progression

Every step is an explicit command. There is no "run everything" mode.

| Step | Command | Notes |
|---|---|---|
| 1,000 | `./scripts/run_benchmark.sh 1000` | ramp 5s |
| 5,000 | `./scripts/run_benchmark.sh 5000` | ramp 5s |
| 10,000 | `./scripts/run_benchmark.sh 10000` | ramp 10s |
| 25,000 | `./scripts/run_benchmark.sh 25000` | asks for confirmation; one source IP |
| 50,000 | `./scripts/run_benchmark.sh 50000` | asks for confirmation; source IPs 127.0.0.1–2 |
| 100,000 | `./scripts/run_benchmark.sh 100000` | asks for confirmation; source IPs 127.0.0.1–4 |

Useful variations:

```bash
DURATION=300 ./scripts/run_benchmark.sh 10000              # longer hold
MESSAGE_INTERVAL=1000 ./scripts/run_benchmark.sh 10000     # 10k msgs/s instead of ~333
RAMP_RATE=5000 ./scripts/run_benchmark.sh 10000            # stress connection setup
LABEL="sbwt-none" ./scripts/run_benchmark.sh 10000         # tag a variant
./scripts/run_benchmark.sh 5000 -- --connection-duration 20  # churn: clients leave after 20s
```

### Known limitations of this setup

* **Client and server on one machine.** They compete for CPU and, more
  importantly, RAM. Above 10k, the load generator's own memory is a
  significant part of the budget (~43 KB per client).
* **Loopback only.** No NIC, no real network latency, no packet loss. RTTs
  are a floor, not what users would see.
* **WSL2.** A VM with its own memory cap and kernel; results may differ on
  bare-metal Linux.
* **Single runs.** Each step has been run once (twice for 1k and 10k, with a
  change in between). Treat differences of a few percent as noise.
* **Tiny messages.** Pings and replies are under 200 bytes. Large payloads, broadcasts and
  Presence would change the picture (Part 2+).

## System limits

These are the limits that bound the experiment, measured with
`./scripts/system_limits.sh` on the machine described in
[DEVELOPMENT.md](DEVELOPMENT.md). **Nothing in this repository changes a system
setting.** Where a change might be needed, the command and its revert are
listed; apply them yourself only if a run shows the limit being hit.

| Limit | Current value | Why it matters | Needed for 100k? |
|---|---|---|---|
| open files (`ulimit -n`) | 1,048,576 soft and hard | each socket is a file descriptor, in both client and server | no change |
| `fs.nr_open` | 1,048,576 | per-process ceiling for `ulimit -n` | no change |
| `fs.file-max` | 9.2 × 10¹⁸ | system-wide fd ceiling | no change |
| BEAM process limit | **262,144** (default) | server uses **2 processes per connection** (measured), so the default caps it near 130k | raised per VM via `ERL_FLAGS="+P 2000000"` in the scripts |
| BEAM port limit | 1,048,576 | one port per socket | no change |
| ephemeral ports | `32768–60999` = **28,232 per source IP** | each client socket to `127.0.0.1:4000` needs a distinct local port | handled with multiple loopback source IPs (no sysctl change) |
| `net.core.somaxconn` | 4,096 | caps the accept backlog | not hit at 1,000 conn/s (`ListenOverflows` = 0) |
| `net.ipv4.tcp_max_syn_backlog` | 512 | half-open connection queue | not hit at 1,000 conn/s (`ListenDrops` = 0) |
| `net.ipv4.tcp_mem` | 92511 123349 185022 pages (≈361/482/723 MiB) | kernel TCP buffer memory: pressure starts at the middle value | idle sockets use little; watch `TCPMemoryPressures` |
| `nf_conntrack_max` | 262,144 | connection tracking table | `nf_conntrack_count` stays 0 on loopback here |
| RAM | 7.6 GiB total, ~1.6–2.3 GiB available | **the first real limit on this machine** | see below |
| `vm.overcommit_memory` | 1 (always overcommit) | the kernel never refuses an allocation up front; memory trouble shows up later as OOM | leave as is; the load generator's memory guard covers this |

### The BEAM process limit (`+P`)

* **Current:** 262,144 processes per VM.
* **Why it matters:** the server needs 2 processes per connection (the Bandit
  WebSocket handler and the channel), and the load generator needs 1 per
  client. 100k connections = 200k server processes plus the baseline (~470).
* **Change:** a VM flag, not a system setting. Both scripts set
  `ERL_FLAGS="+P 2000000"` (the VM rounds it up to 2,097,152). The process
  table is sized at boot, so a larger limit has a small fixed memory cost even
  when unused.
* **Revert:** run without the flag: `ERL_FLAGS="" ./scripts/start_server.sh`.

### Ephemeral ports

* **Current:** `net.ipv4.ip_local_port_range = 32768 60999`, so 28,232 ports.
* **Why it matters:** a TCP connection is identified by (source IP, source port,
  destination IP, destination port). With one source IP and one destination,
  only the source port can vary. Beyond ~28k connections, `connect` fails with
  `eaddrnotavail`. The load generator warns before starting if the target
  exceeds capacity.
* **Chosen approach (no system change):** on Linux the whole `127.0.0.0/8`
  block is routed to the loopback interface, so the load generator can bind
  clients to `127.0.0.1`, `127.0.0.2`, … (`--source-ips`). `run_benchmark.sh`
  adds one address per 25k connections. Verified working with 127.0.0.2/3.
* **Alternative (system change, not applied):**
  ```bash
  sysctl net.ipv4.ip_local_port_range                       # record current value
  sudo sysctl -w net.ipv4.ip_local_port_range="15000 65000"  # 50,001 ports
  sudo sysctl -w net.ipv4.ip_local_port_range="32768 60999"  # revert
  ```
  Not persistent across reboots unless written to `/etc/sysctl.d/`.

### Accept backlog (only if a run shows drops)

Check after a high-ramp run: `nstat -az TcpExtListenOverflows TcpExtListenDrops`.
If they're non-zero:

```bash
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=4096   # revert: =512
sudo sysctl -w net.core.somaxconn=8192             # revert: =4096
```

Lowering `RAMP_RATE` is the zero-risk alternative.

### Memory (the real constraint here)

* **Current:** 7.6 GiB visible to WSL; during the runs only ~1.0–1.9 GiB was
  available because other programs were running. The lowest `MemAvailable`
  seen during a 10k run was 670 MB.
* **Why it matters:** measured cost is ~38 KB per connection on the server
  (BEAM) plus ~43 KB per client in the load generator, plus kernel socket
  memory on both sides.
* **Options, safest first:**
  1. Close other programs before large runs.
  2. Run the load generator on a second machine you control (`BIND_IP` on
     the server, `--allow-remote` on the client). This also makes the test
     more realistic.
  3. Give WSL more memory. In `%UserProfile%\.wslconfig` on Windows:
     ```ini
     [wsl2]
     memory=12GB
     ```
     then `wsl --shutdown` from PowerShell. **Revert:** delete the line (or the
     file) and run `wsl --shutdown` again.
* **Safety net:** the load generator stops ramping and tears down if
  `MemAvailable` drops below `--min-free-mb` (default 512 MB), and records the
  run as `"status": "aborted"`.

## How to reproduce

```bash
git clone <this repo> && cd elixir_100k_connections
(cd server && mix deps.get) && (cd load_generator && mix deps.get)
./scripts/system_limits.sh                  # record your limits

./scripts/start_server.sh                   # terminal 1
./scripts/watch_metrics.sh                  # terminal 2 (optional)
./scripts/run_benchmark.sh 1000             # terminal 3
./scripts/run_benchmark.sh 5000
./scripts/run_benchmark.sh 10000
```

Restarting the server between steps isn't required (counters are reset at
the start of each run), but it gives the cleanest baseline.

## Design decisions

* **Phoenix Channels over raw WebSockets.** Channels are what a Phoenix app
  would actually use, so their cost (one extra process per joined topic) is
  part of the answer. A raw `Phoenix.Socket.Transport` comparison is a Part 2
  candidate.
* **Bandit**, the Phoenix 1.8 default, with no tuning.
* **No socket `id`.** `LoadSocket.id/1` returns `nil`, so Phoenix doesn't
  subscribe every socket to its own PubSub topic.
* **Channel logging off** (`log_join: false, log_handle_in: false`).
* **`:counters` for metrics**, not a GenServer. 10k–100k processes updating a
  single process's state would make the instrumentation the bottleneck.
* **No `:persistent_term` writes at runtime.** Updating a persistent term
  makes the VM scan every process; the scheduler monitor keeps its state in
  a GenServer instead.
* **Mint in the load generator.** It's process-less: the connection is a data
  structure owned by the client process, so one client = one process.
* **Mint socket buffer shrunk to 16 KB.** Mint sets the BEAM-side receive
  buffer to `max(sndbuf, recbuf, buffer)`, which on Linux loopback is ~2.5 MB.
  The first 1k run showed the load generator reserving ~2.5 MiB per client
  (2.55 GiB of BEAM memory for 1,000 clients). With an explicit 16 KB buffer
  it's ~43 KB per client.
* **Loopback-only by default** at every layer (server bind, load generator
  target check, source IP check, script check).
