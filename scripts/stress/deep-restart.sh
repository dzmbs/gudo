#!/bin/zsh
# Usage: deep-restart.sh <bin_dir> <depth>: nests `depth` splits (canvas panes, no processes),
# restarts the daemon and checks the layout came back whole.
S=deep BIN=$1; DEPTH=$2
. "$(dirname $0)/lib.sh"
trap cleanup EXIT
start_daemon; sleep 1.5; pair
"$BIN/gudo-stress" deep --depth $DEPTH --canvas
sample "after $DEPTH nested splits"
before=$(U ls 2>&1 | wc -l)
sleep 3 # the layout save is debounced
kill $DPID; wait $DPID 2>/dev/null; kill $WPID 2>/dev/null
start_daemon; sleep 3
alive || { echo "DAEMON DIED on restart"; tail -5 "$ROOT/daemon.log"; exit 1; }
after=$(U ls 2>&1 | wc -l)
echo "ls lines before restart: $before, after: $after"
ls "$ROOT/state" | grep -i bad && echo "LAYOUT FILE MOVED ASIDE AS UNREADABLE"
grep -i 'layout.json' "$ROOT/daemon.log" | tail -2
