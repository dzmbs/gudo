#!/usr/bin/env bash
# directory, the stand-in `claude` and `code` are first on PATH. Prints the pairing ticket.
#
#   apple/scripts/w3-daemon.sh start <dir>   # creates the fixtures if <dir> has none
#   apple/scripts/w3-daemon.sh stop  <dir>
#
# PORT sets the daemon's UDP port (default 47613).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="$1"
dir="$2"
if [[ "$action" == start && ! -d "$dir/work/proj" ]]; then
  "$apple/scripts/w3-fixtures.sh" "$dir" >/dev/null
fi
export PORT="${PORT:-47613}"
HOME="$dir/work" PATH="$dir/bin:$PATH" SHELL=/bin/zsh SHELL_ARGS= \
  "$apple/scripts/local-daemon.sh" "$action" "$dir"
