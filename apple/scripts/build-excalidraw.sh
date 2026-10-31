#!/bin/sh
# Rebuilds the offline Excalidraw bundle the app embeds (apple/App/Resources/Excalidraw):
# the draw overlay on terminal panes and the canvas pane (docs/DAEMON.md §7.11).
#
# Sources: apple/scripts/excalidraw/{entry.jsx,index.html,boot.js,package.json,package-lock.json}.
# npm runs in a scratch directory; only the built files are copied into the app:
#   index.html, boot.js, canvas.js, canvas.css, fonts/ (Excalidraw's, without the 12 MB
#   Xiaolai CJK face: CJK text falls back to the system font), LICENSE-excalidraw.txt.
#
# Usage: apple/scripts/build-excalidraw.sh [scratch-dir]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src="$here/excalidraw"
out="$here/../App/Resources/Excalidraw"
work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/excalidraw-build.XXXXXX")}

mkdir -p "$work"
cp "$src/package.json" "$src/entry.jsx" "$src/no-mermaid.js" "$work/"
[ -f "$src/package-lock.json" ] && cp "$src/package-lock.json" "$work/"
cd "$work"
if [ -f package-lock.json ]; then npm ci --ignore-scripts --no-audit --no-fund; else npm install --ignore-scripts --no-audit --no-fund; fi

pkg="$work/node_modules/@excalidraw/excalidraw"
node_modules/.bin/esbuild entry.jsx \
  --bundle --minify --format=iife --target=safari18 \
  --jsx=automatic --loader:.js=jsx --conditions=production \
  --define:process.env.NODE_ENV='"production"' \
  --define:import.meta.env='{"MODE":"production","PROD":true,"DEV":false}' \
  --external:'*.woff2' --alias:@excalidraw/mermaid-to-excalidraw=./no-mermaid.js --legal-comments=none \
  --outfile=build/canvas.js

rm -rf "$out"
mkdir -p "$out/fonts"
cp build/canvas.js "$out/canvas.js"
cp build/canvas.css "$out/canvas.css"
cp "$src/index.html" "$src/boot.js" "$out/"
for face in "$pkg"/dist/prod/fonts/*; do
  case "$(basename "$face")" in Xiaolai) continue ;; esac
  cp -R "$face" "$out/fonts/"
done
{
  echo "@excalidraw/excalidraw $(node -p "require('$pkg/package.json').version") — MIT License"
  echo
  curl -fsSL "https://raw.githubusercontent.com/excalidraw/excalidraw/master/LICENSE" 2>/dev/null ||
    echo "MIT License. Copyright (c) 2020 Excalidraw. See https://github.com/excalidraw/excalidraw/blob/master/LICENSE"
  echo
  echo "Fonts (fonts/): Excalifont, Virgil, Lilita One, Nunito, Comic Shanns, Cascadia Code, Liberation Sans,"
  echo "Assistant — SIL Open Font License 1.1 / Apache 2.0 as published by their authors (see Excalidraw's"
  echo "packages/excalidraw/fonts). React and react-dom — MIT License, Copyright (c) Meta Platforms, Inc."
} > "$out/LICENSE-excalidraw.txt"
cp package-lock.json "$src/package-lock.json"
du -sh "$out"
