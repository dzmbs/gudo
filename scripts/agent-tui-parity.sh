#!/bin/bash
# Launches the installed Codex and Claude Code in a daemon pane, to their start screen only
# (nothing is typed into them, nothing is sent to a model; Codex runs with a throwaway home),
# and fails unless they turn on what they turn on in Ghostty:
#
# - Codex: the composer drawn on the theme's background (OSC 11 answered), the dotted logo in
#   24-bit color, the pet sent as a kitty image.
# - Claude Code: XTVERSION recognised (it then probes kitty graphics), synchronized output,
#   the kitty keyboard protocol, theme change reports, progress reports, hyperlinks.
#
#   scripts/agent-tui-parity.sh [evidence dir]
#
# Each program's screen and raw output land in the evidence dir (default target/agent-tui).
# CODEX and CLAUDE name the binaries; otherwise they are looked up on PATH, and one that is not
# installed is skipped with a message.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="${1:-$repo_root/target/agent-tui}"

find_program() {
  local named="$1" command="$2" path
  path="${named:-$(command -v "$command" 2>/dev/null || true)}"
  if [ -n "$path" ] && [ -x "$path" ]; then
    echo "$path"
  fi
}

codex="$(find_program "${CODEX:-}" codex)"
claude="$(find_program "${CLAUDE:-}" claude)"
[ -n "$codex" ] || echo "agent-tui-parity: Codex is not installed; skipping it"
[ -n "$claude" ] || echo "agent-tui-parity: Claude Code is not installed; skipping it"
if [ -z "$codex" ] && [ -z "$claude" ]; then
  exit 0
fi

mkdir -p "$out_dir"
cd "$repo_root"
AGENT_TUI_CODEX="$codex" AGENT_TUI_CLAUDE="$claude" AGENT_TUI_OUT="$out_dir" \
  cargo test -p daemon --test it agent_tui_parity -- --ignored --nocapture --test-threads=1
echo "agent-tui-parity: passed; evidence in $out_dir"
