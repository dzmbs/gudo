#!/bin/zsh
# Run by with-daemon.sh: mixed load for <minutes>, sampling RSS/fds/threads each minute to spot
# leaks. 40 idle shells, a rate-limited output stream, a title stream, an OSC 133 stream, a
# client that keeps reconnecting, pane churn, and a latency probe every minute.
MIN=${1:-20}
G=$(cd $(dirname $0) && pwd)/gen.py
for i in $(seq 40); do "$BIN/gudo-stress" spawn "exec sh" >/dev/null; done
"$BIN/gudo-stress" spawn "exec python3 $G unicode 2000" >/dev/null
"$BIN/gudo-stress" spawn "exec python3 $G title 200" >/dev/null
"$BIN/gudo-stress" spawn "exec python3 $G osc133 200" >/dev/null
"$BIN/gudo-stress" reconnect --secs $((MIN * 60)) --max-ms 2000 --parallel 2 >"$ROOT/reconnect.txt" &
R=$!
(
  end=$(($(date +%s) + MIN * 60))
  while [ $(date +%s) -lt $end ]; do
    "$BIN/gudo-stress" churn --secs 5 --concurrency 2 --command 'exec sleep 100' >/dev/null
    sleep 25
  done
) &
C=$!
for m in $(seq $MIN); do
  sleep 50
  lat=$("$BIN/gudo-stress" latency --secs 5 --interval-ms 50 | sed 's/echo latency: //')
  printf "min %3d rss_kb=%s fds=%s threads=%s  %s\n" $m "$(ps -o rss= -p $DPID | tr -d ' ')" \
    "$(lsof -p $DPID 2>/dev/null | wc -l | tr -d ' ')" \
    "$(ps -M -p $DPID | tail -n +2 | wc -l | tr -d ' ')" "$lat"
done
wait $R $C
cat "$ROOT/reconnect.txt"
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
