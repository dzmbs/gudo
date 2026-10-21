#!/usr/bin/env bash
# Runs MultiplayerFlowsUITests on an iPad simulator against two real local unnamed-hostd:
#
#   daemon A  the app pairs as the owner. The `un` CLI (a second owner device) makes an
#             ask-first link; "Kim Lee" knocks with it (`un join`, waiting in the background)
#             and the app admits her as a driver. "Rex Diaz" joins as a driver and takes the
#             pane's lease; the app takes control from him.
#   daemon B  owned by the CLI only ("Ola"); its viewer link is opened in the app as a deep
#             link, so the app joins as a guest.
#
# Afterwards the script checks Kim really got in as a driver.
#
#   apple/scripts/multiplayer-flows-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd -p un` and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$apple/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
work="$(mktemp -d "${TMPDIR:-/tmp}/un-mp-flows.XXXXXX")"
bin="${UN_HOSTD_BIN:-$repo/target/debug/unnamed-hostd}"
un="${UN_BIN:-$repo/target/debug/un}"
port_a="${PORT_A:-$((47500 + RANDOM % 40))}"
port_b="$((port_a + 50))"
daemon() { PORT="$1" "$apple/scripts/local-daemon.sh" "$2" "$work/$3"; }
cli() { local who="$1"; shift; XDG_CONFIG_HOME="$work/$who" "$un" --no-relay "$@"; }

pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  daemon "$port_a" stop a; daemon "$port_b" stop b
  rm -rf "$work"
}
trap cleanup EXIT

ticket_app="$(daemon "$port_a" start a)"
ticket_b="$(daemon "$port_b" start b)"
cli_ticket() { "$bin" --state-dir "$work/$1" pair --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])'; }

# Daemon A: the CLI owner invites Rex (driver) and makes an ask-first link for Kim.
cli owner-a pair "$(cli_ticket a)" >/dev/null
rex_link="$(cli owner-a invite --role driver --name "Rex Diaz" --from Alex --no-qr --history full | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
knock_link="$(cli owner-a invite --role viewer --knock --uses 0 --from Alex --no-qr | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
[[ -n $rex_link && -n $knock_link ]] || { echo "no invite links from un invite" >&2; exit 1; }

# Rex holds the lease on the session's first pane: one connection keeps him present, another
# types and takes control (the lease stays while any of his connections is up).
cli rex join "$rex_link" >/dev/null
cli rex who --watch >"$work/rex-who.log" 2>&1 &
pids+=($!)
sleep 0.5
cli rex take-control --pane 1 >"$work/rex-take.log" 2>&1

# Kim knocks and waits for the owner (the app) to answer.
cli kim join --name "Kim Lee" "$knock_link" >"$work/kim.log" 2>&1 &
kim_pid=$!
pids+=("$kim_pid")

# Daemon B: Ola's viewer link for the app's guest join.
cli owner-b pair "$(cli_ticket b)" >/dev/null
join_link="$(cli owner-b invite --role viewer --name "Gus" --from Ola --no-qr | grep -oE '[a-z]+://join/[^ ]+' | head -1)"

log="$work/xcodebuild.log"
status=0
TEST_RUNNER_PAIR_TICKET="$ticket_app" TEST_RUNNER_JOIN_LINK="$join_link" TEST_RUNNER_KNOCKER=1 TEST_RUNNER_DRIVER=1 \
  xcodebuild -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "${DERIVED_DATA:-$apple/build/DerivedData}" \
  -resultBundlePath "$work/result.xcresult" \
  -only-testing:AppUITests/MultiplayerFlowsUITests test >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20

# Kim was let in as a driver: her `un join` finished and says so.
for _ in $(seq 1 50); do kill -0 "$kim_pid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$kim_pid" 2>/dev/null; then
  echo "Kim is still waiting at the door"; status=1
elif grep -q "driver" "$work/kim.log"; then
  echo "Kim: $(tail -1 "$work/kim.log")"
else
  echo "Kim was not let in as a driver:"; cat "$work/kim.log"; status=1
fi

if [[ -n "${SCREENSHOTS:-}" ]]; then
  mkdir -p "$SCREENSHOTS"
  xcrun xcresulttool export attachments --path "$work/result.xcresult" --output-path "$SCREENSHOTS" >/dev/null 2>&1 || true
  echo "attachments: $SCREENSHOTS"
fi
cp "$log" "${TMPDIR:-/tmp}/mp-flows-xcodebuild.log"
echo "log: ${TMPDIR:-/tmp}/mp-flows-xcodebuild.log"
exit "$status"
