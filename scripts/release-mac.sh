#!/bin/bash
# Builds the Mac app for download outside the App Store: archives it signed with Developer ID,
# packs it in a signed DMG, notarizes and staples that, and lays out the release assets.
#
#   scripts/release-mac.sh
#
# Output in apple/build/release-mac/: the DMG, the static Linux helpers and SHA256SUMS, the
# files a GitHub release `v<version>` carries (site/download and site/install.sh link to them).
# SHA256SUMS also goes to site/releases/v<version>/ and site/releases/latest/ (with the version
# in VERSION): install.sh checks the GitHub download against the copy on the site.
# It also adds the release to site/appcast.xml, the Mac app's update feed (Sparkle), with the
# DMG's EdDSA signature; publishing the release and deploying the site stay manual.
#
# Needs the "Developer ID Application" identity of the team in the login Keychain and the App
# Store Connect API key there too (service `$ASC_KEYCHAIN_SERVICE`, the .p8 contents
# base64-encoded), which notarytool uses. The Mac build has no push, App Groups or Keychain
# groups, so it needs no provisioning profile. The EdDSA key that signs updates is in the login
# Keychain too (Sparkle's generate_keys put it there; its public half is SUPublicEDKey in
# apple/project.yml). SKIP_RUST=1 reuses the Rust builds already made. RELEASE_SUMMARY names a
# plain-text file of short notes, one change per line, shown in the app's update card. Codex and
# Claude Code, when installed, are launched to their start screen first to check they render as
# in Ghostty (scripts/agent-tui-parity.sh); SKIP_AGENT_TUI_PARITY=1 skips that.
set -euo pipefail

ASC_KEY_ID="${ASC_KEY_ID:-48K8RU3L66}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-94af5f6c-40ed-47cc-b397-8325e95761d3}"
ASC_KEYCHAIN_SERVICE="${ASC_KEYCHAIN_SERVICE:-unnamed.asc.$ASC_KEY_ID}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
apple_dir="$repo_root/apple"
brand_setting() { sed -n "s/^$1 = //p" "$apple_dir/Brand.xcconfig"; }
team_id="$(brand_setting BRAND_TEAM_ID)"
brand_name="$(brand_setting BRAND_NAME)"
daemon_bin="$(brand_setting BRAND_DAEMON_BIN)"
build_number="${BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
work_dir="$apple_dir/build/release-mac-work"
output_dir="$apple_dir/build/release-mac"
archive_path="$work_dir/$brand_name.xcarchive"
dmg="$output_dir/$brand_name.dmg"
appcast="$repo_root/site/appcast.xml"
github_repo="${GITHUB_REPO:-dzmbs/gudo}"
sparkle_bin="$work_dir/sparkle-bin"

fail() { echo "error: $*" >&2; exit 1; }

signing_identity="$(security find-identity -v -p codesigning \
  | awk -v team="($team_id)\"" 'index($0, "\"Developer ID Application:") && index($0, team) { print $2; exit }')"
[ -n "$signing_identity" ] || fail "no Developer ID Application identity for team $team_id in the Keychain"
security find-generic-password -s "$ASC_KEYCHAIN_SERVICE" >/dev/null 2>&1 \
  || fail "no App Store Connect API key in the Keychain (service $ASC_KEYCHAIN_SERVICE)"

if [ "${SKIP_RUST:-0}" != 1 ]; then
  (cd "$repo_root" && cargo xtask build-xcframework --macos-only)
  "$apple_dir/scripts/build-libghostty-vt.sh"
  (cd "$repo_root" && cargo xtask build-hostd-macos)
  (cd "$repo_root" && cargo xtask build-hostd-linux)
fi
[ -f "$apple_dir/build/hostd/macos/$daemon_bin" ] || fail "no Mac helper; run cargo xtask build-hostd-macos"
for arch in x86_64 aarch64; do
  [ -f "$apple_dir/build/hostd/$daemon_bin-$arch-linux.gz" ] || fail "no $arch Linux helper; run cargo xtask build-hostd-linux"
done

echo "==> coding agents render as in Ghostty"
if [ "${SKIP_AGENT_TUI_PARITY:-0}" != 1 ]; then
  "$repo_root/scripts/agent-tui-parity.sh"
fi
(cd "$apple_dir" && xcodegen generate --quiet)

rm -rf "$work_dir" "$output_dir"
mkdir -p "$work_dir" "$output_dir"
xcodebuild archive \
  -project "$apple_dir/App.xcodeproj" -scheme App -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive_path" \
  -derivedDataPath "$work_dir/DerivedData" ARCHS=arm64 \
  PUSH_ENTITLEMENT=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$team_id" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  CURRENT_PROJECT_VERSION="$build_number"

export_options="$work_dir/ExportOptions.plist"
cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$team_id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$archive_path" -exportPath "$work_dir/export" -exportOptionsPlist "$export_options"
ditto "$work_dir/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin" "$sparkle_bin"
rm -rf "$work_dir/DerivedData"
app="$work_dir/export/$brand_name.app"
[ -d "$app" ] || fail "export made no $brand_name.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
# Kept outside the work and output folders, which each release wipes: hang and crash reports
# from this build can only be read with these.
symbols_dir="$apple_dir/build/symbols/mac-$version-$build_number"
mkdir -p "$symbols_dir"
ditto "$archive_path/dSYMs" "$symbols_dir"
public_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")"
[ "$("$sparkle_bin/generate_keys" -p)" = "$public_key" ] \
  || fail "the Keychain's update signing key does not match the app's SUPublicEDKey"

echo "==> checking signatures"
codesign --verify --deep --strict --verbose=2 "$app"
entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
case "$entitlements" in
  *get-task-allow*) fail "the app has the get-task-allow entitlement (a debug signature)" ;;
esac
while IFS= read -r -d '' file; do
  kind="$(file -b "$file")"
  case "$kind" in Mach-O*) ;; *) continue ;; esac
  details="$(codesign -dvv "$file" 2>&1)" || fail "$file is not signed"
  grep -q "^Authority=Developer ID Application: .*($team_id)$" <<<"$details" \
    || fail "$file is not signed with the team's Developer ID"
  grep -q "^Timestamp=" <<<"$details" || fail "$file has no secure timestamp"
  case "$kind" in
    *executable*) grep -q "^CodeDirectory .*flags=.*runtime" <<<"$details" \
      || fail "$file lacks the hardened runtime" ;;
  esac
  echo "    signed: ${file#"$app/"}"
done < <(find "$app" -type f -print0)

echo "==> checking linked libraries resolve inside the app"
executable="$app/Contents/MacOS/$brand_name"
rpaths=()
while IFS= read -r rpath; do
  rpaths+=("${rpath/@executable_path/$app/Contents/MacOS}")
done < <(otool -l "$executable" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
while IFS= read -r library; do
  found=""
  for rpath in "${rpaths[@]}"; do
    [ -e "$rpath/${library#@rpath/}" ] && found=1
  done
  [ -n "$found" ] || fail "$library does not resolve from the app's run paths: ${rpaths[*]}"
  echo "    resolves: $library"
done < <(otool -L "$executable" | awk '$1 ~ /^@rpath\// { print $1 }')

echo "==> making $(basename "$dmg")"
staging="$work_dir/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/$brand_name.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "$brand_name" -srcfolder "$staging" -fs HFS+ -format ULFO -ov "$dmg"
codesign --sign "$signing_identity" --timestamp "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

echo "==> notarizing"
key_dir="$(mktemp -d)"
trap 'rm -rf "$key_dir"' EXIT
key_file="$key_dir/AuthKey_$ASC_KEY_ID.p8"
security find-generic-password -s "$ASC_KEYCHAIN_SERVICE" -w | base64 --decode > "$key_file"
chmod 600 "$key_file"
notary() { xcrun notarytool "$@" --key "$key_file" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"; }
result="$work_dir/notarization.plist"
notary submit "$dmg" --wait --output-format plist > "$result" || true
submission_id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
status="$(plutil -extract status raw "$result" 2>/dev/null || true)"
echo "    submission $submission_id: $status"
if [ "$status" != Accepted ]; then
  cat "$result" >&2
  [ -n "$submission_id" ] && notary log "$submission_id" >&2
  fail "notarization did not succeed"
fi
notary log "$submission_id" > "$work_dir/notarization-log.json"

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl -a -t open --context context:primary-signature -v "$dmg"
mount_point="$(mktemp -d)"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null
spctl -a -t exec -vv "$mount_point/$brand_name.app" || { hdiutil detach "$mount_point" >/dev/null; exit 1; }
hdiutil detach "$mount_point" >/dev/null
rmdir "$mount_point"

echo "==> update feed"
# The first run asks to let sign_update use the key: Always Allow.
ed_signature="$("$sparkle_bin/sign_update" -p "$dmg")" || fail "sign_update could not sign the DMG"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$app/Contents/Info.plist")"
python3 -I "$repo_root/scripts/appcast-item.py" "$appcast" \
  --title "Version $version" \
  --version "$build_number" --short-version "$version" \
  --minimum-system "$minimum_system" \
  --release-notes "https://github.com/$github_repo/releases/tag/v$version" \
  --url "https://github.com/$github_repo/releases/download/v$version/$(basename "$dmg")" \
  --length "$(stat -f %z "$dmg")" --signature "$ed_signature" \
  ${RELEASE_SUMMARY:+--description "$(cat "$RELEASE_SUMMARY")"}
echo "    ${appcast#"$repo_root/"}: $version ($build_number)"

echo "==> release assets"
for arch in x86_64 aarch64; do
  asset="$output_dir/$daemon_bin-$arch-unknown-linux-musl"
  gunzip -c "$apple_dir/build/hostd/$daemon_bin-$arch-linux.gz" > "$asset"
  chmod 755 "$asset"
done
(cd "$output_dir" && shasum -a 256 "$(basename "$dmg")" "$daemon_bin"-*-unknown-linux-musl > SHA256SUMS)
for published in "v$version" latest; do
  mkdir -p "$repo_root/site/releases/$published"
  cp "$output_dir/SHA256SUMS" "$repo_root/site/releases/$published/SHA256SUMS"
done
echo "$version" > "$repo_root/site/releases/latest/VERSION"
echo "    site/releases: v$version and latest; deploy the site with the release"
ls -l "$output_dir"
cat "$output_dir/SHA256SUMS"
echo "$brand_name $version ($build_number), notarization $submission_id"
echo "release tag: v$version"
