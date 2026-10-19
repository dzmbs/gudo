#!/usr/bin/env bash
# Runs AskpassUITests on a simulator against a real local unnamed-hostd: a script in the pane
# runs $SSH_ASKPASS, the test answers in the secure card, and a hidden-input prompt gets the
# "Enter Password Securely" chip.
#
#   apple/scripts/askpass-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd` (unnamed-hostd and un-hook, side by side) and the app project
# (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-askpass.XXXXXX")"
export PORT="${PORT:-47013}"
daemon() { "$apple/scripts/local-daemon.sh" "$@" "$state"; }

ticket="$(daemon start)"
trap 'daemon stop; rm -rf "$state"' EXIT

log="$state/xcodebuild.log"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket" xcodebuild -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -only-testing:AppUITests/AskpassUITests test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
echo "log: $log"
exit "$status"
