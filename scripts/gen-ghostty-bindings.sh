#!/usr/bin/env bash
# Regenerates crates/ghostty-vt-sys/src/bindings.rs. Run after bumping vendor/ghostty.
set -euo pipefail
cd "$(dirname "$0")/.."

"${BINDGEN:-bindgen}" vendor/ghostty/include/ghostty/vt.h \
  --allowlist-type 'Ghostty.*' \
  --allowlist-function 'ghostty_.*' \
  --allowlist-var 'GHOSTTY_.*' \
  --with-derive-default \
  --use-core \
  --output crates/ghostty-vt-sys/src/bindings.rs \
  -- -Ivendor/ghostty/include "$@"
