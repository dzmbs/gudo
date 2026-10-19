#!/usr/bin/env bash
# Screenshots of the W3 screens on real daemon data: a local daemon with the UI tests' fixtures
# (w3-fixtures.sh: a git repository with changes, stand-in `claude` and `code`), an agent turn
# and a dev server started first, then each screen opened by `-screen <name>`.
#
#   apple/scripts/w3-screenshots.sh <simulator-udid> <prefix> <out-dir> [screen …]
#
# The app must be installed on the simulator. Screens: inbox files diff editor browser links
# launchAgent.
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device=$1 prefix=$2 out=$3
shift 3
screens=${*:-"inbox files diff editor browser links launchAgent"}
mkdir -p "$out"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-w3shots.XXXXXX")"
"$apple/scripts/w3-fixtures.sh" "$state" >/dev/null
export PORT="${PORT:-47014}"
bin="${UN_HOSTD_BIN:-$apple/../target/debug/unnamed-hostd}"
daemon() { PORT="${PORT:-47014}" "$apple/scripts/w3-daemon.sh" "$1" "$state"; }
ticket="$(daemon start)"
trap 'daemon stop; pkill -f "http.server 18766" 2>/dev/null || true; rm -rf "$state"' EXIT

app() {
  xcrun simctl launch --terminate-running-process "$device" dev.unnamed.app \
    -testTicket "$ticket" -testRelay disabled -noAutoFocus YES "$@" >/dev/null
}

xcrun simctl ui "$device" appearance dark
# First launch pairs and starts the shell; then a dev server in a second tab of output for
# links, and an agent that finishes one turn and asks for permission on the next.
app
sleep 6
app -screen seed -typeOnStart 'echo "see src/main.rs:2, README.md and http://localhost:18766/"; (python3 -m http.server 18766 --bind 127.0.0.1 >/dev/null 2>&1 &)\n'
sleep 4
app -screen seed -seedAgent "tidy the readme"
sleep 8
app -screen seed -seedAgent "now ask permission to clean up src/main.rs:2 (served at http://localhost:18766/)"
sleep 8
for screen in $screens; do
  app -screen "$screen"
  sleep "${SCREENSHOT_DELAY:-6}"
  xcrun simctl io "$device" screenshot --type=png "$out/$prefix-$screen-dark.png" >/dev/null 2>&1
  echo "$out/$prefix-$screen-dark.png"
done
