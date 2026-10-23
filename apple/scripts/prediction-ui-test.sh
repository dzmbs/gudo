#!/usr/bin/env bash
# Runs EchoPredictionUITests on a simulator against a real local unnamed-hostd, whose events the
# app holds back to make a slow link: typed text is drawn ahead of the echo and confirmed.
#
#   apple/scripts/prediction-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd` (unnamed-hostd and un-hook, side by side) and the app project
# (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-prediction.XXXXXX")"
export PORT="${PORT:-47014}"
daemon() { "$apple/scripts/local-daemon.sh" "$@" "$state"; }

ticket="$(daemon start)"
trap 'daemon stop; rm -rf "$state"' EXIT

log="$state/xcodebuild.log"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket" xcodebuild -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -only-testing:AppUITests/EchoPredictionUITests test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
echo "log: $log"
exit "$status"
