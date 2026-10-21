#!/usr/bin/env bash
# Runs DeadHostPairingUITests on an iPad simulator: pairs a local unnamed-hostd (daemon 1),
# stops it, then pairs a fresh one on another port (daemon 2) with daemon 1 dead in the app's
# saved hosts and window state, as consecutive UI suites do. Daemon 2's ticket is minted
# together with others (the race that lost tickets and failed those suites).
#
#   apple/scripts/dead-host-ui-test.sh [simulator-udid]
#
# Needs `cargo build -p hostd` and the app project (xcodegen). PORT sets daemon 1's port
# (daemon 2 uses PORT+1); DERIVED_DATA the derived data folder; UN_HOSTD_BIN the daemon.
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${UN_HOSTD_BIN:-$apple/../target/debug/unnamed-hostd}"
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}"
first="$(mktemp -d "${TMPDIR:-/tmp}/un-dead-host-1.XXXXXX")"
second="$(mktemp -d "${TMPDIR:-/tmp}/un-dead-host-2.XXXXXX")"
port="${PORT:-$((47700 + RANDOM % 100 * 2))}"
log="${TMPDIR:-/tmp}/dead-host-ui-test.log"
: >"$log"

trap 'PORT=$port "$apple/scripts/local-daemon.sh" stop "$first"; PORT=$((port + 1)) "$apple/scripts/local-daemon.sh" stop "$second"; rm -rf "$first" "$second"' EXIT

run() {  # run <test> <env assignment>
  env "$2" xcodebuild -project "$apple/App.xcodeproj" -scheme App \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "${DERIVED_DATA:-$apple/build/DerivedData}" \
    -only-testing:"AppUITests/DeadHostPairingUITests/$1" test >>"$log" 2>&1
}

status=0
ticket="$(PORT=$port "$apple/scripts/local-daemon.sh" start "$first")"
run test1PairFirstHost "TEST_RUNNER_PAIR_TICKET_FIRST=$ticket" || status=$?
PORT=$port "$apple/scripts/local-daemon.sh" stop "$first"
if [[ $status -eq 0 ]]; then
  PORT=$((port + 1)) "$apple/scripts/local-daemon.sh" start "$second" >/dev/null
  # Daemon 2's ticket is minted alongside others, as `pair` racing the daemon's own startup
  # ticket did: a daemon that loses one of them refuses the app with InvalidGrant.
  for i in 1 2 3 4 5 6 7 8; do "$bin" --state-dir "$second" pair --json >"$second/mint$i" 2>/dev/null & done
  wait
  ticket="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ticket"])' "$second/mint1")"
  run test2PairSecondHostWhileFirstIsDead "TEST_RUNNER_PAIR_TICKET_SECOND=$ticket" || status=$?
  [[ -f "$second/devices.json" ]] && echo "daemon 2 paired a device" || echo "daemon 2 never paired a device"
fi
grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -20
echo "log: $log"
exit "$status"
