#!/usr/bin/env bash
# Runs LifecycleStressUITests on a simulator of its own (created here, deleted at the end)
# against a local unnamed-hostd: a memory warning every second while the test floods a pane and
# cycles background/foreground and rotation, the app's footprint sampled throughout, crash
# reports listed at the end.
#
#   apple/scripts/lifecycle-stress.sh [cycles]
#
# UN_HOSTD_BIN picks the daemon (default: target/debug/unnamed-hostd); DEVICE_TYPE the simulator;
# LOG_DIR keeps the xcodebuild log and footprint samples.
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cycles="${1:-10}"
type="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB}"
runtime="${RUNTIME:-}"
[[ -n "$runtime" ]] || runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print([r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r["isAvailable"]][0])')"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-lifecycle.XXXXXX")"
export PORT="${PORT:-47031}"
daemon() { "$apple/scripts/local-daemon.sh" "$@" "$state"; }

sim="$(xcrun simctl create "un-lifecycle-stress" "$type" "$runtime")"
cleanup() {
  [[ -n "${pump:-}" ]] && { kill "$pump" 2>/dev/null; wait "$pump" 2>/dev/null; } || true
  daemon stop || true
  xcrun simctl shutdown "$sim" 2>/dev/null || true
  xcrun simctl delete "$sim" 2>/dev/null || true
  rm -rf "$state"
}
trap cleanup EXIT
xcrun simctl boot "$sim"
ticket="$(daemon start)"
touch "$state/started"

log="$state/xcodebuild.log"
TEST_RUNNER_PAIR_TICKET="$ticket" TEST_RUNNER_CYCLES="$cycles" nice -n 15 xcodebuild -jobs 4 \
  -project "$apple/App.xcodeproj" -scheme App -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath "$apple/build/dd-lifecycle" -only-testing:AppUITests/LifecycleStressUITests test >"$log" 2>&1 &
test_pid=$!

# Memory warnings and footprint samples while the app runs.
(
  while kill -0 "$test_pid" 2>/dev/null; do
    xcrun simctl spawn "$sim" notifyutil -p dev.unnamed.debug.memorywarning 2>/dev/null || true
    pid="$(pgrep -f "Devices/$sim/.*/unnamed.app/unnamed" | head -1 || true)"
    if [[ -n "$pid" ]]; then
      echo "$(date +%T) $(footprint "$pid" 2>/dev/null | grep -m1 -E 'Footprint:' | tr -s ' ')" >>"$state/footprint.log"
    fi
    sleep 1
  done
) &
pump=$!

status=0
wait "$test_pid" || status=$?
grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)" "$log" | tail -10
echo "footprint samples: $(wc -l <"$state/footprint.log" 2>/dev/null || echo 0); first, last:"
head -1 "$state/footprint.log" 2>/dev/null || true
tail -1 "$state/footprint.log" 2>/dev/null || true
[[ -n "${LOG_DIR:-}" ]] && cp "$state/footprint.log" "$log" "$LOG_DIR/" 2>/dev/null || true
echo "crash reports since start:"
find ~/Library/Logs/DiagnosticReports -name 'unnamed*' -newer "$state/started" 2>/dev/null || true
exit "$status"
