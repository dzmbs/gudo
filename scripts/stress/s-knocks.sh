#!/bin/zsh
# Run by with-daemon.sh: fresh devices knocking on one knock invite, as fast as the daemon
# lets them in, while an owner client is connected and an echo probe runs. Then the waiting
# list, the audit log's growth and whether the owner still gets answers.
SECS=${1:-60}
"$BIN/gudo" --no-relay invite --knock --uses 0 --role driver --no-qr >"$ROOT/invite.txt"
before=$(wc -c <"$ROOT/state/audit/audit.jsonl" 2>/dev/null || echo 0)
echo "== 32 knockers at a time, each hanging up after 2 s, $SECS s"
"$BIN/gudo-stress" knocks --invite-file "$ROOT/invite.txt" --secs $SECS --parallel 32 --hold-ms 2000 &
K=$!
sleep 5
"$BIN/gudo-stress" latency --secs $((SECS - 10)) --interval-ms 50
"$BIN/gudo" --no-relay knocks 2>&1 | tail -3 | sed 's/^/  knocks mid-flood: /'
wait $K
echo "== 32 knockers that stay, 30 s (the per-invite cap)"
"$BIN/gudo-stress" knocks --invite-file "$ROOT/invite.txt" --secs 30 --parallel 32 --hold-ms 30000 &
K=$!
sleep 20
echo "  waiting knocks: $("$BIN/gudo" --no-relay knocks 2>/dev/null | grep -c .)"
wait $K
after=$(wc -c <"$ROOT/state/audit/audit.jsonl" 2>/dev/null || echo 0)
echo "  audit log grew by $(((after - before) / 1024)) KiB ($(wc -l <"$ROOT/state/audit/audit.jsonl") records)"
python3 -c '
import collections, json, sys
c = collections.Counter()
for line in open(sys.argv[1]):
    r = json.loads(line)
    c[(r.get("kind"), " ".join(r.get("detail", "").split()[-4:]))] += 1
for (k, d), n in c.most_common(6): print(f"    {n:6} {k}: …{d}")' "$ROOT/state/audit/audit.jsonl"
sleep 5
heap $DPID 2>/dev/null | grep -E 'Physical footprint:|All zones: [0-9]+ nodes \(' | sed 's/^/  /'
# iroh keeps state per remote key for 60 s after its last connection.
sleep 65
echo "  65 s later:"
heap $DPID 2>/dev/null | grep -E 'Physical footprint:|All zones: [0-9]+ nodes \(' | sed 's/^/  /'
# With MallocStackLogging=lite in the daemon's environment: where the memory still held was
# allocated.
[ -n "${MallocStackLogging:-}" ] && malloc_history $DPID -allBySize 2>/dev/null >"$ROOT/../knocks-malloc.txt"
