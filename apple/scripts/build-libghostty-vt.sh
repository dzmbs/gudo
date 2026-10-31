#!/usr/bin/env bash
# Builds ghostty-vt.xcframework (macOS universal, iOS arm64, iOS simulator arm64) from the pinned
# vendor/ghostty plus patches/ghostty (scripts/ghostty-source.sh). TerminalKit consumes it as the
# `GhosttyVt` binary target.
#
# Output: apple/build/ghostty-vt/lib/ghostty-vt.xcframework
#
# Requires Zig 0.17.x (Ghostty pins major.minor) and Xcode: xcodebuild assembles the xcframework,
# and the iOS slices are only emitted when the iOS SDK is installed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ghostty="$repo_root/vendor/ghostty"
prefix="${GHOSTTY_VT_PREFIX:-$repo_root/apple/build/ghostty-vt}"
optimize="${GHOSTTY_VT_OPTIMIZE:-fast}"
zig="${ZIG:-zig}"

if [[ ! -f "$ghostty/build.zig" ]]; then
  git -C "$repo_root" submodule update --init vendor/ghostty
fi

zig_version="$("$zig" version)"
if [[ "$zig_version" != 0.17.* ]]; then
  echo "error: Zig 0.17.x required, found $zig_version" >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: xcodebuild from Xcode (not only the Command Line Tools) is required" >&2
  exit 1
fi

source="$repo_root/apple/build/ghostty-src"
version="$("$repo_root/scripts/ghostty-source.sh" "$source")"

rm -rf "$prefix"
(cd "$source" && "$zig" build \
  -Demit-lib-vt \
  -Demit-xcframework=true \
  -Dversion-string="$version" \
  -Doptimize="$optimize" \
  --cache-dir "$ghostty/.zig-cache" \
  --prefix "$prefix")

xcframework="$prefix/lib/ghostty-vt.xcframework"
for slice in macos-arm64_x86_64 ios-arm64 ios-arm64-simulator; do
  if [[ ! -d "$xcframework/$slice" ]]; then
    echo "error: $xcframework has no $slice slice" >&2
    exit 1
  fi
done
echo "built $xcframework ($(du -sh "$xcframework" | cut -f1))"
