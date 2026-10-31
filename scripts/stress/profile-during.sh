#!/bin/zsh
# Usage (via with-daemon.sh): profile-during.sh <seconds-to-wait> <command> [args...]
# Runs the command and takes a 5 s sample(1) profile of the daemon after the wait.
WAIT=$1; shift
"$@" &
CMD=$!
sleep $WAIT
sample $DPID 5 -file "$ROOT.profile.txt" >/dev/null 2>&1
wait $CMD
echo "profile: $ROOT.profile.txt"
