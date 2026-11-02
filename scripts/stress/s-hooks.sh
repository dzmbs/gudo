#!/bin/zsh
# Run by with-daemon.sh: real `un-hook` floods and approval spam from fake agents.
#   1. 4 panes × 16 threads running un-hook PreToolUse/PostToolUse for 30 s, echo probe
#   2. 20 fake agents × 4 threads running un-hook PermissionRequest for 60 s (each new request
#      replaces the one held open), a device registered for pushes with a local fake relay in
#      the background, echo probe
. "$(dirname $0)/jobs.sh"
echo "== un-hook flood: 4 panes x 16 threads, 30 s"
for i in 1 2 3 4; do job h$i hooks "$BIN/un-hook" 16 30; done
sleep 3
"$BIN/un-stress" latency --secs 25 --interval-ms 50
waitfor 4
echo "== approval spam: 20 fake agents x 4 threads, 60 s"
"$BIN/unnamed-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' >"$ROOT/push-ticket"
"$BIN/un-stress" push-sink --secs 80 --status ${RELAY_STATUS:-200} --ticket-file "$ROOT/push-ticket" &
PS=$!
sleep 3
for i in $(seq 20); do job p$i perm "$BIN/un-hook" 4 60; done
"$BIN/un-stress" latency --secs 60 --interval-ms 50
wait $PS
waitfor 24
echo "== 40 fake agents, each asking for a new approval every 4 s (each is pushed), 120 s"
"$BIN/unnamed-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' >"$ROOT/push-ticket"
"$BIN/un-stress" push-sink --secs 130 --status ${RELAY_STATUS:-200} --ticket-file "$ROOT/push-ticket" &
PS=$!
sleep 3
for i in $(seq 40); do job e$i perm-every "$BIN/un-hook" 4 120; done
wait $PS
waitfor 64
cat $OUT
"$BIN/un" --no-relay session close >/dev/null 2>&1
