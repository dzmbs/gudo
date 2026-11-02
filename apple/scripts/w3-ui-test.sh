#!/usr/bin/env bash
# Runs W3UITests (Inbox, Files, Diff, Editor, Browser, Links on real daemon data) on an iPad
# simulator against a local gudo-hostd set up by w3-fixtures.sh: HOME is a scratch work
# directory with a git repository, `claude` and `code` are stand-ins on PATH.
#
#   apple/scripts/w3-ui-test.sh [simulator-udid] [test-name …]
#
# UI_TEST_CLASS picks another suite on the same fixtures (default W3UITests), e.g.
# UI_TEST_CLASS=AgentApprovalsUITests for agent toasts and the approval verbs.
#
# Needs `cargo build -p hostd` (gudo-hostd and gudo-hook) and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
shift || true
state="$(mktemp -d "${TMPDIR:-/tmp}/gudo-w3.XXXXXX")"
"$apple/scripts/w3-fixtures.sh" "$state" >/dev/null
export PORT="${PORT:-47613}"

daemon() { PORT="${PORT:-47613}" "$apple/scripts/w3-daemon.sh" "$1" "$state"; }
ticket="$(daemon start)"
# vscode.dev's stand-in for the Remote Tunnel test.
tunnel_web_port="${TUNNEL_WEB_PORT:-47712}"
"$state/bin/vscode-dev-stub" "$tunnel_web_port" &
stub=$!
. "$apple/scripts/lib/cleanup.sh"
on_exit 'daemon stop; kill $stub 2>/dev/null || true; pkill -f "http.server 18765" 2>/dev/null || true; pkill -f "devserver 4831" 2>/dev/null || true; rm -rf "$state"'

suite="${UI_TEST_CLASS:-W3UITests}"
only=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do only+=("-only-testing:AppUITests/$suite/$name"); done
else
  only=("-only-testing:AppUITests/$suite")
fi

log="$state/xcodebuild.log"
# W3_RESULTS keeps the result bundle (screenshots) and the daemon's log.
results="${W3_RESULTS:-$state/W3.xcresult}"
rm -rf "$results"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket" TEST_RUNNER_W3_REPO="$state/work/proj" \
  TEST_RUNNER_TUNNEL_WEB="http://127.0.0.1:$tunnel_web_port" xcodebuild -collect-test-diagnostics never \
  -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -resultBundlePath "$results" "${only[@]}" test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -40
if [[ -n "${W3_RESULTS:-}" ]]; then cp "$state/log" "$W3_RESULTS.daemon.log" 2>/dev/null || true; fi
exit "$status"
