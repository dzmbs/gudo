#!/usr/bin/env bash
# Runs WindowsUITests on an iPad simulator against a real local daemon, with Stage Manager on
# (iPadOS windowing: a new window opens over the first, and the test brings either forward),
# and on an iPhone simulator if one is given (its own daemon: a ticket pairs one device).
#
#   apple/scripts/windows-ui-test.sh [ipad-udid] [iphone-udid]
#
# Needs `cargo build -p hostd` (or UN_HOSTD_BIN) and the app project (xcodegen). The simulators
# are erased before each step (iPadOS keeps the windows of earlier runs, hidden, and a launch
# beside them is sometimes refused); the iPad gets Stage Manager through SpringBoard's defaults.
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ipad="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
iphone="${2:-}"
root="$(mktemp -d "${TMPDIR:-/tmp}/un-ui-windows.XXXXXX")"
started=()
cleanup() { for entry in "${started[@]}"; do PORT=${entry%%:*} SHELL_ARGS= "$apple/scripts/local-daemon.sh" stop "${entry#*:}" || true; done; }
trap cleanup EXIT

# A clean simulator; `yes`: with Stage Manager ("Chamois" windowing).
fresh() {
  local sim=$1 stage=$2
  xcrun simctl shutdown "$sim" 2>/dev/null || true
  xcrun simctl erase "$sim"
  xcrun simctl boot "$sim"
  if [[ $stage == yes ]]; then
    xcrun simctl spawn "$sim" defaults write com.apple.springboard SBChamoisWindowingEnabled -bool true
    xcrun simctl shutdown "$sim"
    xcrun simctl boot "$sim"
  fi
}

status=0
port=${PORT:-47031}
# A daemon of its own for each step (a ticket pairs once; an erased simulator pairs anew).
daemon() {
  local state="$root/daemon-$port"
  ticket="$(PORT=$port SHELL_ARGS= "$apple/scripts/local-daemon.sh" start "$state")"
  started+=("$port:$state")
  port=$((port + 1))
}

run() {
  local sim=$1 stage=$2 log="$root/xcodebuild-$1.log"
  ticket=""
  local test=(xcodebuild -project "$apple/App.xcodeproj" -scheme App -destination "platform=iOS Simulator,id=$sim"
    -derivedDataPath "$apple/build/DerivedData")
  # The two-window test first, then the rest, each on a fresh simulator.
  fresh "$sim" "$stage"
  daemon
  TEST_RUNNER_PAIR_TICKET="$ticket" "${test[@]}" \
    -only-testing:AppUITests/WindowsUITests/testTwoWindowsOnOneHostTypeIndependently test >"$log" 2>&1 || status=$?
  fresh "$sim" "$stage"
  daemon
  TEST_RUNNER_PAIR_TICKET="$ticket" "${test[@]}" -only-testing:AppUITests/WindowsUITests \
    -skip-testing:AppUITests/WindowsUITests/testTwoWindowsOnOneHostTypeIndependently test >>"$log" 2>&1 || status=$?
  grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
  echo "log: $log"
}
run "$ipad" yes
[[ -n "$iphone" ]] && run "$iphone" no
exit "$status"
