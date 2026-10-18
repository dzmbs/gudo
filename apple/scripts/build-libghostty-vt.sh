#!/usr/bin/env bash
# Builds the static libghostty-vt.a (host macOS slice) that TerminalKit's CGhosttyVt target links.
#
# Output: apple/build/ghostty-vt/lib/libghostty-vt.a (+ include/ copied by zig).
#
# Requires Zig 0.16.x (Ghostty pins major.minor). Works with only the Command Line Tools: the dylib
# step may fail to link under CLT, but the static archive is installed first, so a non-zero exit is
# accepted as long as libghostty-vt.a exists.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ghostty="$repo_root/vendor/ghostty"
prefix="${GHOSTTY_VT_PREFIX:-$repo_root/apple/build/ghostty-vt}"
optimize="${GHOSTTY_VT_OPTIMIZE:-ReleaseFast}"
zig="${ZIG:-zig}"

if [[ ! -f "$ghostty/build.zig" ]]; then
  git -C "$repo_root" submodule update --init vendor/ghostty
fi

zig_version="$("$zig" version)"
if [[ "$zig_version" != 0.16.* ]]; then
  echo "error: Zig 0.16.x required, found $zig_version" >&2
  exit 1
fi

rm -rf "$prefix"
set +e
(cd "$ghostty" && "$zig" build \
  -Demit-lib-vt \
  -Demit-xcframework=false \
  -Doptimize="$optimize" \
  --prefix "$prefix")
status=$?
set -e

archive="$prefix/lib/libghostty-vt.a"
if [[ ! -f "$archive" ]]; then
  echo "error: zig build exited $status and produced no $archive" >&2
  exit 1
fi
if [[ $status -ne 0 ]]; then
  echo "warning: zig build exited $status (expected under CLT: dylib link); static archive is present" >&2
fi

# SwiftPM must link the static archive, never a dylib sitting next to it.
find "$prefix/lib" -maxdepth 1 \( -name '*.dylib' -o -name '*.so*' \) -delete
echo "built $archive ($(du -h "$archive" | cut -f1))"
