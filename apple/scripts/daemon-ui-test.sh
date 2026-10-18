#!/usr/bin/env bash
# Runs DaemonUITests on an iPad simulator against a real local unnamed-hostd, and drops the
# connection mid-test (kills the daemon once the test has split, restarts it 4 s later) so the
# test can check stale → live.
#
#   apple/scripts/daemon-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd` and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-daemon.XXXXXX")"
export PORT="${PORT:-47012}"
daemon() { SHELL_ARGS= "$apple/scripts/local-daemon.sh" "$@" "$state"; }

ticket="$(daemon start)"
trap 'daemon stop; rm -rf "$state"' EXIT

log="$state/xcodebuild.log"
TEST_RUNNER_PAIR_TICKET="$ticket" xcodebuild -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -only-testing:AppUITests/DaemonUITests test >"$log" 2>&1 &
test_pid=$!

# Wait for the split (two leaves persisted), give the second echo time, then drop the daemon.
for _ in $(seq 1 600); do
  if [[ -f "$state/layout.json" ]] && [[ "$(grep -c '"Leaf"' "$state/layout.json")" -ge 2 ]]; then break; fi
  kill -0 "$test_pid" 2>/dev/null || break
  sleep 0.5
done
sleep 6
echo "killing the daemon"
daemon stop
sleep 4
echo "restarting the daemon"
daemon start >/dev/null

status=0
wait "$test_pid" || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
echo "log: $log"
exit "$status"
