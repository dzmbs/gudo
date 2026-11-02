#!/bin/zsh
# Run by with-daemon.sh (with a fake `codex` first on PATH, see scenarios.sh): agents' terminal
# tools at high concurrency, called from inside panes as `gudo-hook mcp` calls them.
#   1. cmd_run without a pane from 40 threads: each opens a pane, up to the 32-pane cap
#   2. agent_spawn from 16 threads: the same cap for agents
#   3. 600 pane_waits for a pattern that never comes on a `yes` pane, next to real hooks
#      from another pane and an echo probe
. "$(dirname $0)/jobs.sh"
panes() { "$BIN/gudo" --no-relay ls 2>/dev/null | grep -c 'pane' ; }
echo "== cmd_run without a pane, 40 threads, 20 s"
job run term 40 20 cmd_run '{"command":"echo hi"}'
waitfor 1
echo "  lines with 'pane' in \`gudo ls\`: $(panes)"
echo "== agent_spawn (fake codex), 16 threads, 15 s"
job spawn term 16 15 agent_spawn '{"kind":"codex"}'
waitfor 2
echo "  lines with 'pane' in \`gudo ls\`: $(panes)"
echo "== 600 pane_waits on a yes flood, hooks from another pane, echo probe"
Y=$("$BIN/gudo-stress" spawn "exec yes")
job wait term 600 40 pane_wait "{\"pane\":\"p$Y\",\"match\":\"NEVER-MATCHES\",\"timeoutMs\":20000}"
sleep 5
job hooks hooks "$BIN/gudo-hook" 8 30
"$BIN/gudo-stress" latency --secs 30 --interval-ms 50
waitfor 4
cat $OUT
"$BIN/gudo" --no-relay session close >/dev/null 2>&1
