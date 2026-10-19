#!/usr/bin/env bash
# Runs W3UITests (Inbox, Files, Diff, Editor, Browser, Links on real daemon data) on an iPad
# simulator against a local unnamed-hostd set up by w3-fixtures.sh: HOME is a scratch work
# directory with a git repository, `claude` and `code` are stand-ins on PATH.
#
#   apple/scripts/w3-ui-test.sh [simulator-udid] [test-name …]
#
# Needs `cargo build -p hostd` (unnamed-hostd and un-hook) and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
shift || true
state="$(mktemp -d "${TMPDIR:-/tmp}/un-w3.XXXXXX")"
"$apple/scripts/w3-fixtures.sh" "$state" >/dev/null
export PORT="${PORT:-47013}"

daemon() {
  HOME="$state/work" PATH="$state/bin:$PATH" SHELL=/bin/zsh SHELL_ARGS= \
    "$apple/scripts/local-daemon.sh" "$@" "$state"
}
ticket="$(daemon start)"
trap 'daemon stop; pkill -f "http.server 18765" 2>/dev/null || true; rm -rf "$state"' EXIT

only=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do only+=("-only-testing:AppUITests/W3UITests/$name"); done
else
  only=("-only-testing:AppUITests/W3UITests")
fi

log="$state/xcodebuild.log"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket" TEST_RUNNER_W3_REPO="$state/work/proj" xcodebuild \
  -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -resultBundlePath "$state/W3.xcresult" "${only[@]}" test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -40
if [[ -n "${W3_RESULTS:-}" ]]; then
  rm -rf "$W3_RESULTS"
  cp -R "$state/W3.xcresult" "$W3_RESULTS"
  cp "$state/log" "$W3_RESULTS.daemon.log" 2>/dev/null || true
fi
exit "$status"
