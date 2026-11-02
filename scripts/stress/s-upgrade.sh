#!/bin/zsh
# Run by with-daemon.sh with BIN pointing at a scratch copy of the binaries (the upgrade
# replaces $BIN/gudo-hostd): under full load (40 shells, 2 `yes` panes, a Unicode stream,
# a title flood, 20 guest clients following a flood, reconnects, an echo probe), the daemon is
# upgraded <rounds> times to the build in <new-hostd>. Each round: how long the upgrade took,
# when clients were back, whether every tab came back, and the echo latency afterwards.
NEW=$1; ROUNDS=${2:-3}
G=$(cd $(dirname $0) && pwd)/gen.py
for i in $(seq 40); do "$BIN/gudo-stress" spawn "exec sh" >/dev/null; done
for i in 1 2; do "$BIN/gudo-stress" spawn "exec yes" >/dev/null; done
"$BIN/gudo-stress" spawn "exec python3 $G unicode 2000" >/dev/null
"$BIN/gudo-stress" spawn "exec python3 $G title 0" >/dev/null
INVITE=$("$BIN/gudo" --no-relay invite --uses 0 --role driver --no-qr | grep -o 'gudo://[^ ]*')
: >"$ROOT/tickets"; for i in $(seq 20); do echo "$INVITE" >>"$ROOT/tickets"; done
SECS=$((ROUNDS * 60 + 30))
"$BIN/gudo-stress" clients --tickets "$ROOT/tickets" --secs $SECS >"$ROOT/clients.txt" &
CL=$!
"$BIN/gudo-stress" reconnect --secs $SECS --max-ms 2000 --parallel 2 >"$ROOT/reconnect.txt" &
RC=$!
tabs() { "$BIN/gudo" --no-relay ls 2>/dev/null | grep -c . ; }
sleep 20
before=$(tabs)
echo "  lines in \`gudo ls\` before: $before"
for r in $(seq $ROUNDS); do
  cp "$NEW" "$ROOT/new-hostd"
  t0=$(python3 -c 'import time; print(time.time())')
  "$BIN/gudo" --no-relay daemon upgrade "$ROOT/new-hostd" --build "stress-$r" 2>&1 | tail -1 | sed 's/^/  /'
  t1=$(python3 -c 'import time; print(time.time())')
  for i in $(seq 300); do
    "$BIN/gudo" --no-relay ls >/dev/null 2>&1 && break
    kill -0 $DPID 2>/dev/null || { echo "  DAEMON GONE after round $r"; tail -5 "$ROOT/daemon.log"; exit 1; }
    sleep 0.2
  done
  t2=$(python3 -c 'import time; print(time.time())')
  sleep 5
  printf "  round %d: upgrade answered in %.1f s, answering again %.1f s later; lines in \`gudo ls\`: %s; daemon pid %s\n" \
    $r $((t1 - t0)) $((t2 - t1)) "$(tabs)" "$(pgrep -f "$ROOT/state" | head -1)"
  "$BIN/gudo-stress" latency --secs 10 | sed 's/^/  /'
  sleep 20
done
wait $CL $RC
sed 's/^/  /' "$ROOT/clients.txt" "$ROOT/reconnect.txt"
grep -iE 'upgrade|restart' "$ROOT/daemon.log" | cut -c1-160 | tail -6
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
