#!/usr/bin/env bash
# Prints the OS and BEAM limits that matter for holding many TCP connections.
# Read-only: this script never changes a setting.
#
#   ./scripts/system_limits.sh
set -uo pipefail

kv() { printf "  %-34s %s\n" "$1" "$2"; }
sys() { sysctl -n "$1" 2>/dev/null | tr '\t' ' ' || echo "n/a"; }

echo "== Host"
kv "kernel" "$(uname -sr)"
kv "os" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
kv "cpu" "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
kv "logical cpus" "$(nproc)"
kv "MemTotal" "$(awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
kv "MemAvailable" "$(awk '/MemAvailable/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
kv "swap" "$(awk '/SwapTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
grep -qi microsoft /proc/version && kv "virtualization" "WSL2 (limits are those of the WSL VM)"

echo "== File descriptors (every socket is one fd)"
kv "ulimit -n (soft)" "$(ulimit -Sn)"
kv "ulimit -n (hard)" "$(ulimit -Hn)"
kv "fs.nr_open (per-process max)" "$(sys fs.nr_open)"
kv "fs.file-max (system-wide)" "$(sys fs.file-max)"
kv "fds in use system-wide" "$(awk '{print $1}' /proc/sys/fs/file-nr)"

echo "== TCP / network"
kv "net.ipv4.ip_local_port_range" "$(sys net.ipv4.ip_local_port_range)"
read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range
kv "  ephemeral ports per source IP" "$((hi - lo + 1))"
kv "net.core.somaxconn" "$(sys net.core.somaxconn)"
kv "net.ipv4.tcp_max_syn_backlog" "$(sys net.ipv4.tcp_max_syn_backlog)"
kv "net.ipv4.tcp_mem (pages)" "$(sys net.ipv4.tcp_mem)"
kv "net.ipv4.tcp_rmem (bytes)" "$(sys net.ipv4.tcp_rmem)"
kv "net.ipv4.tcp_wmem (bytes)" "$(sys net.ipv4.tcp_wmem)"
kv "net.ipv4.tcp_fin_timeout" "$(sys net.ipv4.tcp_fin_timeout)"
kv "net.ipv4.tcp_tw_reuse" "$(sys net.ipv4.tcp_tw_reuse)"
kv "net.netfilter.nf_conntrack_max" "$(sys net.netfilter.nf_conntrack_max)"
kv "current TCP sockets" "$(grep '^TCP:' /proc/net/sockstat)"

echo "== BEAM (defaults for a fresh VM, before any +P/+Q flags)"
erl -noshell -eval '
  F = fun(K) -> io:format("  ~-34s ~p~n", [K, erlang:system_info(K)]) end,
  lists:foreach(F, [otp_release, schedulers, schedulers_online, dirty_cpu_schedulers,
                    dirty_io_schedulers, process_limit, port_limit, kernel_poll]),
  halt().' 2>/dev/null || echo "  erl not found"
