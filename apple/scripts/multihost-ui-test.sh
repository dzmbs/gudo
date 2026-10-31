#!/usr/bin/env bash
# Runs MultiHostUITests on an iPad simulator against two real local daemons ("alpha" on
# $PORT_A, "beta" on $PORT_B). Once the test has opened a second tab on beta (two leaves in
# beta's layout), it kills alpha, then restarts it 8 s later, so the test can check that alpha's
# group shows reconnecting while beta stays live, and that alpha comes back.
#
#   apple/scripts/multihost-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd` (or UN_HOSTD_BIN) and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
root="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-multihost.XXXXXX")"
a="$root/alpha" b="$root/beta"
daemon() { local port=$1; shift; PORT=$port SHELL_ARGS= "$apple/scripts/local-daemon.sh" "$@"; }

ticket_a="$(daemon "${PORT_A:-47021}" start "$a")"
ticket_b="$(daemon "${PORT_B:-47022}" start "$b")"
. "$apple/scripts/lib/cleanup.sh"
on_exit 'daemon "${PORT_A:-47021}" stop "$a"; daemon "${PORT_B:-47022}" stop "$b"'

log="$root/xcodebuild.log"
markers="$root/markers"
mkdir -p "$markers"
TEST_RUNNER_PAIR_TICKET_A="$ticket_a" TEST_RUNNER_PAIR_TICKET_B="$ticket_b" TEST_RUNNER_MARKER_DIR="$markers" \
  xcodebuild -collect-test-diagnostics never -project "$apple/App.xcodeproj" \
  -scheme App -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -only-testing:AppUITests/MultiHostUITests test >"$log" 2>&1 &
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
  daemon "${PORT_A:-47021}" stop "$a"
  if await restart-alpha; then
    echo "restarting alpha"
    daemon "${PORT_A:-47021}" start "$a" >/dev/null
  fi
fi

status=0
wait "$test_pid" || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
echo "log: $log"
exit "$status"
