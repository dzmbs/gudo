#!/bin/sh
# Captures every design screen in light and dark on one booted simulator.
#   apple/scripts/screenshots.sh <simulator-udid> <prefix> <out-dir> [screen ...]
# The app must already be installed. Screens are DesignFixtures names (docs/DESIGN.md).
set -eu

device=$1
prefix=$2
out=$3
shift 3
screens=${*:-"single splits bar hosts inbox palette search reconnect overlays welcome pairing launchAgent invite links diff files browser editor settings"}
mkdir -p "$out"

for appearance in dark light; do
    xcrun simctl ui "$device" appearance "$appearance"
    for screen in $screens; do
        style=sidebar
        name=$screen
        if [ "$screen" = bar ]; then style=bar; name=splits; fi
        xcrun simctl launch --terminate-running-process "$device" dev.gudo.app \
            -screen "$name" -mock -tabStyle "$style" >/dev/null
        sleep "${SCREENSHOT_DELAY:-3}"
        xcrun simctl io "$device" screenshot --type=png "$out/$prefix-$screen-$appearance.png" >/dev/null 2>&1
        echo "$out/$prefix-$screen-$appearance.png"
    done
done
