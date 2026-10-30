# Apple client (iOS, iPadOS, macOS)

The app in `apple/` with its extensions (Notification Service, Live Activity widget, File
Provider), the packages under `apple/Packages`, and the Rust core it links
(`crates/client-core`, `crates/apple-ffi`).

## What we protect

- **This device's key** (Ed25519, `device-key`). Every paired daemon knows the device by it.
  Whoever has it can connect to every host the device has paired with, as the owner.
- **Pairing tickets** (`host.<id>.ticket`). After pairing, a ticket only says how to dial the
  host. Its one-time secret is already spent.
- **SSH private keys, saved SSH passwords, askpass passwords** (the last kept behind Face ID or
  Touch ID), and the **relay token**.
- **The push sealing key** (`push-seal-key`, shared with the Notification Service Extension).
- **What is on screen**: terminal output, agent approvals, invite links. Invite links are
  bearer secrets.
- **This device itself**: its files, its other apps, and its browser sessions, as seen from a
  host. A Mac also runs local shells.

## Who attacks

1. **Another app or web page on the device.** It can open `unnamed://` links (`pair`, `join`,
   `open`, `inbox`) and hand the app `.unreplay` files.
2. **A phisher.** Sends a pairing link, QR code or invite that leads to *their* host.
3. **A malicious or compromised host.** This includes a guest's view of someone else's host.
   It controls terminal output (including OSC 8 links), pushes "open this URL" requests,
   drives the agent browser, and sends drawings and notification text.
4. **A local process on the Mac running as the same user.** The Mac app is not sandboxed. It
   can write the app's preferences and read files in its folders.
5. **Someone holding the locked device**: the lock screen, notifications, the app switcher.

## What we defend, and how

**Secrets at rest.**
- Everything above is stored in the data-protection Keychain (`KeychainStore`):
  - Accessibility is `AfterFirstUnlockThisDeviceOnly`, because reconnects and the extensions run
    in the background.
  - Items are never synchronizable, so they never go to iCloud and never move to another device.
- Askpass passwords use `WhenUnlockedThisDeviceOnly` plus `.userPresence`.
- Secure Enclave SSH keys never leave the enclave.
- The App Group container holds only:
  - the list of paired daemon ids, which the NSE uses to verify a push came from a paired daemon;
  - the hosts that the File Provider may show.
- Shared secrets (tickets, device key, seal key) go through the shared Keychain group only.

**Secrets in the Mac app.** A Developer ID build without a provisioning profile cannot use the
data-protection keychain. Before this pass it silently stored every secret in plain files.
Now:
- A team-signed build uses the login keychain instead. Its items are tied to the app's
  signature, so other apps trigger a system prompt.
- Only ad-hoc developer builds fall back to files (`0600` in a `0700` folder, enforced on every
  write).
- Secrets left in files by an older build move into the Keychain on launch.
- `docs/MAC-DISTRIBUTION.md` recommends a Developer ID provisioning profile, so release builds
  use the data-protection keychain.

**Links and codes from outside.** No link pairs or joins by itself.
- A pairing link, a pasted ticket and a scanned QR code all open the same Add Host sheet. It
  shows:
  - the host: its name if already paired, else "New host";
  - the start of its key, which matches `daemon id` in the host's `status` output;
  - the relay it will use;
  - for a link, a warning that the host will see what you type.
- Pairing happens only when the user taps Pair. Invites open the Join sheet, which shows the
  inviter and the role.
- Tickets and invites are parsed by the Rust core as strict, versioned base32 structures, never
  as shell text.
- `.unreplay` files are parsed as JSON. Session ids are UUIDs, keyframe names must match a
  fixed pattern, and imported sessions play offline in rrweb's script-less sandbox.

**A host is not trusted with this device** (the "remote-to-local" class: VS Code Remote-SSH
- A host may open only `http`/`https` pages, inside the in-app browser beside its pane. It can
  never open:
  - a `file:` URL, which its agent could then read through the browser tools;
  - another app's link;
  - our own pairing links.
- A guest connection (someone else's host) never announces the browser capability. If such a
  host sends a browser request anyway, the app drops it.
- When a user clicks a terminal link from a host, a `file:` URL is not handed to the system.
  Links the in-app browser opens from a remote pane must be web pages.
- There is no OSC 52: a host can neither read nor write the clipboard.
- The VS Code web view hands only `vscode:`, `vscode-insiders:`, `mailto:` and `tel:` links to
  the system, and only from the main frame.
- The Excalidraw canvas:
  - never navigates away from its bundled scheme;
  - opens clicked links in the system browser, and only web links;
  - accepts bridge messages only from its own main frame, so an embedded site in a shared scene
    cannot edit the drawing.

**Tooling hooks.** Test hooks (`-testTrustHostKeys`, `-testBundledDaemons`, `-testTicket`,
`-testTunnelWebBase`, …) are read from the launch arguments only, never from saved defaults.
On the Mac, `defaults write` could otherwise turn off host key checks for good, or make the
app install a different daemon on every host.

**SSH.**
- Host keys are trust-on-first-use, with the fingerprint shown. A changed key raises a "Host
  Key Changed" alert that warns about interception; the only way past it is a destructive
  "Replace Key".
- Agent forwarding is off unless the user's own `ssh_config` asks for it.
- Password fields are `SecureField`s.
- The terminal disables autocorrect, spell checking and inline prediction, so typed passwords
  are not learned by the keyboard.

**Lock screen and notifications.**
- Approve and Deny need the device unlocked (`.authenticationRequired`).
- Approval and blocked categories show a placeholder when previews are hidden.
- The push body is sealed end to end. The NSE shows it only for a daemon this device paired
  with, and takes the category from the sealed payload, not from the relay.

**Logs and debug output.**
- Rust core messages and user- or host-identifying fields (host names, device names, paths,
  invitee names) are logged `privacy: .private`.
- `Debug` output of `ClientConfig`, `ConnectOptions` (client-core and FFI) and
  `GeneratedSshKey` redacts the device key, the relay token and the private key.
- Askpass secrets in the core are zeroized (`proto::Secret`).

**Pasteboard.** Copied invite links expire from the iOS clipboard after 10 minutes. On the Mac
they carry the nspasteboard.org "concealed / transient" markers, so clipboard managers skip them.

**App Store.** The app and each extension ship a `PrivacyInfo.xcprivacy`: no tracking and no
collected data. Required-reason APIs are declared: UserDefaults `CA92.1`/`1C8F.1`, boot time
`35F9.1` (Rust's monotonic clock), and file timestamps `C617.1`/`3B52.1`.

**Mac hardening.**
- Hardened runtime, with one exception: microphone input.
- No `disable-library-validation`, no `allow-dyld-environment-variables`, no JIT.
- The bundled helper is signed the same way.
- The App Sandbox is off, because the app runs login shells.

## Residual risk

- **Notification text persists.** iOS keeps delivered notification text in its notification
  store, even after the app is deleted. The body is whatever the daemon writes. Keeping it to a
  short summary (never a full command, file contents or secrets) is the daemon's job; see
  docs/PUSH.md.
- **Pairing with a hostile host is still possible** if the user confirms. The sheet says "New
  host" and shows the key, but a user who doesn't read it can still pair. A paired host gets
  what the user types in its terminals and can show pages in the in-app browser beside its
  panes. It cannot reach the device's files, other apps or the clipboard.
- **The app switcher snapshot shows terminal content.** There is no privacy cover and no App
  Lock (Face ID to open the app). Both are product decisions.
- **The Mac app is not sandboxed.** A local process running as the user can read whatever the
  user can, including an ad-hoc build's secret files. A team-signed build keeps secrets in the
  Keychain, where another app's access triggers a prompt.
- **`*.localhost` is allowed over plain HTTP by ATS.** It is needed for dev servers through the
  host's proxy. A resolver that sends `*.localhost` off the machine would expose those loads.
- **Secrets cross into Swift as `Data`/`String`**, which Swift cannot zeroize. The Rust side
  zeroizes askpass secrets; device and SSH keys live as long as the connection does.
- **The in-app browser** (the agent browser and vscode.dev) uses the default website data
  store unless a page is given its own. A page a host opens can then see cookies from earlier
  browsing in the app.
