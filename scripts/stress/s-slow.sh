#!/bin/zsh
# Run by with-daemon.sh: <n> stuck clients (paired, subscribed to every pane, never reading)
# while one pane floods output and another floods title changes; measures the echo latency
# of a fresh pane meanwhile.
N=${1:-4}; SECS=${2:-40}
G=$(cd $(dirname $0) && pwd)/gen.py
"$BIN/gudo-stress" spawn "exec yes" >/dev/null
"$BIN/gudo-stress" spawn "exec python3 $G title 0" >/dev/null
: >"$ROOT/tickets"
for i in $(seq $N); do
  "$BIN/gudo-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' >>"$ROOT/tickets"
done
"$BIN/gudo-stress" slow --tickets "$ROOT/tickets" --secs $SECS &
SLOW=$!
sleep 10
"$BIN/gudo-stress" latency --secs 10
wait $SLOW
