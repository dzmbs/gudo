#!/bin/zsh
# Usage: with-daemon.sh <bin_dir> <name> <command> [args...]
# Starts a daemon (lib.sh), pairs, samples it every second in the background, runs
# `<command> [args...]` with BIN, ROOT, DPID and XDG_CONFIG_HOME exported, then prints the peak and
# the state 10 s after the load stopped, and whether the daemon survived.
S=$2 BIN=$1
. "$(dirname $0)/lib.sh"
shift 2
trap cleanup EXIT
start_daemon; sleep 1.5; pair
export BIN ROOT DPID XDG_CONFIG_HOME
sample "baseline"
(
  while kill -0 $DPID 2>/dev/null; do
    sample "t=$(date +%s)" >>"$ROOT/samples.txt"
    sleep 1
  done
) &
SPID=$!
"$@"
kill $SPID 2>/dev/null
awk '{for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="rss_mb"&&a[2]>r)r=a[2];if(a[1]=="cpu"&&a[2]+0>c)c=a[2]+0;if(a[1]=="fds"&&a[2]>f)f=a[2];if(a[1]=="threads"&&a[2]>t)t=a[2]}} END{printf "peak: rss_mb=%s cpu=%s fds=%s threads=%s\n",r,c,f,t}' "$ROOT/samples.txt"
if alive; then
  sleep ${RECOVER:-10}
  sample "after load (+${RECOVER:-10} s)"
  U ls >/dev/null 2>&1 && echo "daemon alive and answering" || echo "DAEMON NOT ANSWERING"
else
  echo "DAEMON DIED"
  tail -20 "$ROOT/daemon.log"
fi
cat "$ROOT/watchdog.log" 2>/dev/null
grep -E 'panic|ERROR' "$ROOT/daemon.log" | cut -c1-200 | sort | uniq -c | sort -rn | head -5
