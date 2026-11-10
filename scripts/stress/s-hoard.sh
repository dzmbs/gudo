#!/bin/zsh
# Run by with-daemon.sh: 4 panes (2 running yes), then <connections> raw connections each hold
# unread 30 MiB blob downloads, stalled uploads and streams without a header and flood links
# and history requests for <secs>, while the echo latency of a quiet pane is measured and a
# fresh subscription is timed every 5 s.
CONNS=${1:-16}; SECS=${2:-40}
"$BIN/gudo-stress" spawn "exec yes" >/dev/null
"$BIN/gudo-stress" spawn "exec yes" >/dev/null
"$BIN/gudo-stress" spawn "exec sleep 600" >/dev/null
"$BIN/gudo-stress" hoard --connections $CONNS --streams 64 --blob-mib 30 --secs $SECS &
HOARD=$!
sleep $((SECS / 3))
"$BIN/gudo-stress" latency --secs $((SECS / 2))
wait $HOARD
rm -f "$HOME"/hoard-*.bin
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
