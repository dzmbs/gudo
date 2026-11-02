#!/bin/zsh
# Usage: measure.sh <bin_dir> <label> [shell]
# Starts a daemon in a temp state dir with --no-relay, then measures idle RSS / CPU / wakeups
# at 0 (before pairing), 1, 10 and 50 panes, with and without an attached client.
set -u
BIN=$1; LABEL=$2; SHELL_BIN=${3:-/bin/zsh}
BENCH=$(cd "$(dirname $0)" && pwd)
OUT=${BENCH_OUT:-${TMPDIR:-/tmp}/gudo-bench}; mkdir -p $OUT
ROOT=$(mktemp -d $OUT/run-XXXX)
STATE=$ROOT/state; CFG=$ROOT/cfg; mkdir -p $STATE $CFG
export XDG_CONFIG_HOME=$CFG GUDO_LOG=warn
WINDOW=${WINDOW:-20}

$BIN/gudo-hostd --state-dir $STATE run --no-relay --bind 127.0.0.1:0 --shell $SHELL_BIN 2>$ROOT/daemon.log &
DPID=$!
trap "kill $DPID 2>/dev/null; pkill -f '$BIN/gudo --no-relay attach' 2>/dev/null; pkill -f 'sleep 100000'; rm -rf $ROOT" EXIT
sleep 3

csw() { top -l 1 -pid $1 -stats csw | tail -1 | tr -d '+ '; }
cpu_secs() { ps -o time= -p $1 | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }

measure() {
  local what=$1
  sleep ${SETTLE:-5}
  local c0=$(cpu_secs $DPID)
  local w0=$(csw $DPID)
  sleep $WINDOW
  local c1=$(cpu_secs $DPID)
  local w1=$(csw $DPID)
  local topout=$(top -l 1 -pid $DPID -stats pid,cpu,idlew,mem,th | tail -1)
  local rss=$(ps -o rss= -p $DPID)
  local idlew=$(echo "$w0 $w1 $WINDOW" | awk '{printf "%.1f", ($2-$1)/$3}')
  local th=$(echo $topout | awk '{print $5}')
  local cpu=$(echo "$c0 $c1 $WINDOW" | awk '{printf "%.2f", ($2-$1)/$3*100}')
  printf "%s\t%s\trss_mb=%.1f\tcpu%%=%s\tctx_switches/s=%s\tthreads=%s\n" $LABEL "$what" $(echo "$rss/1024" | bc -l) $cpu $idlew $th
}

measure "0 panes, no client"
TICKET=$($BIN/gudo-hostd --state-dir $STATE pair --json --local --wait 10 | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
$BIN/gudo --no-relay pair "$TICKET" >/dev/null
$BIN/gudo --no-relay ls > $ROOT/ls1.txt 2>&1
measure "1 pane, no client"
for i in $(seq 2 10); do $BIN/gudo --no-relay tab new >/dev/null; done
measure "10 panes, no client"
for i in $(seq 11 50); do $BIN/gudo --no-relay tab new >/dev/null; done
measure "50 panes, no client"
# One attached client (needs a tty): script(1) provides one.
(sleep 100000 | script -q /dev/null $BIN/gudo --no-relay attach >/dev/null 2>&1) &
APID=$!
measure "50 panes, 1 client attached"
pkill -f "$BIN/gudo --no-relay attach"; pkill -f "sleep 100000"; kill $APID 2>/dev/null
measure "50 panes, client gone"
