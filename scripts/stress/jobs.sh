# Sourced by the hook scenarios: run hookload.py in panes of the daemon under test.
H=$(cd $(dirname $0) && pwd)/hookload.py
OUT=$ROOT/hookload.txt
: >$OUT
# job <name> <hookload args...>: runs hookload in a new pane (it needs the pane's hook token).
job() {
  local f=$ROOT/job-$1.sh; shift
  print -r -- "HOOKLOAD_OUT=$OUT python3 $H ${(q)@}; exec sleep 1000" >$f
  "$BIN/un-stress" spawn "sh $f" >/dev/null
}
# waitfor <n>: until hookload has reported n runs (at most 5 min).
waitfor() {
  local end=$(($(date +%s) + 300))
  while [ $(grep -c '^[a-z]*: ' $OUT) -lt $1 ] && [ $(date +%s) -lt $end ]; do sleep 2; done
}
