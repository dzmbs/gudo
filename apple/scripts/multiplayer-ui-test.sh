#!/usr/bin/env bash
# Runs MultiplayerUITests on an iPad simulator against a real local gudo-hostd: the app pairs
# as the owner; a guest ("Mira Holt", viewer) joins through the `gudo` CLI and stays connected
# (`gudo who --watch`) so the app sees her, invites, lists grants, revokes her and reads the audit
# log. Afterwards the script checks the guest really was disconnected.
#
#   apple/scripts/multiplayer-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd -p cli` and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$apple/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
state="$(mktemp -d "${TMPDIR:-/tmp}/gudo-mp-ui.XXXXXX")"
export PORT="${PORT:-$((47100 + RANDOM % 800))}"
bin="${GUDO_HOSTD_BIN:-$repo/target/debug/gudo-hostd}"
gudo="${GUDO_BIN:-$repo/target/debug/gudo}"
daemon() { "$apple/scripts/local-daemon.sh" "$@" "$state"; }

watch_pid=
. "$apple/scripts/lib/cleanup.sh"
on_exit 'daemon stop; rm -rf "$state"'
ticket_app="$(daemon start)"

# A second owner device (the CLI) signs the guest's invite; the guest joins with its own key.
ticket_cli="$("$bin" --state-dir "$state" pair --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')"
export XDG_CONFIG_HOME="$state/owner-cli"
"$gudo" --no-relay pair "$ticket_cli" >/dev/null
link="$("$gudo" --no-relay invite --role viewer --name "Mira Holt" --ttl 24h --uses 1 | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
[[ -n $link ]] || { echo "no invite link from gudo invite" >&2; exit 1; }
export XDG_CONFIG_HOME="$state/guest-cli"
"$gudo" --no-relay join "$link"
"$gudo" --no-relay who --watch >"$state/guest-who.log" 2>&1 &
watch_pid=$!
unset XDG_CONFIG_HOME

log="$state/xcodebuild.log"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket_app" xcodebuild -collect-test-diagnostics never -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "${DERIVED_DATA:-$apple/build/DerivedData}" \
  -resultBundlePath "$state/result.xcresult" \
  -only-testing:AppUITests/MultiplayerUITests test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20

# The revoked guest's connection is closed by the daemon.
sleep 1
if kill -0 "$watch_pid" 2>/dev/null; then
  echo "guest still connected after revocation (gudo who --watch is running)"; tail -5 "$state/guest-who.log"
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
