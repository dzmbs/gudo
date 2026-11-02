#!/bin/zsh
# Run by with-daemon.sh: numbered lines typed every 20 ms into a pane that writes them to a
# file, while the daemon is frozen (SIGSTOP) now and then; every line must arrive exactly once.
O=(--pid $DPID --file $ROOT/typed.txt)
echo "== daemon frozen 2 s every 10 s (under the keepalive timeout), 40 s"
"$BIN/gudo-stress" outages $O --secs 40 --every 10 --outage-secs 2
echo "== daemon frozen 8 s every 20 s, 60 s"
"$BIN/gudo-stress" outages $O --secs 60 --every 20 --outage-secs 8
echo "== daemon frozen 20 s every 30 s (past the 12 s idle timeout: the link drops), 110 s"
"$BIN/gudo-stress" outages $O --secs 110 --every 30 --outage-secs 20
