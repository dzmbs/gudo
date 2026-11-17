#!/usr/bin/env bash
# Updates every released helper (v0.1.3 and later) to this build, the ways the app does, and
# checks nothing is lost: same daemon id and pairing, the same panes,
# layout and scrollback, agents tracked with their Chat sessions, the new build serving, and a
# client built from the release still connecting.
#
#   scripts/upgrade-matrix.sh [TAG...]
#
# Each release's gudo-hostd and client are built once from `git archive` of the tag and kept in
# target/upgrade-matrix/<tag>/ (the sources and build directory are removed afterwards). The
# checks are the `a_release_*` tests in crates/hostd/tests/hot_upgrade.rs, run once per release.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="$root/target/upgrade-matrix"
jobs="${UPGRADE_MATRIX_JOBS:-4}"
export PATH="$HOME/.cargo/bin:$PATH"

say() { printf '==> %s\n' "$*" >&2; }

# From v0.1.3, the last release before hot hand-off, which updates by restarting cold.
oldest="${UPGRADE_MATRIX_OLDEST:-v0.1.3}"
tags=("$@")
if [[ ${#tags[@]} -eq 0 ]]; then
  while read -r tag; do
    tags+=("$tag")
  done < <(git -C "$root" tag --list 'v*' --sort=version:refname | sed -n "/^$oldest\$/,\$p")
fi
[[ ${#tags[@]} -gt 0 ]] || { echo "no releases to update from" >&2; exit 1; }

# Puts `built` at `out/name` as a new file renamed over the old one.
keep() {
  local built="$1" out="$2" name="$3"
  mkdir -p "$out"
  cp "$built" "$out/.$name.new"
  mv -f "$out/.$name.new" "$out/$name"
}

# Builds the helper in `source` into `target`, stamped as `build` from `stamp`, kept in `out`.
# Every tree builds in a target directory of its own: cargo names a workspace's own crates by
# their path inside it, so two trees would overwrite each other's.
build_helper() {
  local source="$1" target="$2" out="$3" build="$4" stamp="$5"
  (cd "$source" && CARGO_TARGET_DIR="$target" GUDO_BUILD_ID="$build" GUDO_BUILD_UNIX="$stamp" \
    nice -n 10 cargo build -q -j "$jobs" -p hostd --bin gudo-hostd)
  keep "$target/debug/gudo-hostd" "$out" gudo-hostd
}

release() {
  local tag="$1" out="$cache/$1"
  if [[ -x "$out/gudo-hostd" && -x "$out/release_client" ]]; then
    return
  fi
  say "building $tag"
  local source="$cache/src/$tag" target="$cache/build/$tag"
  rm -rf "$source"
  mkdir -p "$source"
  git -C "$root" archive "$tag" | tar -x -C "$source"
  local ghostty
  ghostty="$(git -C "$root" ls-tree "$tag" vendor/ghostty | awk '{ print $3 }')"
  rm -rf "$source/vendor/ghostty"
  git clone -q --shared --no-checkout "$root/vendor/ghostty" "$source/vendor/ghostty"
  git -C "$source/vendor/ghostty" checkout -q "$ghostty"
  # Zig's content-addressed package cache, shared rather than fetched again.
  mkdir -p "$root/vendor/ghostty/zig-pkg"
  ln -s "$root/vendor/ghostty/zig-pkg" "$source/vendor/ghostty/zig-pkg"
  build_helper "$source" "$target" "$out" "$(git -C "$root" rev-parse --short=12 "$tag^{commit}")" \
    "$(git -C "$root" log -1 --format=%ct "$tag")"
  mkdir -p "$source/crates/client-core/examples"
  cp "$root/scripts/upgrade-matrix/release_client.rs" "$source/crates/client-core/examples/"
  (cd "$source" && CARGO_TARGET_DIR="$target" \
    nice -n 10 cargo build -q -j "$jobs" -p client-core --example release_client)
  keep "$target/debug/examples/release_client" "$out" release_client
  rm -rf "$source" "$target"
}

for tag in "${tags[@]}"; do
  release "$tag"
done

say "building this tree"
build_helper "$root" "$cache/build/current" "$cache/current" \
  "$(git -C "$root" rev-parse --short=12 HEAD)-matrix" "$(date +%s)"

failed=()
for tag in "${tags[@]}"; do
  say "updating from $tag"
  checks=(a_release_)
  # Releases that hand their panes on also keep the agents' processes.
  if git -C "$root" cat-file -e "$tag:crates/daemon/src/handoff.rs" 2>/dev/null; then
    checks+=(an_app_update_keeps_chat_for_a_claude an_app_update_keeps_codex)
  fi
  if GUDO_TEST_UPGRADE_FROM="$cache/$tag/gudo-hostd" \
    GUDO_TEST_UPGRADE_TO="$cache/current/gudo-hostd" \
    GUDO_TEST_RELEASE_CLIENT="$cache/$tag/release_client" \
    nice -n 10 cargo test -q -j "$jobs" -p hostd --test hot_upgrade -- "${checks[@]}" \
      --test-threads 2; then
    say "$tag: ok"
  else
    say "$tag: FAILED"
    failed+=("$tag")
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "updating from ${failed[*]} failed" >&2
  exit 1
fi
say "every release (${tags[*]}) updates to this build"
