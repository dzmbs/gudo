
Status: 2026-10-18. The Apple app talks to real hosts: paired daemons over iroh and plain SSH,
with "just ssh" → "Install helper" → daemon. This document is the contract between the data
layer (`apple/Packages/HostKit`, the `Workspace`/`Pane` glue in `apple/App`) and the views. The
views in `App/Sources/Views/HostsView.swift` and `HostChrome.swift` are deliberately plain; the
design layer replaces them by binding to the same models.

```
                 ┌──────────── App (SwiftUI) ───────────────────────────────────────────┐
 views ────────▶ │ WindowRoot ─ target (.local | .host(id)) ─▶ AppModel.workspace(for:)  │
                 │ Workspace (layout + Pane per leaf)   Pane (Terminal, surface, view)   │
                 └───────────────┬───────────────────────────────┬───────────────────────┘
                                 │ LayoutStore                   │ PaneBackend / PredictionFeed
                 ┌───────────────▼───────── HostKit ─────────────▼───────────────────────┐
                 │ HostsModel ─ records (hosts.json) · secrets (Keychain) · KeyStore       │
                 │   connections[id]: HostConnection                                      │
                 │     DaemonConnection ─ DaemonLayoutStore · PaneRouter · DaemonPaneBackend│
                 │     SshConnection    ─ LocalLayoutStore  · SshPaneBackend               │
                 │ JustSSHFlow · PairingTicket · HostKeyPrompts · NetworkMonitor · CoreLog │
                 └───────────────────────────────┬────────────────────────────────────────┘
                                                 │ UniFFI (UnnamedCore: DaemonClient, SshSession, SshPane)
```

## 1. Models the views bind to

All are `@MainActor @Observable`. Views never hold a socket or a `DaemonClient` (04 R7).

| Model | What a view reads | What a view calls |
|---|---|---|
| `AppModel` (App) | `hosts`, `lastError` | `workspace(for:)` (resolve on target change, never in `body`), `handle(url:)` |
| `HostsModel` | `entries: [HostEntry]` (sorted: Needs you → pinned → recent), `installs[id]` (`InstallProgress.summary`), `installNotes[id]`, `sshConfigAliases`, `keys.keys`, `hostKeyPrompts.pending`, `network.isOffline` | `open(id)`, `pair(ticket, name:)`, `connectSSH(…)`, `installHelper(id)`, `loadSSHConfig(text)` / `loadUserSSHConfig()` (macOS) / `importSSHHosts(aliases)`, `rename`, `setPinned`, `disconnect`, `remove`, `foreground()/background()/networkChanged()` |
| `HostEntry` (value) | `name`, `kind` (`.daemon`/`.ssh`), `address`, `status: ConnectionStatus`, `needsYou: String?`, `blockedAgents`, `canInstallHelper`, `pinned`, `lastConnected` | — |
| `ConnectionStatus` (value) | `.idle/.connecting/.connected(rtt)/.reconnecting(attempt, reason)/.offline/.suspended/.needsAttention(reason)`; `summary` (words, A22), `isLive`, `needsUser` | — |
| `any HostConnection` (`Workspace.host`) | `status`, `isReady` | `retry()` (R9) |
| `DaemonConnection` | `blockedAgents`, `meta[pane]` (title, cwd, agent), `echoRoundTrip`, `timings` | `decide(requestId:optionId:)` |
| `Pane` (App) | `connection: PaneConnection` (`.live` / `.stale(reason)`), `title`, `workingDirectory`, `foregroundProgram` | — |
| `JustSSHFlow` | `destination`, `auth`, `password`, `rememberPassword`, `step`, `newKey` (`publicKey`, `authorizeCommand`, `sshCopyIdCommand(for:)`) | `endpoint()`, `generateKey()`, `generateSecureEnclaveKey()`, `importKey(pem:passphrase:label:)`, `connect()`, `authorizeOverSession(hostId:key:)` |
| `HostKeyPrompts` | `pending: Prompt?` (`host`, `algorithm`, `fingerprint`, `expected` for a changed key) | `answer(Bool)` |
| `PairingTicket` | `info` (`daemonId`, `addrs`, `relayUrl`, `expiresUnixMs`), `isExpired`, `defaultName` | `init(_ text)`, `init?(url:)` (deep link), QR payloads as text |

Mock data for previews: build `HostEntry` values directly; `HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: tmp))` gives a working empty model.

## 2. Panes: `PaneBackend` and `PaneEvent`

`PaneBackend` (HostKit, public) keeps the original byte-stream shape (`start(onOutput:onExit:)`,
`write`, `resize`, `terminate`) and adds `start(events:)`, `paste(_:)` and `requestHistory()`, each
with a default, so local backends (`LocalPTYBackend`, `EchoBackend`) are unchanged. A `Pane`
always calls `start(events:)` and handles, on the delivering thread:

| `PaneEvent` | Pane does |
|---|---|
| `.output(Data)` | `terminal.write`, `surface.outputArrived()` |
| `.snapshot(Data)` | `terminal.restore(snapshot:)` (TerminalCore, READY section) — never blanks: on failure the old screen stays |
| `.history(Data, done)` | `terminal.appendHistory(_:)` (prepends scrollback pages) |
| `.resized(cols, rows)` | resizes the VT at that point of the stream (the remote PTY's size) |
| `.connection(.live / .stale(reason))` | `Pane.connection` → `StalePaneOverlay` dims the pane |
| `.exited` | closes the pane (local PTY, SSH shell exit) |

Scrolling to the top (`TerminalSurface.onScroll` with `scrollbar.offset == 0`) calls
`requestHistory()`; the daemon backend fetches 256 KiB pages.

Echo prediction: `DaemonPaneBackend` implements TerminalKit's `PredictionFeed` (moved to
HostKit, public): `.hint` from the daemon's `EchoHint` (ECHO/ICANON/alt screen/at-prompt;
`nil` while stale), `.rtt` (smoothed input→`InputAck`), and `.acknowledged(upTo:)` mapped from
the daemon's per-input `InputAck`s to the predictor's sequence numbers; an ack is delivered after
the output past its `at_seq` (the echo), or after 40 ms if the input printed nothing. The daemon
does not report the foreground program yet, so `ForegroundProgramReporting` is not implemented
(the title stands in).

## 3. Connections and lifecycle (04 R1–R12)

| Rule | Where |
|---|---|
| R1 keepalive + probe on foreground | SSH: `SshSession` keepalives (15 s × 3); `HostsModel.foreground()` → `SshSession.setForeground(true)` (probe) and `DaemonClient.reconnect()` for daemons not live |
| R2 "connected" = answered recently | `ConnectionStatus` comes from client-core / ssh session states, never a socket flag |
| R3/R5 suspend → resume | iOS `scenePhase == .background` → `DaemonClient.suspend()` (resume state kept), `.active` → `reconnect()`; panes resume from the ring or a snapshot |
| R7 stable handle | `HostConnection` per host id; transports swap underneath; `Workspace` holds the connection, views hold ids |
| R8 status from the input path | status is derived from the `DaemonClient`/`SshSession` that also sends input |
| R9 retry everywhere | `ConnectionBanner` (Retry), host row menu (Retry) |
| R10 budgets reset | `NetworkMonitor` (NWPathMonitor, debounced 300 ms) → `networkChanged()`; foreground; Retry |
| R11 end-to-end check | `DaemonIntegrationTests`, `DaemonUITests` type a marker and assert it comes back |
| R12 output independent of views | `PaneRouter` buffers per pane until the view starts; VT lives in `Pane`, not the view; stale panes keep their content |

Threading: `ClientEvent`s arrive on the Rust runtime thread. Pane-stream events (bytes,
snapshots, resizes, history, acks, hints, connection state) are routed directly to the pane's
handler on that thread, in order (no main-actor hop on the keystroke path); everything else
(layout, meta, status) goes through one `AsyncStream` to the main actor, in order.

Layout: `DaemonLayoutStore` (a `LayoutStore`) applies `LayoutChanged` by revision (reset when
the daemon's epoch changes) and sends every op to the daemon. Focus/ratio/zoom/tab-move/rename
ops are also applied locally at once (the daemon's answer replaces them; a failed op reverts);
split/close/new tab wait for the daemon, which allocates ids. `Workspace` follows the store with
observation tracking, so splits made by other clients appear too. `setView(focused, visible)`
is pushed on every layout change (stream priorities).

## 4. Pairing, secrets, persistence

- Device key: `DeviceIdentity.load` — generated once (`generateDeviceKey`), Keychain item
  `device-key`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, data-protection keychain.
- Secrets (`SecretStore`): ticket per daemon host (`host.<id>.ticket`; after pairing it still
  names the daemon and the device grant is used), SSH passwords, private keys (`key.<id>`),
  Secure Enclave key handles, `known_hosts`. `SecretStores.appDefault` uses the Keychain, or
  owner-only files in Application Support when this build has no keychain entitlement (ad-hoc
  signed Mac builds get `errSecMissingEntitlement`; logged).
- Metadata: `hosts.json`, `keys.json`, imported `ssh_config` in Application Support/<bundle id>.
- Pairing inputs: paste (`PairSheet`), QR (`QRScannerView`, VisionKit
  `DataScannerViewController`, camera string in project.yml; not in the simulator), deep link
  `$(BRAND_URL_SCHEME)://pair/<ticket>` (`CFBundleURLTypes` from `Brand.xcconfig`, handled in
  `WindowRoot.onOpenURL`).
- SSH auth: password (saved by default), app keys (generated ed25519 / imported PEM), Secure
  Enclave P-256 via `SecureEnclaveSigner` (`SshSigner`; `ecdsa-sha2-nistp256`, raw r‖s),
  key files and ssh-agent on macOS. Host keys: TOFU through `HostKeyPrompts` (blocking delegate
  bridged to the UI); changed keys need an explicit "Replace key".
- "Install helper": `HostsModel.installHelper` runs `SshSession.bootstrap` with the bundled
  gzipped Linux daemons (`build/hostd/*.gz` → app resources), pairs with the returned ticket,
  keeps the SSH connection until the daemon's layout is ready, then swaps the host's connection;
  `WindowRoot` notices the new connection object and shows a workspace on it (same window,
  same host). Bootstrap now enables systemd lingering itself (`loginctl --no-ask-password
  enable-linger`), because without it the daemon dies with the installing SSH session.

## 5. Logs and diagnostics

`CoreLog.install()` routes the Rust core's `tracing` (`install_log_sink`, new in apple-ffi) to
os_log category `core`. HostKit logs `daemon` (dial, connected after N ms, first paint, echo
RTT at debug), `ssh`, `hosts` (pairing, bootstrap action and time). In the simulator:
`xcrun simctl spawn <udid> log show --info --predicate 'subsystem == "dev.unnamed.app"'`.

## 6. Test hooks (launch arguments)

`-testTicket <ticket>` pair and show; `-testSSH user@host[:port]` with `-testSSHKey <path>` or
`-testSSHPassword <pw>`; `-testTrustHostKeys YES`; `-testInstallHelper YES`; `-testRelay
disabled`; `-testMirror YES` (core VT mirror for pane text).

## 7. Tests

| | |
|---|---|
| `cd apple/Packages/HostKit && swift test` | unit tests with a fake `DaemonClientAPI` (layout conversion, store revisions/optimism, connection state machine, routing/buffering, prediction feed, hosts sorting/persistence, ssh_config import, keys, secrets) and `DaemonIntegrationTests` against a real local `unnamed-hostd` (pair, echo, split, daemon restart → stale → live, suspend/resume, re-dial by saved ticket) |
| `cd apple/Packages/TerminalKit && swift test --filter snapshot` | READY restore + history pages + live bytes |
| `apple/scripts/daemon-ui-test.sh [udid]` | `DaemonUITests` on the iPad simulator against a local daemon, killed and restarted mid-test |
| `TEST_RUNNER_SSH_TARGET=… TEST_RUNNER_SSH_KEY=… xcodebuild … -only-testing:AppUITests/RealHostUITests test` | just ssh → Install helper → daemon pane: ls, vim, Ctrl-C, htop, screenshots |
| `MacDogfoodUITests` | Ctrl-C, Ctrl-Z, vim, resize during output, closing a tab kills its process (pgrep), local and daemon |

## 8. Measurements (2026-10-18, M5 Max, iPad Pro 13" simulator iOS 27.0, debug builds)

| | Local daemon (loopback, relays off) | Hetzner x86_64, Helsinki (ping 53.6 ms avg) |
|---|---|---|
| SSH connect + auth (just ssh, key) | — | 577–920 ms |
| Bootstrap ("Install helper") | — | `Upgraded` 6.3 s (upload + restart), `Reused` 0.55 s |
| iroh connect after the ticket (pair) | 0.27–0.31 s (app), 38–56 ms (HostKit test) | 0.34–0.55 s |
| Dial → first paint (snapshot on screen) | 53–83 ms | 0.58–0.80 s |
| Keystroke → echo | 0.4–0.6 ms (input→ack) | p50 65.6 ms, min 55, max 72 (20 keys) |
| Daemon restart → pane live again | ≈1.0 s | — |
| Suspend → resume (foreground) | 10–15 ms | — |

`ipad-hetzner-{1-plain-ssh,2-installing,3-daemon-pane,4-ls,5-vim,6-ctrl-c,7-htop,8-done}.png`.

## 9. Gaps

- macOS UI automation needs an interactive authentication approval for the ad-hoc signed test
  runner; `MacDogfoodUITests` is written but was not run here. The same behaviours are covered
  below the UI: LocalPTY tests (Ctrl-C, Ctrl-Z, terminate ends foreground and background jobs)
  and HostKit integration (Ctrl-C and close-kills-process on a daemon pane).
- Keychain on ad-hoc signed Mac builds: no entitlement, so secrets fall back to owner-only files.
- QR scanning is untested (no camera in the simulator). Tailscale hints are not implemented.
- The daemon does not report the foreground program, so key-bar profiles use the title.
- `RealHostUITests` passes but takes ≈14 min: XCUITest waits for the app to idle between
  synthesized keys; the app-side timings above are from os_log, not the test's duration.
- Plain-SSH panes cannot be suspended on iOS (no serialized state); they reconnect instead.
- Switching a host from SSH to daemon replaces the window's workspace (same window, same host):
  the plain-SSH shell is closed once the daemon's layout is ready, so its scrollback is not
  carried over.
- `TerminalInputUITests.testMultilinePasteAsksForConfirmation` fails on the dedicated iOS 27.0
  simulator used here, also with the window root reduced to a bare `WorkspaceView`, so it is not
  caused by the host wiring; not yet checked on main or on iOS 27.1. All other iOS UI tests pass.
- macOS remote host: the app paired with a local daemon by `-testTicket` and attached (hosts.json,
  session 1); typing into it on macOS was not driven (no UI automation, see above).
