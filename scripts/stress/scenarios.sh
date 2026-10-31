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

for s in "$@"; do
  echo "######## $s"
  "case_$s"
done
