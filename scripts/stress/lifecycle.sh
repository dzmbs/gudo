#!/bin/zsh
# Usage: lifecycle.sh <bin_dir>: children that ignore SIGHUP, a zombie storm, SIGSTOP/SIGCONT of
# the daemon, a restart under load with a client attached, and a read-only state directory.
S=lifecycle BIN=$1
. "$(dirname $0)/lib.sh"
trap cleanup EXIT
G=$(cd $(dirname $0) && pwd)/gen.py
start_daemon; sleep 1.5; pair
sample "start"

echo "== children that ignore SIGHUP, then their panes close"
TAG=hupignore$$
for i in $(seq 5); do "$BIN/un-stress" spawn "trap '' HUP; exec sleep 1000 # $TAG" >/dev/null; done
sleep 1
sample "5 panes ignoring SIGHUP"
U session close >/dev/null 2>&1
sleep 8
echo "left running after close: $(pgrep -f "$TAG" | wc -l | tr -d ' ') (want 0)"
sample "after closing them"

echo "== zombie storm: 1000 children never reaped, then the pane closes"
"$BIN/un-stress" spawn "exec python3 -c 'import os,time
for _ in range(1000):
    if os.fork() == 0: os._exit(0)
time.sleep(1000)'" >/dev/null
sleep 3
echo "zombies: $(ps -axo stat= | grep -c '^Z')"
sample "zombie storm"
U session close >/dev/null 2>&1
sleep 3
sample "after closing it"

echo "== SIGSTOP the daemon for 20 s with a client following a flooding pane"
"$BIN/un-stress" spawn "exec yes" >/dev/null
"$BIN/unnamed-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' >"$ROOT/tickets"
"$BIN/un-stress" clients --tickets "$ROOT/tickets" --secs 50 >"$ROOT/clients1.txt" &
CL=$!
sleep 5
kill -STOP $DPID; sleep 20; kill -CONT $DPID
sleep 10
"$BIN/un-stress" latency --secs 3
wait $CL; cat "$ROOT/clients1.txt"
sample "after SIGCONT"

echo "== restart under load: kill the daemon with a client attached, start it again"
"$BIN/unnamed-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' >"$ROOT/tickets"
"$BIN/un-stress" clients --tickets "$ROOT/tickets" --secs 40 >"$ROOT/clients2.txt" &
CL=$!
sleep 8
kill $DPID; wait $DPID 2>/dev/null; kill $WPID 2>/dev/null
start_daemon
sleep 15
"$BIN/un-stress" latency --secs 3
wait $CL; cat "$ROOT/clients2.txt"
echo "(connected counts each (re)connection: 2 means the client came back by itself)"
sample "after restart"

echo "== read-only state directory"
chmod -R a-w "$ROOT/state"
for i in $(seq 20); do U tab new >/dev/null 2>&1; done
U tab rename readonly >/dev/null 2>&1
sleep 3
alive && echo "daemon alive with a read-only state dir" || echo "DAEMON DIED"
"$BIN/un-stress" latency --secs 2
chmod -R u+w "$ROOT/state"
grep -ciE 'error|warn' "$ROOT/daemon.log" | sed 's/^/log warnings+errors: /'
grep -iE 'layout.json|persist|saving' "$ROOT/daemon.log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c28-200 | sort | uniq -c | head -3
U session close >/dev/null 2>&1
sample "end"
