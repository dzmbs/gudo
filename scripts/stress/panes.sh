#!/bin/zsh
# Usage: panes.sh <bin_dir> <count>: creates <count> panes as tabs with `gudo`, samples the daemon,
# then closes them all and checks it returns to baseline.
S=panes BIN=$1; N=$2
. "$(dirname $0)/lib.sh"
trap cleanup EXIT
start_daemon; sleep 1.5; pair
sample "start (1 pane)"
t0=$(date +%s)
fails=0
for i in $(seq 2 $N); do
  U tab new >/dev/null 2>>"$ROOT/gudo.err" || fails=$((fails + 1))
  [ $((i % 100)) -eq 0 ] && sample "$i panes"
done
echo "created $N panes in $(($(date +%s) - t0)) s, $fails failures"
sleep 5
sample "$N panes, settled"
U ls 2>&1 | tail -2
U session close >/dev/null 2>&1
sleep 5
sample "after closing the session"
alive && echo "daemon alive" || echo "DAEMON DIED"
tail -5 "$ROOT/gudo.err" 2>/dev/null
grep -iE 'panic|error' "$ROOT/daemon.log" | sort | uniq -c | sort -rn | head
