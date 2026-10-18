#!/usr/bin/env bash
# Starts a local unnamed-hostd for app tests (relays off, fixed loopback port) and prints a
# pairing ticket. The simulator shares the Mac's network, so the iPad app can pair with it.
#
#   apple/scripts/local-daemon.sh start [state-dir]   # prints the ticket
#   apple/scripts/local-daemon.sh stop  [state-dir]
#
# UN_HOSTD_BIN overrides the daemon (default: target/debug/unnamed-hostd); PORT the UDP port.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bin="${UN_HOSTD_BIN:-$repo_root/target/debug/unnamed-hostd}"
state="${2:-${TMPDIR:-/tmp}/un-app-test-daemon}"
port="${PORT:-47011}"

case "${1:-start}" in
  start)
    mkdir -p "$state"
    if [[ -f "$state/pid" ]] && kill -0 "$(cat "$state/pid")" 2>/dev/null; then :; else
      "$bin" --state-dir "$state" run --no-relay --bind "127.0.0.1:$port" >"$state/log" 2>&1 &
      echo $! >"$state/pid"
    fi
    for _ in $(seq 1 150); do
      if out="$("$bin" --state-dir "$state" pair --json 2>/dev/null)" && [[ "$out" == *'"running":true'* ]]; then
        python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' <<<"$out"
        exit 0
      fi
      sleep 0.1
    done
    echo "daemon did not come up; log: $state/log" >&2
    exit 1
    ;;
  stop)
    [[ -f "$state/pid" ]] && kill "$(cat "$state/pid")" 2>/dev/null || true
    rm -f "$state/pid"
    ;;
esac
