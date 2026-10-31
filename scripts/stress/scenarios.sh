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

for s in "$@"; do
  echo "######## $s"
  "case_$s"
done
