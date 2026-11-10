#!/bin/zsh
# Run by with-daemon.sh: <n> tabs running sleep, then one raw client (QUIC's default of 100
# incoming streams, never accepting one) follows them all and reconnects resuming them all;
# a ping and an op must be answered within 1 s each time.
N=${1:-150}
"$BIN/gudo-stress" tabs --count $N --command 'exec sleep 600' | tail -1
"$BIN/gudo-stress" subs --limit-ms 1000
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
