#!/usr/bin/env bash
# Runs GitUITests (git sidebar rows, the PR popover, Merge PR through the palette, New Task
# making a worktree) on a simulator against a local gudo-hostd on git-fixtures.sh: a
# repository with an origin and a second worktree, and a stand-in `gh` with fixture pull
# requests.
#
#   apple/scripts/git-ui-test.sh [simulator-udid] [test-name …]
#
# GIT_RESULTS keeps the result bundle (screenshots) and the daemon's log. Needs
# `cargo build -p hostd` and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
shift || true
state="$(mktemp -d "${TMPDIR:-/tmp}/gudo-git.XXXXXX")"
"$apple/scripts/git-fixtures.sh" "$state" >/dev/null
export PORT="${PORT:-47614}"

daemon() { PORT="$PORT" "$apple/scripts/w3-daemon.sh" "$1" "$state"; }
ticket="$(daemon start)"
. "$apple/scripts/lib/cleanup.sh"
on_exit 'daemon stop; rm -rf "$state"'

only=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do only+=("-only-testing:AppUITests/GitUITests/$name"); done
else
  only=("-only-testing:AppUITests/GitUITests")
fi

log="$state/xcodebuild.log"
results="${GIT_RESULTS:-$state/Git.xcresult}"
rm -rf "$results"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket" TEST_RUNNER_GIT_FIXTURES="$state" xcodebuild -collect-test-diagnostics never \
  -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -resultBundlePath "$results" "${only[@]}" test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -40
if [[ -n "${GIT_RESULTS:-}" ]]; then
  cp "$state/log" "$GIT_RESULTS.daemon.log" 2>/dev/null || true
  cp "$state/fixtures/log" "$GIT_RESULTS.gh.log" 2>/dev/null || true
fi
exit "$status"
