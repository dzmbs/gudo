#!/bin/zsh
# Run by with-daemon.sh: the mixed soak (s-soak.sh <minutes>) plus, every HEAP_EVERY minutes
# (default 10), the malloc heap summary, the biggest allocation groups and the size of the
# command history, to tell a leak from a cache filling to its cap.
MIN=${1:-90}
EVERY=${HEAP_EVERY:-10}
"$(dirname $0)/s-soak.sh" $MIN &
SOAK=$!
for m in $(seq $EVERY $EVERY $MIN); do
  sleep $((EVERY * 60))
  kill -0 $SOAK 2>/dev/null || break
  echo "== heap at min $m: history lines $(wc -l <"$ROOT/state/history/commands.jsonl" 2>/dev/null | tr -d ' ')"
  heap $DPID 2>/dev/null | grep -E 'Physical footprint:|All zones: [0-9]+ nodes \('
  heap $DPID 2>/dev/null | sed -n '/COUNT/,$p' | sed -n 3,9p | cut -c1-140
done
wait $SOAK
