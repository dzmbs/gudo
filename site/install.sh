#!/bin/sh
# Installs gudo-hostd, the Gudo host program, for the current user.
#
#   curl -fsSL https://gudo.dev/install.sh | sh
#
# It downloads the static binary for this CPU from the GitHub release, checks it against the
# release's SHA256SUMS, and puts it in ~/.local/bin with a short `gudo` link to it. No sudo,
# nothing else is changed.
#
#   GUDO_VERSION=0.1.0       install that release instead of the latest
#   GUDO_INSTALL_DIR=DIR     install somewhere else (default ~/.local/bin)
#
# Source: https://github.com/dzmbs/gudo (Apache-2.0)

set -eu

REPO="https://github.com/dzmbs/gudo"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -q -O "$2" "$1"
  else
    fail "curl or wget is needed"
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | sed 's/.*= //'
  else
    fail "sha256sum, shasum or openssl is needed to check the download"
  fi
}

main() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Linux) ;;
    Darwin)
      say "On a Mac, the Gudo app includes the host. Get it at https://gudo.dev/download/"
      exit 0 ;;
    *) fail "gudo-hostd runs on Linux and macOS, not $os" ;;
  esac
  case "$arch" in
    x86_64 | amd64) target="x86_64-unknown-linux-musl" ;;
    aarch64 | arm64) target="aarch64-unknown-linux-musl" ;;
    *) fail "no build for $arch yet (x86_64 and arm64 are available)" ;;
  esac

  if [ -n "${GUDO_VERSION:-}" ]; then
    base="$REPO/releases/download/v${GUDO_VERSION#v}"
  else
    base="$REPO/releases/latest/download"
  fi
  dir="${GUDO_INSTALL_DIR:-$HOME/.local/bin}"
  file="gudo-hostd-$target"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM

  say "Downloading $file"
  fetch "$base/$file" "$tmp/$file"
  fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"

  want=$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
  [ -n "$want" ] || fail "$file is not listed in SHA256SUMS"
  got=$(sha256 "$tmp/$file")
  [ "$want" = "$got" ] || fail "checksum mismatch for $file (expected $want, got $got)"
  say "Checksum OK"

  mkdir -p "$dir"
  chmod 755 "$tmp/$file"
  mv -f "$tmp/$file" "$dir/gudo-hostd"
  say "Installed $dir/gudo-hostd"
  "$dir/gudo-hostd" build-info 2>/dev/null || true

  # `gudo` is the same program under its short name: `gudo pair`, `gudo devices`.
  if [ ! -e "$dir/gudo" ] || [ -L "$dir/gudo" ]; then
    ln -sf gudo-hostd "$dir/gudo"
    gudo="gudo"
  else
    say "Kept the existing $dir/gudo; use gudo-hostd for the commands below."
    gudo="gudo-hostd"
  fi

  case ":$PATH:" in
    *":$dir:"*) bin="gudo-hostd" ;;
    *)
      bin="$dir/gudo-hostd"
      gudo="$dir/$gudo"
      say ""
      say "$dir is not on your PATH. Add it in your shell profile:"
      say "  export PATH=\"$dir:\$PATH\"" ;;
  esac

  say ""
  say "Next:"
  say "  $bin service install    # run it in the background (systemd --user)"
  say "  $gudo pair               # show a QR code to pair the Gudo app"
  say "  $gudo devices            # see, rename or remove paired devices"
  say ""
  say "To keep it running after you log out: sudo loginctl enable-linger \$USER"
}

main "$@"
