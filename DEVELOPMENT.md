# Development environment

These are the conditions the Part 1 results were produced under, recorded
on 2026-10-05. Every result JSON also embeds its own `environment` block, so
a result file stays self-describing even if this page changes.

## Toolchain

| Component | Version | Notes |
|---|---|---|
| Elixir | 1.17.0 | compiled with OTP 25, running on OTP 26 (supported) |
| Erlang/OTP | 26.1.2 (ERTS 14.1.1) | JIT enabled, `kernel_poll: true` |
| Mix | 1.17.0 | |
| Phoenix | 1.8.15 | generated with `phx_new` 1.8.8 |
| Bandit | 1.12.5 | HTTP/WebSocket server (Phoenix 1.8 default) |
| Thousand Island | 1.5.0 | Bandit's socket acceptor layer |
| Mint | 1.11.0 | load generator HTTP client |
| Mint.WebSocket | 1.0.6 | load generator WebSocket client |
| Jason | 1.4.5 | JSON |
| Node.js | v23.0.0 installed, **not used** | the project has no assets |

Versions were installed through `asdf`. Nothing is installed system-wide by
this project.

## Operating system and hardware

| | |
|---|---|
| OS | Ubuntu 24.04.3 LTS under **WSL2** |
| Kernel | 6.6.87.2-microsoft-standard-WSL2 |
| CPU | 12th Gen Intel Core i5-1245U, 12 logical CPUs as seen by WSL |
| RAM visible to WSL | 7.6 GiB total, 2.0 GiB swap |
| RAM *available* before runs | ~1.6–2.3 GiB (other programs, including an editor and its Elixir language server, were running) |
| Disk | 1 TB virtual disk, 9% used |

Things to keep in mind about this machine:

* **It's a laptop CPU with a hybrid design.** The i5-1245U has 2 performance
  cores (with Hyper-Threading) and 8 efficiency cores, which comes to 12
  threads. Inside WSL `lscpu` reports it as "6 cores × 2 threads", so the
  BEAM's 12 schedulers don't know which ones land on slow cores.
* **WSL2 is a VM.** Limits (memory, file descriptors, sysctls) are the
  WSL VM's, not Windows'. The VM gets a share of the host's RAM, which you can
  configure in `%UserProfile%\.wslconfig` (see BENCHMARKING.md).
* **Client and server share the machine.** Both BEAM VMs compete for the same
  CPU and the same RAM, and traffic stays on loopback (no NIC, no real
  network latency).

## Setting up from scratch

```bash
# Elixir/Erlang via asdf (or use your distro / Homebrew / mise)
asdf plugin add erlang && asdf install erlang 26.1.2
asdf plugin add elixir && asdf install elixir 1.17.0-otp-26
mix local.hex --force

# Tools used by the scripts
sudo apt install -y curl jq

# Dependencies
(cd server && mix deps.get)
(cd load_generator && mix deps.get)
```

Phoenix itself is a dependency of `server/`; the `phx_new` archive is only
needed if you want to generate a new project.

## Day-to-day commands

```bash
# Server in dev mode (code reloading, debug logs). Not for benchmarks.
cd server && iex -S mix phx.server

# Server in benchmark mode (what the results use)
./scripts/start_server.sh

# Tests
(cd server && mix test)
(cd load_generator && mix test)
(cd load_generator && mix test --include integration)   # with a server running

# Formatting / warnings
(cd server && mix format && mix compile --warnings-as-errors)
(cd load_generator && mix format && mix compile --warnings-as-errors)
```

## Why "prod" mode for benchmarks

`scripts/start_server.sh` runs the server with `MIX_ENV=prod`:

* no code reloader (dev checks for changed files on every request),
* `:info` log level, and per-join / per-message channel logging turned off
  in `ConnectionChannel` (logging 100k joins would make Logger the bottleneck),
* a throwaway `SECRET_KEY_BASE` generated per start, so no secret is ever
  committed (the app doesn't sign anything, but Phoenix requires one),
* `ERL_FLAGS="+P 2000000"` to raise the BEAM process limit (see
  BENCHMARKING.md).

There is no `force_ssl` and no public bind: this is a benchmark build, not a
deployment.
