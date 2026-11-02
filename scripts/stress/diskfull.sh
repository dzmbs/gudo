#!/bin/zsh
# Usage: diskfull.sh <bin_dir>: the daemon's state directory on a 32 MB disk image that is then
# filled; panes, layout changes and a restart must keep working (macOS, hdiutil).
S=diskfull BIN=$1
. "$(dirname $0)/lib.sh"
IMG=$ROOT.dmg
hdiutil create -size 32m -fs HFS+ -volname unstress -o "$IMG" >/dev/null
MNT=$(hdiutil attach -nobrowse "$IMG" | awk '/unstress/ {print $NF}')
cleanup_all() { cleanup; hdiutil detach "$MNT" -force >/dev/null 2>&1; rm -f "$IMG"; }
trap cleanup_all EXIT
rm -rf "$ROOT/state"; ln -s "$MNT" "$ROOT/state"
start_daemon; sleep 1.5; pair
for i in $(seq 5); do U tab new >/dev/null; done
dd if=/dev/zero of="$MNT/filler" bs=1m count=64 2>/dev/null
df -h "$MNT" | tail -1
sample "disk full"
for i in $(seq 20); do U tab new >/dev/null 2>&1 || echo "tab new failed"; done
U tab rename full >/dev/null 2>&1
"$BIN/un-stress" latency --secs 3
sleep 3
alive && echo "daemon alive with a full disk" || echo "DAEMON DIED"
grep -iE 'No space|ENOSPC|saving' "$ROOT/daemon.log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c28-200 | sort | uniq -c | head -5
echo "-- free space again, restart"
rm "$MNT/filler"
sleep 3
kill $DPID; wait $DPID 2>/dev/null; kill $WPID 2>/dev/null
start_daemon; sleep 3
U ls 2>&1 | head -3
sample "after restart"
