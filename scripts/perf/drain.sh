#!/bin/zsh
# Usage: drain.sh <bin_dir> <label>: one pane cats a 64 MB file once; reports how long the
# daemon took to take it all in and how much CPU it spent doing so.
set -u
BIN=$1; LABEL=$2
BENCH=$(cd "$(dirname $0)" && pwd)
OUT=${BENCH_OUT:-${TMPDIR:-/tmp}/gudo-bench}; mkdir -p $OUT
[ -f $OUT/big.txt ] || seq 1 9000000 | awk '{print "line " $1 " the quick brown fox jumps over the lazy dog"}' | head -c 67108864 > $OUT/big.txt
ROOT=$(mktemp -d $OUT/run-XXXX); STATE=$ROOT/state; CFG=$ROOT/cfg; mkdir -p $STATE $CFG
export XDG_CONFIG_HOME=$CFG GUDO_LOG=warn
printf '#!/bin/sh\nsleep 2\ncat %s\necho DRAIN-""DONE\nexec sleep 100000\n' $OUT/big.txt > $ROOT/f.sh; chmod +x $ROOT/f.sh
$BIN/gudo-hostd --state-dir $STATE run --no-relay --bind 127.0.0.1:0 --shell $ROOT/f.sh 2>$ROOT/daemon.log &
DPID=$!
trap "kill $DPID 2>/dev/null; pkill -f 'sleep 100000'; rm -rf $ROOT" EXIT
cpu_secs() { ps -o time= -p $1 | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
csw() { top -l 1 -pid $1 -stats csw | tail -1 | tr -d '+ '; }
sleep 1
TICKET=$($BIN/gudo-hostd --state-dir $STATE pair --json --local --wait 10 | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
U=${UN:-$BIN/gudo}
$U --no-relay pair "$TICKET" >/dev/null
c0=$(cpu_secs $DPID); w0=$(csw $DPID); t0=$(python3 -c 'import time; print(time.time())')
until $U --no-relay search "DRAIN-DONE" 2>/dev/null | head -1 | grep -q "^[1-9]"; do sleep 0.2; done
t1=$(python3 -c 'import time; print(time.time())'); c1=$(cpu_secs $DPID); w1=$(csw $DPID)
echo "$LABEL" | awk -v t0=$t0 -v t1=$t1 -v c0=$c0 -v c1=$c1 -v w0=$w0 -v w1=$w1 '{printf "%s\tdrain 64 MB: %.1f s wall (incl. 2 s start), %.1f CPU s, %.0f ctx switches\n", $1, t1-t0, c1-c0, w1-w0}'
