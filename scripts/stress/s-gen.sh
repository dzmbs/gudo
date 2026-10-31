#!/bin/zsh
# Run by with-daemon.sh: one pane running gen.py <kind> for <secs>, no client; prints the
# daemon's RSS every 5 s.
KIND=$1; SECS=${2:-20}
"$BIN/un-stress" spawn "exec python3 $(cd $(dirname $0) && pwd)/gen.py $KIND ${RATE:-0}" >/dev/null
for i in $(seq $((SECS / 5))); do
  sleep 5
  echo "t=$((i * 5))s rss_kb=$(ps -o rss= -p $DPID) gen=$(pgrep -f "gen.py $KIND" | head -1 | xargs ps -o stat=,%cpu= -p 2>/dev/null)"
done
"$BIN/un" --no-relay session close >/dev/null 2>&1
