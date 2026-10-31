#!/usr/bin/env bash
# Writes the pinned Ghostty source with patches/ghostty/*.patch applied to DEST (replaced).
#
#   scripts/ghostty-source.sh DEST
#
# Every build of libghostty-vt compiles this tree, never vendor/ghostty itself: the submodule
# stays pristine, local edits in it cannot leak into a build, and every build path applies the
# same patches. Fails if a patch does not apply. Prints the version to pass to `zig build`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/vendor/ghostty"
dest="${1:?usage: ghostty-source.sh DEST}"

if [[ ! -f "$src/build.zig" ]]; then
  echo "error: vendor/ghostty is not checked out (git submodule update --init vendor/ghostty)" >&2
  exit 1
fi
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

rm -rf "$dest"
mkdir -p "$dest"
git -C "$src" archive --format=tar HEAD | tar -xf - -C "$dest"

# Zig unpacks dependencies into the build root; they are content-addressed, so the trees share
# one copy instead of hundreds of MB each.
mkdir -p "$src/zig-pkg"
ln -s "$src/zig-pkg" "$dest/zig-pkg"

patches=0
for patch in "$root"/patches/ghostty/*.patch; do
  [[ -e "$patch" ]] || continue
  # The ceiling keeps git from treating DEST as part of an enclosing repository.
  if ! (cd "$dest" && GIT_CEILING_DIRECTORIES="$(dirname "$dest")" git apply "$patch"); then
    echo "error: ${patch#"$root/"} does not apply to vendor/ghostty $(git -C "$src" rev-parse --short HEAD)" >&2
    exit 1
  fi
  patches=$((patches + 1))
done

# The tree has no git metadata for Ghostty's version detection, so name the version: the
# release plus how many local patches it carries.
version="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$dest/build.zig.zon" | head -n 1)"
if [[ -z "$version" ]]; then
  echo "error: no version in vendor/ghostty/build.zig.zon" >&2
  exit 1
fi
echo "$version+patches.$patches"
