#!/bin/zsh
# Run by with-daemon.sh: <count> panes running output generator <kind> for <secs>, one client
# following the last of them, and the echo latency of a quiet pane measured meanwhile.
# Kinds: yes, urandom, bigline (100 MB, no newline), or any gen.py kind.
KIND=$1; COUNT=${2:-1}; SECS=${3:-30}
G=$(cd $(dirname $0) && pwd)/gen.py
case $KIND in
  yes) CMD="exec yes" ;;
  urandom) CMD="exec cat /dev/urandom" ;;
  bigline) CMD="head -c 104857600 /dev/zero | tr '\\000' x; exec sleep 100000" ;;
  *) CMD="exec python3 $G $KIND ${RATE:-0}" ;;
esac
for i in $(seq $COUNT); do "$BIN/un-stress" spawn "$CMD" >/dev/null; done
"$BIN/unnamed-hostd" --state-dir "$ROOT/state" pair --json --local --wait 10 |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])' >"$ROOT/tickets"
"$BIN/un-stress" clients --tickets "$ROOT/tickets" --secs $SECS &
CL=$!
sleep 5
"$BIN/un-stress" latency --secs $((SECS - 10))
wait $CL
# Stop the load so the wrapper sees the recovery.
"$BIN/un" --no-relay session close >/dev/null 2>&1
