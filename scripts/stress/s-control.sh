#!/bin/zsh
# Run by with-daemon.sh: input and control storms against a session of 8 tabs, one after the
# other, each followed by a check that the daemon still answers and echoes.
for i in $(seq 7); do "$BIN/gudo-stress" spawn "exec cat" >/dev/null; done
step() {
  echo "-- $*"
  "$BIN/gudo-stress" "$@"
  "$BIN/gudo-stress" latency --secs 2 | sed 's/^/   after: /'
}
step keys --rate 10000 --secs 10
step paste --mb 100
step layout --rate 1000 --secs 10
step projects --rate 1000 --secs 10
step reconnect --secs 15 --max-ms 30 --parallel 8
step stale-resume --secs 15
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
