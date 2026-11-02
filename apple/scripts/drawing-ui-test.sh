#!/usr/bin/env bash
# Runs DrawingUITests (draw overlay, placements, Send To, export, Write) on a simulator against
# a local unnamed-hostd of its own.
#
#   apple/scripts/drawing-ui-test.sh [simulator-udid] [test-name …]
#
# DRAWING_RESULTS keeps the result bundle (screenshots). Needs `cargo build -p hostd` and the
# app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
shift || true
state="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-drawing.XXXXXX")"
export PORT="${PORT:-47016}"
daemon() { SHELL_ARGS= "$apple/scripts/local-daemon.sh" "$@" "$state"; }

ticket="$(daemon start)"
. "$apple/scripts/lib/cleanup.sh"
on_exit 'daemon stop; rm -rf "$state"'

only=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do only+=("-only-testing:AppUITests/DrawingUITests/$name"); done
else
  only=("-only-testing:AppUITests/DrawingUITests")
fi

log="$state/xcodebuild.log"
results="${DRAWING_RESULTS:-$state/Drawing.xcresult}"
rm -rf "$results"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket" xcodebuild -collect-test-diagnostics never -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -resultBundlePath "$results" "${only[@]}" test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -40
exit "$status"
