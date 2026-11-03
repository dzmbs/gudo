#!/bin/bash
# Archives the iOS app, signs it for the App Store and uploads it to App Store Connect (TestFlight).
#
#   scripts/release-ios.sh            build the Rust core, archive, export, upload
#   scripts/release-ios.sh --no-upload  stop after the signed .ipa
#
# Needs the "Apple Distribution" identity in the login Keychain and the App Store Connect API key
# there too (service `$ASC_KEYCHAIN_SERVICE`, the .p8 contents base64-encoded). Signing is manual
# with App Store profiles the API creates, so no Xcode account sign-in is involved.
# SKIP_RUST=1 reuses the GudoCore xcframework already built. Codex and Claude Code, when
# installed, are launched to their start screen first to check they render as in Ghostty
# (scripts/agent-tui-parity.sh); SKIP_AGENT_TUI_PARITY=1 skips that.
set -euo pipefail

ASC_KEY_ID="${ASC_KEY_ID:-48K8RU3L66}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-94af5f6c-40ed-47cc-b397-8325e95761d3}"
ASC_KEYCHAIN_SERVICE="${ASC_KEYCHAIN_SERVICE:-unnamed.asc.$ASC_KEY_ID}"
export ASC_KEY_ID ASC_ISSUER_ID

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
apple_dir="$repo_root/apple"
brand_setting() { sed -n "s/^$1 = //p" "$apple_dir/Brand.xcconfig"; }
team_id="$(brand_setting BRAND_TEAM_ID)"
bundle_prefix="$(brand_setting BRAND_BUNDLE_ID_PREFIX)"
brand_name="$(brand_setting BRAND_NAME)"
build_number="${BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
output_dir="$apple_dir/build/release-ios"
archive_path="$output_dir/$brand_name.xcarchive"

upload=1
[ "${1:-}" = "--no-upload" ] && upload=0

api_key_base64() { security find-generic-password -s "$ASC_KEYCHAIN_SERVICE" -w; }

app_id="$bundle_prefix.app"
notifications_id="$bundle_prefix.app.notification-service"
agents_id="$bundle_prefix.app.agent-activity"
app_profile="$brand_name App Store"
notifications_profile="$brand_name Notifications App Store"
agents_profile="$brand_name Agents App Store"

api_key_base64 | node "$repo_root/scripts/asc-profiles.mjs" IOS_APP_STORE DISTRIBUTION \
  "$app_id=$app_profile" "$notifications_id=$notifications_profile" "$agents_id=$agents_profile"

if [ "${SKIP_RUST:-0}" != 1 ]; then
  (cd "$repo_root" && cargo xtask build-xcframework)
fi
echo "==> coding agents render as in Ghostty"
if [ "${SKIP_AGENT_TUI_PARITY:-0}" != 1 ]; then
  "$repo_root/scripts/agent-tui-parity.sh"
fi
(cd "$apple_dir" && xcodegen generate --quiet)

rm -rf "$output_dir"
mkdir -p "$output_dir"
xcodebuild archive \
  -project "$apple_dir/App.xcodeproj" -scheme App -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive_path" \
  PUSH_ENTITLEMENT=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" DEVELOPMENT_TEAM="$team_id" \
  RELEASE_PROFILE_APP="$app_profile" \
  RELEASE_PROFILE_NOTIFICATIONS="$notifications_profile" \
  RELEASE_PROFILE_AGENTS="$agents_profile" \
  CURRENT_PROJECT_VERSION="$build_number"

export_options="$output_dir/ExportOptions.plist"
cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$team_id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>provisioningProfiles</key>
  <dict>
    <key>$app_id</key><string>$app_profile</string>
    <key>$notifications_id</key><string>$notifications_profile</string>
    <key>$agents_id</key><string>$agents_profile</string>
  </dict>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$archive_path" -exportPath "$output_dir/export" -exportOptionsPlist "$export_options"
ipa="$(ls "$output_dir"/export/*.ipa)"
echo "signed build $build_number: $ipa"
[ "$upload" = 1 ] || exit 0

# altool reads the key from API_PRIVATE_KEYS_DIR; it lives there only for the upload.
key_dir="$(mktemp -d)"
trap 'rm -rf "$key_dir"' EXIT
api_key_base64 | base64 --decode > "$key_dir/AuthKey_$ASC_KEY_ID.p8"
chmod 600 "$key_dir/AuthKey_$ASC_KEY_ID.p8"
API_PRIVATE_KEYS_DIR="$key_dir" xcrun altool --upload-app --type ios --file "$ipa" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "uploaded build $build_number"
