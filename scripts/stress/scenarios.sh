#!/bin/zsh
# Usage: scenarios.sh <bin_dir> <scenario>...
# <bin_dir> holds release unnamed-hostd, un, un-hook and un-stress
# (cargo build --release -p hostd -p un -p stress). Each scenario starts its own daemon in a temp
# state dir (with-daemon.sh) and prints peak RSS/CPU/fds/threads, the state after the load and
# whether the daemon survived. docs/STRESS.md lists the results.
set -u
B=$1; shift
W=$(cd "$(dirname $0)" && pwd)
D() { local name=$1; shift; "$W/with-daemon.sh" "$B" "$name" "$@"; }
ST=$B/un-stress

case_churn() {
  for c in 1 4 16 64; do
    echo "== churn, $c ops in flight, panes running sleep"
    RECOVER=2 D churn "$ST" churn --secs 8 --concurrency $c --command 'exec sleep 100'
  done
  echo "== churn, 16 in flight, login shells"
  RECOVER=2 D churn "$ST" churn --secs 8 --concurrency 16
}

case_floods() {
  for spec in "yes 4" "urandom 3" "bigline 2" "unicode 2" "altscreen 2" "title 1" "osc7 1" \
    "osc133 1" "notify 1" "osc7501 1" "osc52 1" "osc52big 1" "links 2" "kitty 1"; do
    echo "== flood: $spec"
    RECOVER=5 D flood "$W/s-flood.sh" ${=spec} ${FLOOD_SECS:-30}
  done
}

case_slow() {
  echo "== 4 clients that stop reading, next to a yes flood and a title flood"
  RECOVER=5 D slow "$W/s-slow.sh" 4 90
}

case_panes() {
  echo "== 400 panes as tabs (macOS allows 511 PTYs system-wide)"
  "$W/panes.sh" "$B" 400
  echo "== pane cap: a 600-descriptor limit allows 114 panes"
  DAEMON_NOFILE=600 "$W/panes.sh" "$B" 150
  echo "== launchd's soft limit of 256"
  DAEMON_NOFILE_SOFT=256 "$W/panes.sh" "$B" 150
  echo "== nested splits, then a restart"
  "$W/deep-restart.sh" "$B" 80
}

case_clients() {
  echo "== 50 paired clients on a flooding pane"
  RECOVER=5 D clients "$W/s-clients.sh" 50 30 0
  echo "== 200 guests on a flooding pane, each resizing 5 times a second"
  GUESTS=1 RECOVER=10 D clients "$W/s-clients.sh" 200 40 5
}

case_control() {
  echo "== keys, 100 MB paste, layout and project storms, reconnects, garbage resumes"
  RECOVER=5 D control "$W/s-control.sh"
}

case_lifecycle() {
  "$W/lifecycle.sh" "$B"
  "$W/diskfull.sh" "$B"
}

case_soak() {
  echo "== mixed soak, ${SOAK_MIN:-30} min, heap every ${HEAP_EVERY:-10} min"
  RECOVER=10 D soak "$W/s-soak-heap.sh" ${SOAK_MIN:-30}
}

case_hooks() {
  echo "== un-hook floods and approval spam"
  RECOVER=5 D hooks "$W/s-hooks.sh"
}

case_term() {
  # agent_spawn starts `codex`: a stand-in that only sleeps, so no real agent ever runs.
  local fake=$B/fake-agents
  mkdir -p "$fake"
  printf '#!/bin/sh\nexec sleep 600\n' >"$fake/codex"
  chmod +x "$fake/codex"
  echo "== terminal tools at high concurrency"
  PATH=$fake:$PATH RECOVER=5 D term "$W/s-term.sh"
  rm -rf "$fake"
}

case_upgrade() {
  # The upgrade replaces the running executable, so it runs from a copy.
  local copy=$B/upgrade-bin
  mkdir -p "$copy"
  cp "$B"/unnamed-hostd "$B"/un "$B"/un-hook "$B"/un-stress "$copy/"
  echo "== self-upgrade under load, 3 rounds"
  RECOVER=5 "$W/with-daemon.sh" "$copy" upgrade "$W/s-upgrade.sh" "$B/unnamed-hostd" 3
  rm -rf "$copy"
}

case_outages() {
  # Outages freeze the daemon (SIGSTOP): a user-space UDP proxy cannot cut the link, since
  # QUIC multipath finds the direct loopback path around it.
  echo "== input across outages"
  RECOVER=3 D chaos "$W/s-outages.sh"
}

for s in "$@"; do
  echo "######## $s"
  "case_$s"
done
