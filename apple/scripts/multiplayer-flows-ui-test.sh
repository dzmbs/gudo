#!/usr/bin/env bash
# Runs MultiplayerFlowsUITests on an iPad simulator against two real local gudo-hostd:
#
#   daemon A  the app pairs as the owner. The `gudo` CLI (a second owner device) makes an
#             ask-first link; "Kim Lee" knocks with it (`gudo join`, waiting in the background)
#             and the app admits her as a driver. "Rex Diaz" joins as a driver and takes the
#             pane's lease; the app takes control from him.
#   daemon B  owned by the CLI only ("Ola"); its viewer link is opened in the app as a deep
#             link, so the app joins as a guest.
#
#             Live presence: Rex writes a prompt in pane 1 (`gudo draft`) that the app shows
#             as he types; the app follows him to pane 2; an agent in pane 1 asks permission
#             (agent-ask.py) and the app answers it for everyone.
#
#             Sharing: "Pat Quinn" stays connected and a "Temp" link waits; the app copies and
#             revokes the link and removes Pat.
#
#             Mirror: once the app's guest is in on daemon B, Ola opens a tab and writes
#             there; the guest follows her into it by itself.
#
# Afterwards the script checks Kim really got in as a driver, that the app followed Rex, that
# the agent was allowed and that Rex saw who answered, that Pat was cut off and the revoked
# link is refused.
#
#   apple/scripts/multiplayer-flows-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd -p cli` and the app project (xcodegen).
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$apple/.." && pwd)"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
work="$(mktemp -d "${TMPDIR:-/tmp}/gudo-mp-flows.XXXXXX")"
bin="${GUDO_HOSTD_BIN:-$repo/target/debug/gudo-hostd}"
gudo="${GUDO_BIN:-$repo/target/debug/gudo}"
port_a="${PORT_A:-$((47500 + RANDOM % 40))}"
port_b="$((port_a + 50))"
daemon() { PORT="$1" "$apple/scripts/local-daemon.sh" "$2" "$work/$3"; }
cli() { local who="$1"; shift; XDG_CONFIG_HOME="$work/$who" "$gudo" --no-relay "$@"; }

pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  daemon "$port_a" stop a; daemon "$port_b" stop b
  rm -rf "$work"
}
. "$apple/scripts/lib/cleanup.sh"
on_exit cleanup

ticket_app="$(daemon "$port_a" start a)"
ticket_b="$(daemon "$port_b" start b)"
cli_ticket() { "$bin" --state-dir "$work/$1" pair --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])'; }

# Daemon A: the CLI owner invites Rex (driver) and makes an ask-first link for Kim.
cli owner-a pair "$(cli_ticket a)" >/dev/null
rex_link="$(cli owner-a invite --role driver --name "Rex Diaz" --from Alex --no-qr --history full | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
knock_link="$(cli owner-a invite --role viewer --knock --uses 0 --from Alex --no-qr | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
[[ -n $rex_link && -n $knock_link ]] || { echo "no invite links from gudo invite" >&2; exit 1; }

# Rex holds the lease on the session's first pane: one connection keeps him present, another
# types and takes control (the lease stays while any of his connections is up).
cli rex join "$rex_link" >/dev/null
cli rex who --watch >"$work/rex-who.log" 2>&1 &
pids+=($!)
sleep 0.5
cli rex take-control --pane 1 >"$work/rex-take.log" 2>&1

# Sharing: Pat stays connected (to be removed); "Temp" is a link to copy and revoke.
pat_link="$(cli owner-a invite --role viewer --name "Pat Quinn" --from Alex --no-qr | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
temp_link="$(cli owner-a invite --role viewer --name "Temp" --uses 0 --from Alex --no-qr | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
cli pat join "$pat_link" >/dev/null
cli pat who --watch >"$work/pat-who.log" 2>&1 &
pat_pid=$!
pids+=("$pat_pid")

# Kim knocks and waits for the owner (the app) to answer.
cli kim join --name "Kim Lee" "$knock_link" >"$work/kim.log" 2>&1 &
kim_pid=$!
pids+=("$kim_pid")

# Daemon B: Ola's viewer link for the app's guest join.
cli owner-b pair "$(cli_ticket b)" >/dev/null
join_link="$(cli owner-b invite --role viewer --name "Gus" --scope session --from Ola --no-qr | grep -oE '[a-z]+://join/[^ ]+' | head -1)"
# The mirror: once a guest is in, Ola opens a tab (pane 2) and writes a prompt there.
(
  for _ in $(seq 1 600); do cli owner-b who 2>/dev/null | grep -v "(you)" | grep -q viewer && break; sleep 0.5; done
  cli owner-b tab new agent
  cli owner-b draft "Ship the mirror" --pane 2 --cps 8 --hold 40
) >"$work/ola.log" 2>&1 &
pids+=($!)

log="$work/xcodebuild.log"
status=0
derived="${DERIVED_DATA:-$apple/build/DerivedData}"
xcodebuild -project "$apple/App.xcodeproj" -scheme App -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath "$derived" build-for-testing >"$work/build.log" 2>&1 || { tail -30 "$work/build.log"; exit 1; }

# Live presence: a second pane; Rex writes a prompt in pane 1, again and again until someone
# follows him, then moves to pane 2 (the app scrolls there by hand, which stops following,
# and follows again). Meanwhile an agent in pane 1 asks for permission.
cli owner-a split --pane 1 >/dev/null
cli rex draft "Fix the flaky reconnect test" --pane 1 --cps 6 --then-focus 2 --hold 600 >"$work/rex-draft.log" 2>&1 &
pids+=($!)
python3 "$apple/scripts/agent-ask.py" "$work/a" 1 >"$work/ask.log" 2>&1 &
ask_pid=$!
pids+=("$ask_pid")

TEST_RUNNER_PAIR_TICKET="$ticket_app" TEST_RUNNER_JOIN_LINK="$join_link" TEST_RUNNER_KNOCKER=1 TEST_RUNNER_DRIVER=1 \
  TEST_RUNNER_PRESENCE=1 TEST_RUNNER_MIRROR=1 TEST_RUNNER_SHARING=1 \
  xcodebuild -collect-test-diagnostics never -project "$apple/App.xcodeproj" -scheme App \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$derived" \
  -resultBundlePath "$work/result.xcresult" \
  -only-testing:AppUITests/MultiplayerFlowsUITests test-without-building >"$log" 2>&1 || status=$?
grep -E "Test Case|error:|passed|failed|TEST (SUCCEEDED|FAILED)" "$log" | tail -20

# Kim was let in as a driver: her `gudo join` finished and says so.
for _ in $(seq 1 50); do kill -0 "$kim_pid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$kim_pid" 2>/dev/null; then
  echo "Kim is still waiting at the door"; status=1
elif grep -q "driver" "$work/kim.log"; then
  echo "Kim: $(tail -1 "$work/kim.log")"
else
  echo "Kim was not let in as a driver:"; cat "$work/kim.log"; status=1
fi

# The owner followed Rex to pane 2, answered the agent, and Rex saw who answered.
if grep -q "came along to pane 2" "$work/rex-draft.log"; then
  echo "Rex: $(grep 'came along' "$work/rex-draft.log")"
else
  echo "the owner did not follow Rex to pane 2:"; cat "$work/rex-draft.log"; status=1
fi
for _ in $(seq 1 25); do kill -0 "$ask_pid" 2>/dev/null || break; sleep 0.2; done
if [[ "$(cat "$work/ask.log")" == "allow" ]]; then echo "agent: allowed"; else echo "agent was not allowed: $(cat "$work/ask.log")"; status=1; fi
if grep -q "decided by" "$work/rex-who.log"; then
  echo "Rex saw: $(grep 'decided by' "$work/rex-who.log" | tail -1)"
else
  echo "Rex never saw the decision"; status=1
fi

# Pat was cut off; the revoked link lets nobody in.
for _ in $(seq 1 25); do kill -0 "$pat_pid" 2>/dev/null || break; sleep 0.2; done
if grep -q "revoked" "$work/pat-who.log"; then echo "Pat: removed"; else echo "Pat was not removed:"; cat "$work/pat-who.log"; status=1; fi
cli late join "$temp_link" >"$work/late.log" 2>&1 &
late_pid=$!
pids+=("$late_pid")
for _ in $(seq 1 50); do kill -0 "$late_pid" 2>/dev/null || break; sleep 0.2; done
if grep -q "refused" "$work/late.log"; then echo "revoked link: $(tail -1 "$work/late.log")"; else echo "the revoked link still works:"; cat "$work/late.log"; status=1; fi

if [[ -n "${SCREENSHOTS:-}" ]]; then
  mkdir -p "$SCREENSHOTS"
  xcrun xcresulttool export attachments --path "$work/result.xcresult" --output-path "$SCREENSHOTS" >/dev/null 2>&1 || true
  echo "attachments: $SCREENSHOTS"
fi
cp "$log" "${TMPDIR:-/tmp}/mp-flows-xcodebuild.log"
echo "log: ${TMPDIR:-/tmp}/mp-flows-xcodebuild.log"
exit "$status"
