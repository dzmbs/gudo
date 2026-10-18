#!/bin/sh
# Captures design screens of the macOS app in light and dark, without screen-recording access
# (works on a locked Mac): the Debug app draws its own window with `-snapshot`.
#   apple/scripts/mac-screenshots.sh <app> <out-dir> [screen ...]
set -eu

app=$1
out=$2
shift 2
screens=${*:-"single splits bar hosts inbox palette search reconnect overlays welcome pairing launchAgent invite links diff files browser editor"}
mkdir -p "$out"

for appearance in dark light; do
    for screen in $screens; do
        style=sidebar
        name=$screen
        if [ "$screen" = bar ]; then style=bar; name=splits; fi
        if [ "$screen" = toggle ]; then style=""; fi
        file="$out/mac-$screen-$appearance.png"
        rm -f "$file"
        theme="-window-theme $appearance"
        # shellcheck disable=SC2086
        "$app/Contents/MacOS/$(basename "$app" .app)" $theme -ApplePersistenceIgnoreState YES \
            -screen "$name" -mock ${style:+-tabStyle "$style"} -snapshot "$file" -snapshotDelay 3 -snapshotQuit YES \
            >/dev/null 2>&1 &
        pid=$!
        for _ in $(seq 1 30); do
            [ -f "$file" ] && break
            sleep 0.5
        done
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo "$file"
    done
done
