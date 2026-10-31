#!/bin/zsh
# Run by with-daemon.sh: one pane running gen.py <kind>; after 5 s shows the pane's process
# state and a short sample(1) of the daemon (debugging aid).
KIND=$1
"$BIN/un-stress" spawn "exec python3 $(cd $(dirname $0) && pwd)/gen.py $KIND ${RATE:-0}" >/dev/null
sleep 5
ps -o pid,stat,%cpu,command -g $(pgrep -P $DPID | head -1) 2>/dev/null | head
pgrep -fl gen.py
sample $DPID 2 -file "$ROOT.sample.txt" >/dev/null 2>&1
grep -E 'pty-io|Thread_' "$ROOT.sample.txt" | head -20
echo "sample: $ROOT.sample.txt"
"$BIN/un" --no-relay session close >/dev/null 2>&1
