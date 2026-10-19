#!/usr/bin/env bash
# Runs WindowsUITests on an iPad simulator against a real local daemon, with Stage Manager on
# (so a second window sits next to the first), and on an iPhone simulator if one is given.
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
port="${PORT:-47031}"
daemon() { PORT=$port SHELL_ARGS= "$apple/scripts/local-daemon.sh" "$@"; }

ticket="$(daemon start "$root/studio")"
trap 'daemon stop "$root/studio"' EXIT

# Stage Manager (SpringBoard's "Chamois" windowing) in the iPad simulator.
xcrun simctl boot "$ipad" 2>/dev/null || true
if [[ "$(xcrun simctl spawn "$ipad" defaults read com.apple.springboard SBChamoisWindowingEnabled 2>/dev/null)" != 1 ]]; then
  xcrun simctl spawn "$ipad" defaults write com.apple.springboard SBChamoisWindowingEnabled -bool true
  xcrun simctl shutdown "$ipad"
  xcrun simctl boot "$ipad"
fi

status=0
run() {
  local sim=$1 log="$root/xcodebuild-$1.log"
  TEST_RUNNER_PAIR_TICKET="$ticket" xcodebuild -project "$apple/App.xcodeproj" \
    -scheme App -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
    -only-testing:AppUITests/WindowsUITests test >"$log" 2>&1 || status=$?
  grep -E "Test Case|error:|passed|failed|skipped|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
  echo "log: $log"
}
run "$ipad"
[[ -n "$iphone" ]] && run "$iphone"
exit "$status"
