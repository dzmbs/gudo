# Shared setup for the stress scripts. Source it with S=<scenario name> and BIN=<dir with
# release unnamed-hostd and un>. It starts a daemon in a temp state dir with --no-relay under
# ulimits and an RSS watchdog, pairs `un`, and defines U (un), sample and cleanup.
set -u
BIN=${BIN:?set BIN to the directory with release unnamed-hostd and un}
OUT=${STRESS_OUT:-${TMPDIR:-/tmp}/unnamed-stress}
ROOT=$OUT/run-$S
rm -rf "$ROOT"; mkdir -p "$ROOT/state" "$ROOT/cfg"
export XDG_CONFIG_HOME=$ROOT/cfg UN_LOG=${UN_LOG:-warn}

start_daemon() {
  (
    ulimit -H -n "${DAEMON_NOFILE:-8192}"
    ulimit -S -n "${DAEMON_NOFILE_SOFT:-${DAEMON_NOFILE:-8192}}"
    ulimit -u "${DAEMON_NPROC:-4000}"
    exec "$BIN/unnamed-hostd" --state-dir "$ROOT/state" run --no-relay --bind 127.0.0.1:0 \
      --shell "${SHELL_BIN:-/bin/sh}" ${DAEMON_ARGS:-}
  ) 2>>"$ROOT/daemon.log" &
  DPID=$!
  # Kill the daemon past MAXRSS_MB so a runaway can never take the machine down.
  (
    while kill -0 $DPID 2>/dev/null; do
      r=$(ps -o rss= -p $DPID 2>/dev/null || echo 0)
      if [ "${r:-0}" -gt $((${MAXRSS_MB:-4000} * 1024)) ]; then
        echo "WATCHDOG killed daemon at rss_kb=$r" >>"$ROOT/watchdog.log"
        kill -9 $DPID
      fi
      sleep 0.5
    done
  ) &
  WPID=$!
}

U() { "$BIN/un" --no-relay "$@"; }

pair() {
  local ticket
  ticket=$("$BIN/unnamed-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
  U pair "$ticket" >/dev/null
  echo "$ticket" >"$ROOT/ticket"
}

# Peak tracking across samples.
PEAK_RSS=0
sample() {
  local rss cpu fds th kids
  rss=$(ps -o rss= -p $DPID 2>/dev/null | tr -d ' ')
  cpu=$(ps -o %cpu= -p $DPID 2>/dev/null | tr -d ' ')
  fds=$(lsof -p $DPID 2>/dev/null | wc -l | tr -d ' ')
  th=$(ps -M -p $DPID 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  kids=$(pgrep -P $DPID 2>/dev/null | wc -l | tr -d ' ')
  [ "${rss:-0}" -gt "$PEAK_RSS" ] && PEAK_RSS=${rss:-0}
  printf "%-40s rss_mb=%-6s cpu=%-6s fds=%-6s threads=%-6s children=%s\n" "$1" \
    $((${rss:-0} / 1024)) "${cpu:-DEAD}" "$fds" "$th" "$kids"
}

alive() { kill -0 $DPID 2>/dev/null; }

cleanup() {
  kill $DPID 2>/dev/null
  sleep 1
  kill -9 $DPID 2>/dev/null
  kill $WPID 2>/dev/null
  [ -n "${KEEP:-}" ] || rm -rf "$ROOT"
}
