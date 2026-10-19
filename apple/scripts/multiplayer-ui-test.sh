#!/usr/bin/env bash
# Runs MultiplayerUITests on an iPad simulator against a real local unnamed-hostd: the app pairs
# as the owner; a guest ("Mira Holt", viewer) joins through the `un` CLI and stays connected
# (`un who --watch`) so the app sees her, invites, lists grants, revokes her and reads the audit
# log. Afterwards the script checks the guest really was disconnected.
#
#   apple/scripts/multiplayer-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd -p un` and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$apple/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-mp-ui.XXXXXX")"
export PORT="${PORT:-$((47100 + RANDOM % 800))}"
bin="${UN_HOSTD_BIN:-$repo/target/debug/unnamed-hostd}"
un="${UN_BIN:-$repo/target/debug/un}"
daemon() { "$apple/scripts/local-daemon.sh" "$@" "$state"; }

watch_pid=
trap '[[ -n $watch_pid ]] && kill $watch_pid 2>/dev/null; daemon stop; rm -rf "$state"' EXIT
ticket_app="$(daemon start)"

# A second owner device (the CLI) signs the guest's invite; the guest joins with its own key.
ticket_cli="$("$bin" --state-dir "$state" pair --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')"
export XDG_CONFIG_HOME="$state/owner-cli"
"$un" --no-relay pair "$ticket_cli" >/dev/null
link="$("$un" --no-relay invite --role viewer --name "Mira Holt" --ttl 24h --uses 1 | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
[[ -n $link ]] || { echo "no invite link from un invite" >&2; exit 1; }
export XDG_CONFIG_HOME="$state/guest-cli"
"$un" --no-relay join "$link"
"$un" --no-relay who --watch >"$state/guest-who.log" 2>&1 &
watch_pid=$!
unset XDG_CONFIG_HOME

log="$state/xcodebuild.log"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket_app" xcodebuild -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$apple/build/DerivedData" \
  -resultBundlePath "$state/result.xcresult" \
  -only-testing:AppUITests/MultiplayerUITests test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20

# The revoked guest's connection is closed by the daemon.
sleep 1
if kill -0 "$watch_pid" 2>/dev/null; then
  echo "guest still connected after revocation (un who --watch is running)"; tail -5 "$state/guest-who.log"
  status=1
else
  echo "guest disconnected: $(tail -1 "$state/guest-who.log")"
fi

if [[ -n "${SCREENSHOTS:-}" ]]; then
  mkdir -p "$SCREENSHOTS"
  xcrun xcresulttool export attachments --path "$state/result.xcresult" --output-path "$SCREENSHOTS" >/dev/null 2>&1 || true
  echo "attachments: $SCREENSHOTS"
fi
echo "log: $log"
exit "$status"
