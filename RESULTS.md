# Results

Every number below comes from a result file in [`results/`](results/). Steps
that haven't been run are marked **not run** and have no numbers.
Environment: [DEVELOPMENT.md](DEVELOPMENT.md). Method and metric definitions:
[BENCHMARKING.md](BENCHMARKING.md).

All runs: server and load generator on the same WSL2 laptop, loopback,
default server flags except `+P 2000000`, 60s hold, one ping per client every
30s, ramp-up at up to 1,000 connections/s (5s minimum). KB = 1,024 bytes.

## Summary

| Step | Status | Connected | Failed | Disconnected | Ping RTT p50 / p99 | Server BEAM per conn | Server processes per conn | Load gen BEAM per conn | Result file |
|---:|---|---:|---:|---:|---|---:|---:|---:|---|
| 1,000 | ✅ completed | 1,000 / 1,000 | 0 | 0 | 1.30 / 2.84 ms | 36.8 KB | 2.0 | 42.8 KB | [`1000.json`](results/1000.json) |
| 5,000 | ✅ completed | 5,000 / 5,000 | 0 | 0 | 1.13 / 2.58 ms | 37.6 KB | 2.0 | 42.7 KB | [`5000.json`](results/5000.json) |
| 10,000 | ✅ completed | 10,000 / 10,000 | 0 | 0 | 1.24 / 5.11 ms | 37.9 KB | 2.0 | 43.5 KB | [`10000.json`](results/10000.json) |
| 25,000 | **not run** | – | – | – | – | – | – | – | – |
| 50,000 | **not run** | – | – | – | – | – | – | – | – |
| 100,000 | **not run** | – | – | – | – | – | – | – | – |

## Detail

| | 1,000 | 5,000 | 10,000 |
|---|---:|---:|---:|
| Run (UTC) | 2026-10-05 16:44 | 2026-10-05 16:45 | 2026-10-05 16:47 |
| Ramp-up | 5s (200/s) | 5s (1,000/s) | 10s (1,000/s) |
| Peak open connections | 1,000 | 5,000 | 10,000 |
| Closed cleanly at teardown | 1,000 | 5,000 | 10,000 |
| Connect latency p50 / p99 / max | 4.86 / 13.5 / 39.9 ms | 6.21 / 37.7 / 77.1 ms | 5.11 / 41.6 / 107.8 ms |
| Ping RTT p99.9 / max | 5.63 / 14.5 ms | 6.21 / 24.8 ms | 14.9 / 125.3 ms |
| Pings sent / replies received | 2,088 / 2,088 | 10,407 / 10,404 ¹ | 21,691 / 21,668 ¹ |
| Ping timeouts | 0 | 0 | 0 |
| Server BEAM memory at peak (baseline) | 126 MiB (90) | 274 MiB (91) | 470 MiB (100) |
| Server RSS at peak | 190 MiB | 373 MiB | 646 MiB |
| Server BEAM processes at peak | 2,467 | 10,467 | 20,467 |
| Server process heap per conn | 32.5 KB | 33.1 KB | 33.3 KB |
| Server OS CPU during hold (% of one core) ² | 15.5% | 58.7% | 112.2% |
| Server scheduler utilization during hold (avg) ² | 0.2% | 0.6% | 1.4% |
| Server `active_connections` after teardown | 0 | 0 | 0 |
| Teardown time | 110 ms | 271 ms | 578 ms |
| Lowest host `MemAvailable` during run | 1,300 MiB | 1,372 MiB | 1,000 MiB |

¹ The server produced a reply for every ping it received (`messages_sent`
equals the client's `messages_sent`). The few missing replies were in flight
when teardown started and were dropped as connections closed. Later runs
record `at_end_of_hold` counters to separate these out (see experiment B).

² OS CPU includes scheduler busy-waiting; scheduler utilization is real
work. See experiment B.

## Experiments

### A. Mint's socket buffer (load generator)

| | Before fix | After fix |
|---|---:|---:|
| Result file | [`runs/1000-20261005T164232Z.json`](results/runs/1000-20261005T164232Z.json) | [`runs/1000-20261005T164427Z.json`](results/runs/1000-20261005T164427Z.json) |
| Load generator BEAM memory at 1,000 clients | 2,615 MiB | 128 MiB |
| Load generator BEAM memory per client | 2,592 KB | 42.8 KB |
| Load generator RSS per client | 41.7 KB | 19.6 KB |

Mint sets each socket's BEAM-side buffer to `max(sndbuf, recbuf, buffer)`.
On this kernel a loopback socket reports `sndbuf` = 2,626,560 bytes, so every
client reserved ~2.5 MiB that it never touched (which is why RSS stayed low).
The fix is a single `:inet.setopts(socket, buffer: 16_384)` after connecting.
The server was unaffected.

### B. Scheduler busy-waiting (server)

Same 10,000-connection run, server restarted with
`+sbwt none +sbwtdcpu none +sbwtdio none`.

| | Default | `+sbwt none` |
|---|---:|---:|
| Result file | [`runs/10000-20261005T164704Z.json`](results/runs/10000-20261005T164704Z.json) | [`runs/10000-20261005T164956Z.json`](results/runs/10000-20261005T164956Z.json) |
| Server OS CPU during hold (% of one core) | 112.2% | 26.1% |
| Server scheduler utilization during hold (avg) | 1.4% | 1.6% |
| Server OS CPU during ramp-up (avg, % of one core) | 297% | 175% |
| Ping RTT p50 / p99 | 1.24 / 5.11 ms | 1.24 / 4.41 ms |
| Connect latency p50 / p99 | 5.11 / 41.6 ms | 5.91 / 67.8 ms |
| Pings sent / received at end of hold | not recorded | 21,674 / 21,674 |
| Teardown time | 578 ms | 1,420 ms |

The BEAM did about the same amount of real work in both runs; most of the
default run's OS CPU was schedulers spinning while waiting for work. Disabling
busy-waiting cut OS CPU by ~4× during the hold, with no change in median ping
latency. Connect p99 and teardown were slower in the `+sbwt none` run. With
one run each, that could be noise or the cost of waking sleeping schedulers;
it needs repeated runs before drawing a conclusion. `results/10000.json` is
the **default** run.

## What has *not* been shown yet

* Anything at or above 25,000 connections.
* Behaviour under sustained high message rates (only ~33–333 pings/s so far).
* Long holds (all holds were 60s).
* Repeatability (one run per configuration).

---

## Template for new results

Copy this block for each new run and fill it in **from the result file only**.

```markdown
### <N> connections — <YYYY-MM-DD>

- Result file: results/runs/<N>-<timestamp>.json
- Label / variant: <label or "default">
- Status: <completed | aborted (reason)>
- Command: ./scripts/run_benchmark.sh <N> [flags]
- Server flags: <ERL_FLAGS>

| Metric | Value |
|---|---:|
| Connected / target | |
| Failed (reasons) | |
| Disconnected unexpectedly | |
| Peak open connections | |
| Connect latency p50 / p99 / max | |
| Ping RTT p50 / p99 / max | |
| Pings sent / received at end of hold | |
| Server BEAM per connection | |
| Server processes per connection | |
| Server BEAM memory / RSS at peak | |
| Server OS CPU during hold / scheduler utilization | |
| Load generator BEAM per client | |
| Lowest host MemAvailable | |

Observations:
```
