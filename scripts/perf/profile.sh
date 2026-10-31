#!/bin/zsh
# Usage: profile.sh <bin_dir> <mode yes|cat> <out>: one flooding pane, sample(1) the daemon for 8 s.
set -u
BIN=$1; MODE=$2; OUT=$3
BENCH=$(cd "$(dirname $0)" && pwd)
OUT=${BENCH_OUT:-${TMPDIR:-/tmp}/unnamed-bench}; mkdir -p $OUT
ROOT=$(mktemp -d $OUT/run-XXXX); STATE=$ROOT/state; CFG=$ROOT/cfg; mkdir -p $STATE $CFG
export XDG_CONFIG_HOME=$CFG UN_LOG=warn
if [ $MODE = yes ]; then printf '#!/bin/sh\nexec yes\n' > $ROOT/f.sh; else printf '#!/bin/sh\nwhile true; do cat %s; done\n' $OUT/big.txt > $ROOT/f.sh; fi
chmod +x $ROOT/f.sh
$BIN/unnamed-hostd --state-dir $STATE run --no-relay --bind 127.0.0.1:0 --shell $ROOT/f.sh 2>$ROOT/daemon.log &
DPID=$!
trap "kill $DPID 2>/dev/null; rm -rf $ROOT" EXIT
sleep 3
TICKET=$($BIN/unnamed-hostd --state-dir $STATE pair --json --local --wait 10 | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
$BIN/un --no-relay pair "$TICKET" >/dev/null
sleep 3
sample $DPID 8 -file $OUT >/dev/null 2>&1
