#!/usr/bin/env bash
# Runs MixedTabsUITests on an iPad simulator against two real local daemons ("alpha" on
# $PORT_A, "beta" on $PORT_B). The test splits a tab across both, relaunches the app, then asks
# for alpha to be killed (marker "kill-alpha") to check that beta's pane keeps working.
#
#   apple/scripts/mixed-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd` (or UN_HOSTD_BIN) and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
root="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-mixed.XXXXXX")"
a="$root/alpha" b="$root/beta"
daemon() { local port=$1; shift; PORT=$port SHELL_ARGS= "$apple/scripts/local-daemon.sh" "$@"; }

ticket_a="$(daemon "${PORT_A:-47421}" start "$a")"
ticket_b="$(daemon "${PORT_B:-47422}" start "$b")"
# Tickets are one-time: a second pair for the other test that pairs.
ticket_a2="$(daemon "${PORT_A:-47421}" start "$a")"
ticket_b2="$(daemon "${PORT_B:-47422}" start "$b")"
trap 'daemon "${PORT_A:-47421}" stop "$a"; daemon "${PORT_B:-47422}" stop "$b"' EXIT

log="$root/xcodebuild.log"
markers="$root/markers"
mkdir -p "$markers"
TEST_RUNNER_PAIR_TICKET_A="$ticket_a" TEST_RUNNER_PAIR_TICKET_B="$ticket_b" \
  TEST_RUNNER_PAIR_TICKET_A2="$ticket_a2" TEST_RUNNER_PAIR_TICKET_B2="$ticket_b2" TEST_RUNNER_MARKER_DIR="$markers" \
  xcodebuild -project "$apple/App.xcodeproj" \
  -scheme App -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -only-testing:"AppUITests/MixedTabsUITests${ONLY:+/$ONLY}" test >"$log" 2>&1 &
test_pid=$!

# The test writes a marker when it is ready for each step.
await() {
  for _ in $(seq 1 1800); do
    [[ -f "$markers/$1" ]] && return 0
    kill -0 "$test_pid" 2>/dev/null || return 1
    sleep 0.5
  done
  return 1
}
if await kill-alpha; then
  echo "killing alpha"
  daemon "${PORT_A:-47421}" stop "$a"
fi

status=0
wait "$test_pid" || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
echo "log: $log"
exit "$status"
