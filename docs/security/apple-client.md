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
- Other addresses a host reports open only if they are web pages: a pull request's or CI
  check's page, an editor sign-in page. A tunnel's editor page must be on vscode.dev, and its
  desktop link must be a `vscode://vscode-remote/tunnel+…` link.
- A guest connection (someone else's host) never announces the browser capability. If such a
  host sends a browser request anyway, the Rust core drops it (it does the same for any
  connection that did not announce the capability), and so does the app.
- When a user clicks a terminal link from a host, a `file:` URL is not handed to the system.
  Links the in-app browser opens from a remote pane must be web pages.
- A host can never read the clipboard. A program can write it (OSC 52) only on the device
  that typed into its pane last; the item is local only (no Universal Clipboard), and a toast
  says "Copied from <pane>".
- A guest connection never offers to answer password prompts, and drops any a host sends;
  the owner's sheet says when a guest was driving the pane.
- Pages tied to a host (pages it opens, its agent's browser, its sign-ins, its dev servers)
  use that host's own persistent `WKWebsiteDataStore(forIdentifier:)`, never the store of the
  user's own browsing. Host A's pages cannot see host B's cookies or storage, or the user's
  sessions. Removing a host deletes its store.
- The VS Code web view hands only `vscode:`, `vscode-insiders:`, `mailto:` and `tel:` links to
  the system, and only from the main frame.
- A repository's own setup and teardown commands run only once the owner trusts them in the
  app ("Run Setup Commands for repo?", listing them).
- The Excalidraw canvas:
  - never navigates its page away from its bundled scheme, not even to a `data:` or `blob:`
    page (a shared drawing's link could otherwise replace it with a form);
  - opens clicked links in the system browser, and only web links;
  - accepts bridge messages only from its own main frame, so an embedded site in a shared scene
    cannot edit the drawing.

**Tooling hooks.** Test and tooling hooks (`-testTrustHostKeys`, `-testBundledDaemons`,
`-testTicket`, `-testTunnelWebBase`, `-screen`, `-typeOnStart`, `-seedAgent`, `-joinInvite`,
`-browserProxy`, …) are read from the launch arguments only, never from saved defaults. On the
Mac, `defaults write` could otherwise turn off host key checks for good, make the app install a
different daemon on every host, or type a command into a paired host's terminal at launch.

**SSH.**
- Host keys are trust-on-first-use, with the fingerprint shown. A changed key raises a "Host
  Key Changed" alert that warns about interception; the only way past it is a destructive
  "Replace Key".
- Agent forwarding is off unless the user's own `ssh_config` asks for it.
- Password fields are `SecureField`s.
- The terminal disables autocorrect, spell checking and inline prediction, so typed passwords
  are not learned by the keyboard.

**App Lock** (Settings › Privacy & Security on the Mac, App Lock on iPhone and iPad; off by
default). "Require Face ID" (Touch ID, Optic ID or the passcode, named after what the device
has) works like a password manager's or a bank's:
- LocalAuthentication's `.deviceOwnerAuthentication`: biometrics with the passcode (Mac: login
  password) as fallback, as Apple recommends. Turning it on or off asks too, so someone holding
  the unlocked app cannot quietly switch it off.
- The app opens locked, and locks again after it has been in the background (Mac: another app
  in front) for the grace period: Immediately, 1, 5 or 15 minutes (default 1). The time is
  measured on a clock that keeps running while the device sleeps.
- Locked, every window shows the app icon and Unlock (asked for once on its own each time the
  app comes back). It is a window of its own above each iPhone/iPad scene's windows and above
  each Mac window (sheets, popovers, tool windows, Settings included), so nothing behind it is
  visible or reachable, and the keyboard goes to it, never to a terminal.
- With App Lock on, an iPhone or iPad window that leaves the front is covered at once, so the
  app switcher's snapshot shows only the icon.
- Connections stay up while locked: agents keep working and notifications still arrive.
- If the device's passcode is removed, App Lock turns itself off (there is no owner left to
  check; removing the passcode needed it).

**Lock screen and notifications.**
- Approve and Deny need the device unlocked (`.authenticationRequired`).
- An approval whose summary had to be cut has no Approve: Open only, and the app shows it all.
- An approval's action token lasts 15 minutes (`push.action_ttl`), so a notification left on a
  lock screen cannot approve a request much later.
- Approval and blocked categories show a placeholder when previews are hidden.
- The push body is sealed end to end. The NSE shows it only for a daemon this device paired
  with, and takes the category from the sealed payload, not from the relay.

**Logs and debug output.**
- Rust core messages and user- or host-identifying fields (host names, device names, paths,
  invitee names) are logged `privacy: .private`.
- `Debug` output of the FFI types that carry a secret leaves it out: `ClientConfig` (device
  key), `ConnectOptions` (relay token; also in client-core), `GeneratedSshKey` (private key),
  `PushSealKey`, `PushActionOffer` (action token), `CreatedInvite` (link),
  `EditorInstance` (token) and `PushRegistration` (relay capabilities). In the wire types,
  `proto::Invite` leaves out its grant chain and `proto::EditorInstance` its token and URL.
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
- **With App Lock off** (the default), the app switcher snapshot shows terminal content and
  anyone holding the unlocked device can use the app.
- **App Lock is not a defence against local malware on the Mac.** The setting lives in the
  app's preferences, which a process running as the user can change; and the Mac's cover is a
  window above the app's own, not encryption.
- **Mac windows are not covered while another app is in front** within the grace period (the
  terminal stays readable beside other apps, as users expect). Mission Control shows them
  as they are.
- **The Mac app is not sandboxed.** A local process running as the user can read whatever the
  user can, including an ad-hoc build's secret files. A team-signed build keeps secrets in the
  Keychain, where another app's access triggers a prompt.
- **`*.localhost` is allowed over plain HTTP by ATS.** It is needed for dev servers through the
  host's proxy. A resolver that sends `*.localhost` off the machine would expose those loads.
- **Secrets cross into Swift as `Data`/`String`**, which Swift cannot zeroize. The Rust side
  zeroizes askpass secrets; device and SSH keys live as long as the connection does.
- **Links a user clicks in a host's terminal** open as the user's own browsing (as a
  terminal opening Safari would), in the app's default store with vscode.dev's sign-in.
- **Editor servers' stores** (per host and folder, for VS Code on the host) are not deleted
  when the host is removed; they hold only the server's connection token.
- **Saved preferences on the Mac.** Tooling hooks ignore saved defaults, but real preferences
  (themes, Git scripts, hosts to reopen) are still the user's files; a process running as the
  user can change them.

## Validation

Each test runs the attack against the real code and fails if the defence is removed (checked
by removing it).

- `AppTests/ClientExploitTests` (macOS; also on an iOS simulator):
  - `testNoFormOfLinkPairsOrJoins`: pairing links with odd casing, extra path segments,
    query/fragment, duplicated parameters, percent-encoding, control characters, 1 MiB of
    payload, `scheme:`/`scheme:///` forms, user info, `join` wrappers and `file:` URLs reach
    Add Host or Join at most (showing the ticket a tap would pair) and add no host.
  - `testAHostOpensWebPagesAndNothingElse`: `FILE:`, `file:///`, `x-apple.systempreferences:`,
    `shortcuts://`, our own links, the canvas scheme, `javascript:`, `data:`, `blob:`, `smb:`,
    `itms-services:` and host-less URLs are refused by `HostLinks`, `browser_navigate`, the
    tunnel page and its desktop link; IDN web pages open; vscode.dev look-alikes don't.
  - `testTheCanvasBridgeHearsOnlyItsOwnPage`: a frame inside the live canvas posts to the
    bridge and is ignored; the page navigating to a site, `data:` or `file:` stays put.
  - `testTheCanvasMainFrameStaysInItsBundle`.
  - `testTheEditorWebViewHandsOnlyItsSchemesToTheSystem`: the editor's navigation decision
    itself, for web pages, its schemes in the main frame and in a frame, and files, other
    apps' and this app's links.
  - `testAHostsCopyIsPlainTextNamedByItsPane` (macOS), `testTheRepositoryTrustAlertListsEveryCommand`.
  - `testToolingHooksAreNeverReadFromSavedDefaults`: scans the app's sources; every tooling
    hook and `test…` key is read through `LaunchArguments`.
  - `testKeychainItemsStayOnThisDevice`: the stored item is `AfterFirstUnlockThisDeviceOnly`
    and not synchronizable (skipped where the data-protection keychain is unusable: ad-hoc Mac
    builds).
  - `testCopiedInviteLinksAreConcealed` (macOS).
- `AppTests/LinkSecurityTests`: a pairing link shows Add Host; invites open Join.
- `HostKitTests`: `fileSecretsAreOwnerOnlyUnderAnOpenUmask` (umask 0, a folder made before),
  `fileSecretsMoveIntoTheKeychainAndLeaveNoFiles`.
- `client-core` `browser::tests`: a daemon pushing browser requests to a connection that did
  not announce the capability (or to a guest) reaches nothing.
- `apple-ffi` `debug_output_leaves_secrets_out`: every FFI type that carries a secret.
  `proto` `golden_trust_clipboard::debug_output_leaves_bearer_secrets_out`: `Invite` and
  `EditorInstance`.
- Manual: the hosted tests' unified log (`log stream`) holds none of the test tickets, invite
  links or secrets; the four `PrivacyInfo.xcprivacy` files pass `plutil -lint` and land in their
  bundles; the Rust core links no disk-space API.
