#!/bin/zsh
# Usage: heavy.sh <bin_dir> <label> <mode: yes|cat>
# One pane whose "shell" floods output: `yes` forever, or `cat` of a 64 MB file once and
# then idles. Measures RSS/CPU without a client, with one attached, and after it leaves.
set -u
BIN=$1; LABEL=$2; MODE=$3
BENCH=$(cd "$(dirname $0)" && pwd)
OUT=${BENCH_OUT:-${TMPDIR:-/tmp}/gudo-bench}; mkdir -p $OUT
ROOT=$(mktemp -d $OUT/run-XXXX)
STATE=$ROOT/state; CFG=$ROOT/cfg; mkdir -p $STATE $CFG
export XDG_CONFIG_HOME=$CFG GUDO_LOG=warn
WINDOW=${WINDOW:-15}
[ -f $OUT/big.txt ] || seq 1 9000000 | awk '{print "line " $1 " the quick brown fox jumps over the lazy dog"}' | head -c 67108864 > $OUT/big.txt
if [ $MODE = yes ]; then
  printf '#!/bin/sh\nexec yes\n' > $ROOT/flood.sh
else
  printf '#!/bin/sh\ncat %s\nexec sleep 100000\n' $OUT/big.txt > $ROOT/flood.sh
fi
chmod +x $ROOT/flood.sh
# The daemon starts with no pane; pairing creates the first, so start it with zsh and
# point new panes at the flood script afterwards via a second daemon run is not possible:
# instead the flood script is the shell from the start.
$BIN/gudo-hostd --state-dir $STATE run --no-relay --bind 127.0.0.1:0 --shell $ROOT/flood.sh 2>$ROOT/daemon.log &
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
  local rss=$(ps -o rss= -p $DPID)
  printf "%s\t%s\t%s\trss_mb=%.1f\tcpu%%=%s\tctx_switches/s=%s\n" $LABEL $MODE "$what" $(echo "$rss/1024" | bc -l) $(echo "$c0 $c1 $WINDOW" | awk '{printf "%.1f", ($2-$1)/$3*100}') $(echo "$w0 $w1 $WINDOW" | awk '{printf "%.1f", ($2-$1)/$3}')
}
TICKET=$($BIN/gudo-hostd --state-dir $STATE pair --json --local --wait 10 | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
$BIN/gudo --no-relay pair "$TICKET" >/dev/null
measure "1 flooding pane, no client"
(sleep 100000 | script -q /dev/null $BIN/gudo --no-relay attach >/dev/null 2>&1) &
measure "1 flooding pane, client attached"
pkill -f "$BIN/gudo --no-relay attach"
sleep 40
measure "1 flooding pane, client gone (+40 s)"
