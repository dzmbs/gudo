#!/usr/bin/env bash
# A Mac screenshot of the git workspace on real data: a local unnamed-hostd on the git
# fixtures (git-fixtures.sh, a stand-in gh), the Debug app paired with it, drawn by the app
# itself (`-snapshot`, works on a locked Mac; glass shows as white shapes there).
#
#   apple/scripts/git-mac-screenshot.sh <app> <out.png> [light|dark]
set -euo pipefail

apple="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$1"
out="$2"
appearance="${3:-dark}"
state="$(mktemp -d "${TMPDIR:-/tmp}/un-git-mac.XXXXXX")"
"$apple/scripts/git-fixtures.sh" "$state" >/dev/null
export PORT="${PORT:-47615}"
daemon() { PORT="$PORT" "$apple/scripts/w3-daemon.sh" "$1" "$state"; }
ticket="$(daemon start)"
trap 'daemon stop; rm -rf "$state"' EXIT

rm -f "$out"
"$app/Contents/MacOS/$(basename "$app" .app)" -window-theme "$appearance" -ApplePersistenceIgnoreState YES \
    -testTicket "$ticket" -testRelay disabled -tabStyle sidebar \
    -snapshot "$out" -snapshotDelay 12 -snapshotQuit YES >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 60); do
    [[ -f "$out" ]] && break
    sleep 0.5
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
[[ -f "$out" ]] && echo "$out"
