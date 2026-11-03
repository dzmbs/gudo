# Mac distribution: signing and notarization

The Mac app ships outside the App Store as a Developer ID build. Gatekeeper opens it only if
it is signed with a Developer ID certificate, runs with the hardened runtime, and is
notarized by Apple. This page lists what the project already does, then the steps for a
release. These steps need a paid Apple Developer account. No credentials are kept in the
repository.

## What the project does

| | Where |
|---|---|
| Hardened runtime for the app (`ENABLE_HARDENED_RUNTIME: YES`) | `apple/project.yml` |
| The only runtime exception: the microphone, for dictation (`ENABLE_RESOURCE_ACCESS_AUDIO_INPUT`, which becomes `com.apple.security.device.audio-input`) | `apple/project.yml` |
| No App Sandbox: the app runs login shells on local PTYs | `apple/project.yml` |
| The bundled helper (`Contents/MacOS/<brand>-hostd`) is signed with the app's identity, with `--options runtime` and a secure timestamp. Its identifier is `<bundle id>.hostd` | "This Mac Helper" build phase |
| The helper's LaunchAgent (`Contents/Library/LaunchAgents/<bundle id>.hostd.plist`, `BundleProgram`), registered with `SMAppService` | same phase, `LocalHelper.swift` |

When Xcode signs with "Sign to Run Locally" (ad-hoc), it turns the hardened runtime off,
because library validation would reject Debug's `*.debug.dylib`. The hardened runtime
takes effect once a real identity signs the build. To try a hardened build locally without
one, build Debug with `ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO`, then sign it again
ad-hoc with `--options runtime`: the helper first, then the app with its `.xcent`
entitlements. The dogfood scenarios `core` and `this-mac -- -localHelper YES` pass on a
build made that way.

Debug builds also get `com.apple.security.get-task-allow`. Release builds don't, and
notarization refuses any build that has it.

`SMAppService` ties the helper's launch to the code it registered. With a Developer ID,
that constraint follows the team, so updates keep the login item. Ad-hoc builds change
their hash with every build.

After an app update the running helper is still the old build, its file replaced inside the
new bundle. On the next launch the app runs the new bundled helper's `restart`
(`LocalHelper.restartInPlace`): the running helper checks the new file (`build-info`), hands
its sessions over and `exec`s it at the same path (docs/DAEMON.md "Hot upgrade"). `exec` keeps
the pid, so launchd's job (`KeepAlive`, `BundleProgram`) still owns the process and nothing
is spawned, so the registered code is not consulted; the sessions keep running. The login
item is not registered again then (that would stop the job); the app registers it again the
next time it finds the helper not running. A helper from before this, or a new build that
cannot take the sessions over, is replaced as before: unregister (stopping it), register,
start. The exec-in-place path never writes into the bundle: an upgrade streamed over the
connection stays refused for a helper inside an app bundle, because rewriting the file would
break the app's signature.

### Where the Mac app keeps secrets

The device key, pairing tickets, SSH keys and saved passwords go to the Keychain
(`SecretStores.appDefault`, HostKit):

1. The data-protection keychain, the same as on iOS. A Mac app may use it only when it has an
   `application-identifier` entitlement, which comes from a provisioning profile. A Developer
   ID build gets one through a "Developer ID" provisioning profile with a `keychain-access-groups`
   entitlement. This is the preferred setup for a release.
2. Without a profile but signed by a team (Developer ID), the login keychain. Its items are
   tied to the app's signature, so another app that asks makes macOS prompt the user.
3. An ad-hoc build only (each build has a new signature, so the login keychain would prompt on
   every launch): owner-only files (`0600` in a `0700` folder) in Application Support.

Secrets a previous build left in those files move into the Keychain on the next launch of a
build that can use it.

## Before a release

1. Build the Rust parts: `cargo xtask build-xcframework`, `cargo xtask build-hostd-macos`
   and `cargo xtask build-hostd-linux` (the Linux daemons that "Install helper" uploads).
   `build-hostd-macos` builds `aarch64-apple-darwin` only. For an Intel slice, build
   `x86_64-apple-darwin` too and `lipo` the two, or limit the app to `ARCHS = arm64`.
2. Check the supply chain on the commit you release (docs/security/supply-chain.md):
   `git submodule status` shows `vendor/ghostty` at the pinned tag with no `+`, `cargo deny
   check` passes, and the build starts from a clean checkout so every binary comes from this
   source.
3. Make a "Developer ID Application" certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage
   Certificates) and note the team ID.

## Archive and export

```sh
cd apple && xcodegen
xcodebuild -project App.xcodeproj -scheme App -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/release/App.xcarchive \
  DEVELOPMENT_TEAM=<TEAMID> CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  archive
```

`build/release/ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>TEAMID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
```

```sh
xcodebuild -exportArchive -archivePath build/release/App.xcarchive \
  -exportOptionsPlist build/release/ExportOptions.plist -exportPath build/release/export
```

## Check the signature

```sh
app=build/release/export/gudo.app
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --entitlements - "$app"                       # flags=0x10000(runtime), TeamIdentifier set, no get-task-allow
codesign -dv "$app/Contents/MacOS/gudo-hostd"           # runtime, same team, identifier <bundle id>.hostd
```

The entitlements must hold no `com.apple.security.cs.*` exception (JIT, unsigned executable
memory, dyld environment variables, disabled library validation): each one lets injected code
run inside the hardened app.

```sh
codesign -d --entitlements - --xml "$app" | grep -c 'com.apple.security.cs\.'   # 0
```

The helper must carry the same team and the runtime flag. If an export signed the app again
but left the helper as it was, sign the helper with the Developer ID first, then the app:

```sh
codesign --force --sign "Developer ID Application" --options runtime --timestamp \
  --identifier dev.gudo.app.hostd "$app/Contents/MacOS/gudo-hostd"
codesign --force --sign "Developer ID Application" --options runtime --timestamp \
  --entitlements <(codesign -d --entitlements - --xml "$app" 2>/dev/null) "$app"
```

## Notarize and staple

Store the credentials in the keychain once, with an app-specific password from
appleid.apple.com, or with an App Store Connect API key (`--key`, `--key-id`, `--issuer`):

```sh
xcrun notarytool store-credentials gudo-notary --apple-id <apple id> --team-id <TEAMID>
```

Then for each release:

```sh
ditto -c -k --keepParent "$app" build/release/Gudo.zip
xcrun notarytool submit build/release/Gudo.zip --keychain-profile gudo-notary --wait
xcrun notarytool log <submission id> --keychain-profile gudo-notary   # when it says Invalid
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"            # accepted, source=Notarized Developer ID
```

For a disk image: put the stapled app in the image, sign it
(`codesign --sign "Developer ID Application" --timestamp Gudo.dmg`), submit it the same
way, then `xcrun stapler staple Gudo.dmg`.

## After installing

Open the app from `/Applications` on a Mac that has never run it. Then check four things:
Gatekeeper opens it without a warning; Settings ▸ This Mac shows the helper running;
System Settings ▸ General ▸ Login Items lists it; and the helper still runs after the app
quits (`launchctl print gui/$UID/<bundle id>.hostd` shows `state = running`).
