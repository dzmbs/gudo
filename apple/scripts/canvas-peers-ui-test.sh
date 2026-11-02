#!/usr/bin/env bash
# Runs CanvasPeersUITests on a simulator against a real local unnamed-hostd with a second
# device on the same canvas pane: HostKit's CanvasPeerTests, paired with its own ticket, waits
# for the app's rectangle and adds an ellipse the app must show. Both have to pass.
#
#   apple/scripts/canvas-peers-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd`, `cargo xtask build-xcframework` and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$apple/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-canvas-peers.XXXXXX")"
export PORT="${PORT:-47015}"
daemon() { "$apple/scripts/local-daemon.sh" "$@" "$state"; }

ticket="$(daemon start)"
. "$apple/scripts/lib/cleanup.sh"
on_exit 'daemon stop; rm -rf "$state"'
bin="${UN_HOSTD_BIN:-$repo/target/debug/unnamed-hostd}"
peer_ticket="$("$bin" --state-dir "$state" pair --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')"

# The peer builds first (so its wait starts when the app does).
(cd "$apple/Packages/HostKit" && swift build --build-tests >/dev/null)
(cd "$apple/Packages/HostKit" && CANVAS_PEER_TICKET="$peer_ticket" swift test --skip-build --filter CanvasPeerTests) \
  >"$state/peer.log" 2>&1 &
peer=$!

log="$state/xcodebuild.log"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket" xcodebuild -collect-test-diagnostics never -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -only-testing:AppUITests/CanvasPeersUITests test >"$log" 2>&1 || status=$?
peer_status=0
wait "$peer" || peer_status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
grep -E "canvas peer|passed|failed|error" "$state/peer.log" | tail -10
echo "logs: $log $state/peer.log"
[[ $status -eq 0 && $peer_status -eq 0 ]]
