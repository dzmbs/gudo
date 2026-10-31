#!/bin/zsh
# Usage: busy.sh <bin_dir> <label> <panes> [active:yes|no]
# N panes in one session. With active=yes a realistic share runs things (see role.sh);
# the rest sit at a zsh prompt. Measures daemon RSS / CPU / context switches without a
# client, with one attached, and after it leaves.
set -u
BIN=$1; LABEL=$2; N=$3; ACTIVE=${4:-yes}
BENCH=$(cd "$(dirname $0)" && pwd)
OUT=${BENCH_OUT:-${TMPDIR:-/tmp}/unnamed-bench}; mkdir -p $OUT
ROOT=$(mktemp -d $OUT/run-XXXX)
STATE=$ROOT/state; CFG=$ROOT/cfg; mkdir -p $STATE $CFG
export XDG_CONFIG_HOME=$CFG UN_LOG=warn BENCH_ROOT=$ROOT BENCH_ACTIVE=$ACTIVE BENCH_DIR=$OUT
WINDOW=${WINDOW:-20}
[ -f $OUT/big.txt ] || seq 1 9000000 | awk '{print "line " $1 " the quick brown fox jumps over the lazy dog"}' | head -c 67108864 > $OUT/big.txt
$BIN/unnamed-hostd --state-dir $STATE run --no-relay --bind 127.0.0.1:0 --shell $BENCH/role.sh 2>$ROOT/daemon.log &
DPID=$!
trap "kill $DPID 2>/dev/null; pkill -f '$BIN/un --no-relay attach' 2>/dev/null; pkill -f 'sleep 100000'; pkill -f 'BENCH_ROLE'; rm -rf $ROOT" EXIT
sleep 3
csw() { top -l 1 -pid $1 -stats csw | tail -1 | tr -d '+ '; }
cpu_secs() { ps -o time= -p $1 | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
measure() {
  local what=$1
  sleep ${SETTLE:-5}
  local c0=$(cpu_secs $DPID) w0=$(csw $DPID)
  sleep $WINDOW
  local c1=$(cpu_secs $DPID) w1=$(csw $DPID)
  local rss=$(ps -o rss= -p $DPID)
  printf "%s\t%s panes (%s)\t%s\trss_mb=%.1f\tcpu%%=%s\tctx_switches/s=%s\n" $LABEL $N $([ $ACTIVE = yes ] && echo active || echo idle) "$what" $(echo "$rss/1024" | bc -l) $(echo "$c0 $c1 $WINDOW" | awk '{printf "%.1f", ($2-$1)/$3*100}') $(echo "$w0 $w1 $WINDOW" | awk '{printf "%.1f", ($2-$1)/$3}')
}
TICKET=$($BIN/unnamed-hostd --state-dir $STATE pair --json --local --wait 10 | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
$BIN/un --no-relay pair "$TICKET" >/dev/null
for i in $(seq 2 $N); do $BIN/un --no-relay tab new >/dev/null; done
if [ -n "${PROFILE:-}" ]; then sleep 5; sample $DPID 10 -file $PROFILE >/dev/null 2>&1; exit 0; fi
measure "no client"
(sleep 100000 | script -q /dev/null $BIN/un --no-relay attach >/dev/null 2>&1) &
measure "1 client attached"
pkill -f "$BIN/un --no-relay attach"
measure "client gone"
