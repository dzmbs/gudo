#!/bin/zsh
# Run by with-daemon.sh: <n> clients, each paired with its own key, follow the focused pane
# (running `yes`) for <secs>, resizing it <hz> times a second each; the echo latency of a
# quiet pane is measured meanwhile. GUESTS=1 joins them all with one unlimited driver invite
# instead of pairing each (pairing takes seconds per device).
N=$1; SECS=${2:-30}; HZ=${3:-0}
"$BIN/gudo-stress" spawn "exec yes" >/dev/null
: >"$ROOT/tickets"
if [ -n "${GUESTS:-}" ]; then
  INVITE=$("$BIN/gudo" --no-relay invite --uses 0 --role driver --no-qr | grep -o 'gudo://[^ ]*')
  for i in $(seq $N); do echo "$INVITE" >>"$ROOT/tickets"; done
else
  for i in $(seq $N); do
    "$BIN/gudo-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' >>"$ROOT/tickets"
  done
fi
"$BIN/gudo-stress" clients --tickets "$ROOT/tickets" --secs $SECS --resize-hz $HZ &
CL=$!
sleep $((SECS / 3))
"$BIN/gudo-stress" latency --secs $((SECS / 2))
wait $CL
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
