#!/bin/zsh
# Usage (via with-daemon.sh): mem-during.sh <seconds-to-wait> <command> [args...]
# Runs the command and, after the wait, prints where the daemon's memory is: the malloc heap
# by allocation site, and the largest VM regions.
WAIT=$1; shift
"$@" &
CMD=$!
sleep $WAIT
heap $DPID 2>/dev/null | grep -E 'Physical footprint:|All zones: [0-9]+ nodes \('
heap $DPID 2>/dev/null | sed -n '/COUNT/,$p' | sed -n 3,12p | cut -c1-160
vmmap --summary $DPID 2>/dev/null | sed -n '/REGION TYPE/,/TOTAL/p' | sort -k3 -h | tail -4
wait $CMD
