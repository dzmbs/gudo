#!/usr/bin/env bash
# Runs WindowsUITests on an iPad simulator against a real local daemon, with Stage Manager on
# (iPadOS windowing: a new window opens over the first, and the test brings either forward),
# and on an iPhone simulator if one is given (its own daemon: a ticket pairs one device).
#
#   apple/scripts/windows-ui-test.sh [ipad-udid] [iphone-udid]
#
# Needs `cargo build -p hostd` (or UN_HOSTD_BIN) and the app project (xcodegen). Stage Manager
# is turned on through SpringBoard's defaults (the simulator reboots once); it stays on.
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ipad="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
iphone="${2:-}"
root="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-windows.XXXXXX")"
started=()
cleanup() { for entry in "${started[@]}"; do PORT=${entry%%:*} SHELL_ARGS= "$apple/scripts/local-daemon.sh" stop "${entry#*:}" || true; done; }
trap cleanup EXIT

# Stage Manager (SpringBoard's "Chamois" windowing) in the iPad simulator.
xcrun simctl boot "$ipad" 2>/dev/null || true
if [[ "$(xcrun simctl spawn "$ipad" defaults read com.apple.springboard SBChamoisWindowingEnabled 2>/dev/null)" != 1 ]]; then
  xcrun simctl spawn "$ipad" defaults write com.apple.springboard SBChamoisWindowingEnabled -bool true
  xcrun simctl shutdown "$ipad"
  xcrun simctl boot "$ipad"
fi

status=0
port=${PORT:-47031}
run() {
  local sim=$1 log="$root/xcodebuild-$1.log" state="$root/daemon-$1"
  local ticket
  ticket="$(PORT=$port SHELL_ARGS= "$apple/scripts/local-daemon.sh" start "$state")"
  started+=("$port:$state")
  port=$((port + 1))
  TEST_RUNNER_PAIR_TICKET="$ticket" xcodebuild -project "$apple/App.xcodeproj" \
    -scheme App -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
    -only-testing:AppUITests/WindowsUITests test >"$log" 2>&1 || status=$?
  grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
  echo "log: $log"
}
run "$ipad"
[[ -n "$iphone" ]] && run "$iphone"
exit "$status"
