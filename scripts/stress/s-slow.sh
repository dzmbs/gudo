#!/bin/zsh
# Run by with-daemon.sh: <n> stuck clients (paired, subscribed to every pane, never reading)
# while one pane floods output and another floods title changes; measures the echo latency
# of a fresh pane meanwhile.
N=${1:-4}; SECS=${2:-40}
G=$(dirname $0)/gen.py
"$BIN/un-stress" spawn "exec yes" >/dev/null
"$BIN/un-stress" spawn "exec python3 $G title 0" >/dev/null
: >"$ROOT/tickets"
for i in $(seq $N); do
  "$BIN/unnamed-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' >>"$ROOT/tickets"
done
"$BIN/un-stress" slow --tickets "$ROOT/tickets" --secs $SECS &
SLOW=$!
sleep 10
"$BIN/un-stress" latency --secs 10
wait $SLOW
