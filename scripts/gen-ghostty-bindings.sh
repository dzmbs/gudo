#!/usr/bin/env bash
# Regenerates crates/ghostty-vt-sys/src/bindings.rs from the patched headers (vendor/ghostty
# plus patches/ghostty). Run after bumping vendor/ghostty or changing a patch's headers.
set -euo pipefail
cd "$(dirname "$0")/.."

source_dir="$(mktemp -d)"
trap 'rm -rf "$source_dir"' EXIT
scripts/ghostty-source.sh "$source_dir/ghostty" >/dev/null

"${BINDGEN:-bindgen}" "$source_dir/ghostty/include/ghostty/vt.h" \
  --allowlist-type 'Ghostty.*' \
  --allowlist-function 'ghostty_.*' \
  --allowlist-var 'GHOSTTY_.*' \
  --with-derive-default \
  --use-core \
  --clang-macro-fallback \
  --output crates/ghostty-vt-sys/src/bindings.rs \
  -- -I"$source_dir/ghostty/include" "$@"
