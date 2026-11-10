#!/bin/zsh
# Run by with-daemon.sh: 4 panes flooding OSC 133 marks and 4 running yes, 8 fake agents
# asking for a new approval every second, the daemon frozen (SIGSTOP) 5 s every 10 s, and one
# client following the session throughout: it must have seen every approval a fresh client
# sees at the end. Counts the times the daemon resent a client the whole state.
SECS=${1:-60}
G=$(cd $(dirname $0) && pwd)/gen.py
. "$(dirname $0)/jobs.sh"
for i in 1 2 3 4; do
  "$BIN/gudo-stress" spawn "exec python3 $G osc133 0" >/dev/null
  "$BIN/gudo-stress" spawn "exec yes" >/dev/null
done
for i in $(seq 8); do job a$i perm-every "$BIN/gudo-hook" 1 $((SECS + 10)); done
sleep 3
"$BIN/gudo-stress" approvals --secs $SECS &
FOLLOW=$!
END=$(($(date +%s) + SECS - 5))
while [ $(date +%s) -lt $END ]; do
  sleep 5
  kill -STOP $DPID; sleep 5; kill -CONT $DPID
done
wait $FOLLOW
echo "resyncs: $(grep -c 'fell behind the events' "$ROOT/daemon.log")"
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
