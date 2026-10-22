#!/bin/sh
# Rebuilds the agent browser's page scripts (apple/App/Resources/AgentBrowser):
#   playwright-injected.js  Playwright's injected script and WebView input, from the pinned
#                           commit below (packages/injected, packages/isomorphic; Apache-2.0)
#   rrweb-record.js         rrweb's recorder (MIT), for session replay
#   rrweb-player.js/.css    rrweb-player (MIT), for the replay viewer
#   LICENSE-*.txt           their licences and Playwright's NOTICE
#
# Sources: apple/scripts/agent-browser/{package.json,package-lock.json,build.mjs,*.ts}.
# Everything runs in a scratch directory; only the built files are copied into the app.
#
# Usage: apple/scripts/build-agent-browser.sh [scratch-dir]
set -eu

PW_COMMIT=20a2087ea43412b90c172c88faef80786ee18b8b
# sha256 of `shasum -a 256` over the extracted Playwright sources, sorted by path.
PW_SOURCES_SHA=99629f1df40c01d281f4376f32d6f53abb0a0cd2af6c0736d4ac43b639ce7939

here=$(cd "$(dirname "$0")" && pwd)
src="$here/agent-browser"
out="$here/../App/Resources/AgentBrowser"
work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/agent-browser-build.XXXXXX")}

mkdir -p "$work/playwright"
cp "$src/package.json" "$src/build.mjs" "$src/injected.ts" "$src/record.ts" "$work/"
[ -f "$src/package-lock.json" ] && cp "$src/package-lock.json" "$work/"

curl -fsSL "https://codeload.github.com/microsoft/playwright/tar.gz/$PW_COMMIT" -o "$work/playwright.tgz"
tar -xzf "$work/playwright.tgz" -C "$work/playwright" --strip-components=1 \
  "playwright-$PW_COMMIT/LICENSE" "playwright-$PW_COMMIT/NOTICE" \
  "playwright-$PW_COMMIT/packages/injected/src" "playwright-$PW_COMMIT/packages/isomorphic" \
  "playwright-$PW_COMMIT/packages/protocol/src"
sum=$(cd "$work/playwright" && find packages LICENSE NOTICE -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
if [ "$sum" != "$PW_SOURCES_SHA" ]; then
  echo "Playwright sources at $PW_COMMIT do not match the pinned digest ($sum)" >&2
  exit 1
fi

cd "$work"
if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi
node build.mjs

rm -rf "$out"
mkdir -p "$out"
{
  echo "// Playwright injected script and WebView input, microsoft/playwright@$PW_COMMIT."
  echo "// Copyright (c) Microsoft Corporation. Apache License 2.0; see LICENSE-playwright.txt."
  cat out/playwright-injected.js
} > "$out/playwright-injected.js"
{
  echo "// @rrweb/record $(node -p "require('./node_modules/@rrweb/record/package.json').version"). MIT License; see LICENSE-rrweb.txt."
  cat out/rrweb-record.js
} > "$out/rrweb-record.js"
cp node_modules/rrweb-player/dist/rrweb-player.umd.min.cjs "$out/rrweb-player.js"
cp node_modules/rrweb-player/dist/style.min.css "$out/rrweb-player.css"
{
  cat playwright/LICENSE
  echo
  cat playwright/NOTICE
} > "$out/LICENSE-playwright.txt"
# The npm packages ship no licence file; it is the repository's, at the same release.
rrweb_version=$(node -p "require('./node_modules/@rrweb/record/package.json').version")
{
  echo "@rrweb/record, rrweb, rrweb-player $rrweb_version (https://github.com/rrweb-io/rrweb)"
  echo
  curl -fsSL "https://raw.githubusercontent.com/rrweb-io/rrweb/rrweb%40$rrweb_version/LICENSE"
} > "$out/LICENSE-rrweb.txt"
cp package-lock.json "$src/package-lock.json"
echo "Playwright sources digest: $sum"
du -sh "$out"
