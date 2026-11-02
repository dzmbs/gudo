#!/bin/zsh
# Usage: many.sh <bin_dir> <pty_tabs> <canvas_tabs>: a session with <pty_tabs> tabs running
# `sleep` (real PTYs) and <canvas_tabs> canvas tabs (no process), then the echo latency, a
# restart (the layout comes back), and closing it all. macOS allows 511 PTYs for the whole
# machine (kern.tty.ptmx_max), so past that only canvas panes add up.
S=many BIN=$1; PTYS=$2; CANVAS=$3
. "$(dirname $0)/lib.sh"
trap cleanup EXIT
start_daemon; sleep 1.5; pair
sample "start"
"$BIN/gudo-stress" tabs --count $PTYS --command 'exec sleep 100000'
sample "$PTYS PTY tabs"
"$BIN/gudo-stress" tabs --count $CANVAS --canvas
sleep 3
sample "+ $CANVAS canvas tabs"
"$BIN/gudo-stress" latency --secs 10
before=$(U ls 2>&1 | wc -l)
sleep 3 # the layout save is debounced
ls -la "$ROOT/state/layout.json" | awk '{print "layout.json: " $5 " bytes"}'
kill $DPID; wait $DPID 2>/dev/null; kill $WPID 2>/dev/null
t0=$(python3 -c 'import time; print(time.time())')
start_daemon
until U ls >/dev/null 2>&1; do sleep 0.2; alive || break; done
t1=$(python3 -c 'import time; print(time.time())')
alive || { echo "DAEMON DIED on restart"; tail -5 "$ROOT/daemon.log"; exit 1; }
sleep 5
sample "after restart"
printf "answering %.1f s after the restart; ls lines before: %s, after: %s\n" $((t1 - t0)) $before "$(U ls 2>&1 | wc -l)"
"$BIN/gudo-stress" latency --secs 10
U session close >/dev/null 2>&1
sleep 8
sample "after closing the session"
grep -iE 'panic|error' "$ROOT/daemon.log" | cut -c1-160 | sort | uniq -c | sort -rn | head -5
