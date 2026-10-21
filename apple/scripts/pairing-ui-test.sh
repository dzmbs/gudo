#!/usr/bin/env bash
# Runs PairingUITests on an iPad simulator against a real local unnamed-hostd (`--no-relay`):
# pairing by pasting a ticket into Add Host, by opening a `unnamed://pair/…` deep link, and
# with Settings › Network on "Direct and Local Network Only" plus an imported private CA. Each
# test gets its own ticket (a ticket pairs one device).
#
#   apple/scripts/pairing-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd` and the app project (xcodegen). DERIVED_DATA overrides the
# derived data folder (default apple/build/DerivedData); SCREENSHOTS=<dir> exports the
# screenshots.
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$apple/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-pairing-ui.XXXXXX")"
export PORT="${PORT:-$((47600 + RANDOM % 100))}"
bin="${UN_HOSTD_BIN:-$repo/target/debug/unnamed-hostd}"
daemon() { "$apple/scripts/local-daemon.sh" "$@" "$state"; }
mint() { "$bin" --state-dir "$state" pair --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])'; }

trap 'daemon stop; rm -rf "$state"' EXIT
paste_ticket="$(daemon start)"
link_ticket="$(mint)"
relay_ticket="$(mint)"

log="$state/xcodebuild.log"
status=0
TEST_RUNNER_PAIR_TICKET_PASTE="$paste_ticket" TEST_RUNNER_PAIR_TICKET_LINK="$link_ticket" \
TEST_RUNNER_PAIR_TICKET_RELAY="$relay_ticket" \
  xcodebuild -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "${DERIVED_DATA:-$apple/build/DerivedData}" \
  -resultBundlePath "$state/result.xcresult" \
  -only-testing:AppUITests/PairingUITests test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20

if [[ -n "${SCREENSHOTS:-}" ]]; then
  mkdir -p "$SCREENSHOTS"
  xcrun xcresulttool export attachments --path "$state/result.xcresult" --output-path "$SCREENSHOTS" >/dev/null 2>&1 || true
  echo "attachments: $SCREENSHOTS"
fi
# The state folder goes with the daemon; keep the log.
cp "$log" "${TMPDIR:-/tmp}/pairing-ui-test.log"
echo "log: ${TMPDIR:-/tmp}/pairing-ui-test.log"
exit "$status"
