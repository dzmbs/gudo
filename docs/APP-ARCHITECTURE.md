
Status: 2026-10-18. The Apple app talks to real hosts: paired daemons over iroh and plain SSH,
with "just ssh" → "Install helper" → daemon. This document is the contract between the data
layer (`apple/Packages/HostKit`, the `Workspace`/`Pane` glue in `apple/App`) and the views.
Since 2026-10-19 the views are the design system's (docs/DESIGN.md), bound to these models
through `WindowModel` and the adapters in `App/Sources/Model/LiveSources.swift`; §10 lists what
is real and what still shows mock data.

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
| `AppModel` (App) | `hosts`, `lastError` | `workspace(for:)` (resolve on target change, never in `body`), `existingWorkspace(for:)`, `handle(url:)` |
| `WindowModel` (App, one per window) | `destination` (terminal / inbox / hosts), `sheet`, palette and search state, `connection: ConnectionState` (the window host's `ConnectionStatus` in design words, with when it went down), `hostName`, `hosts: any HostDirectory`, `agents: any AgentFeed`, `paneStatus: any PaneStatusSource`, `toasts` | `show(target)` (set by `WindowRoot`), `addHost(mode:destination:)`, `retryConnection()`, `disconnect()` |
| `Workspace` (App) | `session`, `panes`, `title(of:)` (the tab's name), `context(of:)` (agent task → program → shell title → repo:branch → directory), `canOpenTabs` | `apply(op)`; unnamed tabs get a friendly name (`FriendlyName`, sent as a rename so a daemon keeps it for every device) |
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

- macOS UI automation is approved now, but the Mac was locked for the whole 2026-10-19 merge run
  ("Failed to activate application … Running Background"), so `MacDogfoodUITests`,
  `ChromeUITests` and `testSidebarAppearsAfterSwitchingFromTabStrip` did not run on macOS. The
  same behaviours run in-app: `apple/scripts/dogfood.sh Dogfood/core.json` (13/13). Run
  `xcodebuild … -destination 'platform=macOS' -only-testing:AppUITests/MacDogfoodUITests
  -only-testing:AppUITests/ChromeUITests -only-testing:AppUITests/WorkspaceUITests test` on an
  unlocked Mac.
- Keychain on ad-hoc signed Mac builds: no entitlement, so secrets fall back to owner-only files.
- QR scanning is untested (no camera in the simulator). Tailscale hints are not implemented.
- The daemon does not report the foreground program: key-bar profiles use the daemon's agent
  kind (`PaneMeta.agent`), else the title.
- XCUITest idle waits are gone: on 2026-10-19 the longest "Wait for app to idle" in the whole iOS
  suite was 0.9 s (≤ 0.1 s in most tests); `RealHostUITests` went from ≈14 min to 53 s,
  `DaemonUITests` runs in 34 s, the 16 iOS UI tests in 280 s. Most likely, the repeating animations that kept
  the app busy were the plain-SSH banner's `ProgressView` (a spinning `UIActivityIndicatorView`,
  shown while a connection or install was in progress) and the design branch's mock spinners;
  the design's `Spinner` draws from a `TimelineView` instead of a repeating Core Animation, and
  the banner is gone. The secure-input badge still loops its gradient (only while a password is
  read).
- Plain-SSH panes cannot be suspended on iOS (no serialized state); they reconnect instead.
- Switching a host from SSH to daemon replaces the window's workspace (same window, same host):
  the plain-SSH shell is closed once the daemon's layout is ready, so its scrollback is not
  carried over.
- `RealHostUITests` needs a clean app container (uninstall first): with the host already saved
  as a daemon, "just ssh" opens the daemon directly and there is no Install Helper button. One
  run of three failed to see the first echo in the daemon pane within 30 s; the next clean run
  passed (53 s).
- macOS remote host: the app paired with a local daemon by `-testTicket` and attached (hosts.json,
  session 1); typing into it on macOS was not driven (no UI automation, see above).

## 10. Design screens: real data vs mock (2026-10-19)

`WindowModel` picks the sources: the live adapters in `App/Sources/Model/LiveSources.swift`, or,
with `-mock` (screenshots, `-screen <name>` fixtures), `App/Sources/Model/MockData.swift`. The
screens only see the protocols in `ScreenModels.swift`.

Real (HostKit / apple-ffi):

| Screen / element | Source |
|---|---|
| Hosts (`Screens/HostsView.swift`) | `LiveHostDirectory` over `HostsModel.entries`: this Mac first (macOS only), daemon + SSH hosts, "Needs you" (blocked agent summary or a connection that needs the user), Active / Pinned / Other, status dots and words from `ConnectionStatus` (RTT when known), tab counts, agent glyph counts from `PaneMeta.agent`, helper install progress (`installs[id].summary`). Menu: Connect, Retry, Install Helper, Pin, Rename, Copy Address, Disconnect, Forget. Import menu: `~/.ssh/config` (Mac), file, paste → `SSHConfigImportSheet` |
| Add Host (`Screens/PairingSheet.swift`) | SSH: `JustSSHFlow` (password, saved keys, ssh-agent on Mac, generate ed25519 / Secure Enclave, import key file, public key + install / ssh-copy-id commands); host-key TOFU / changed-key alert from `HostKeyPrompts` (also presented inside the sheet). Ticket: paste → `HostsModel.pair`. Scan (iOS): VisionKit `QRScannerView` inside the viewfinder when a camera exists. Deep link `<scheme>://pair/<ticket>` (`WindowRoot.onOpenURL`, success/failure toast) |
| Plain-SSH upgrade | `HostNotices` over the terminal: "Plain SSH · Install Helper" (`install-helper`), install progress in words, install notes, offline notice |
| Reconnect | `connectionOverlay` (design card: dimmed/desaturated last frame, "Attempt N · last output Ns ago", Retry Now → `HostConnection.retry()`, Disconnect → back to this device) from the window host's `ConnectionStatus`; `StalePaneOverlay` marks stale panes (`stale-<pane>`); first connect shows `ConnectingView` |
| Sidebar header / footer, iPhone top bar | host name, `ConnectionDot`, status words |
| Tab names and context lines | friendly names (renamed on the daemon so every device shows them); context from `PaneMeta.agent` (task), local PTY foreground program, OSC title, `.git/HEAD` (local), cwd |
| Pane headers, tab strip, sidebar Agents section, palette | agent glyphs and program from `LivePaneStatus` (`DaemonConnection.meta[pane].agent`) |
| Inbox | `LiveAgentFeed`: agents of every connected daemon from `PaneMeta.agent`; Approve / Deny call `DaemonConnection.decide` with the matching option; Mark Done hides the item locally |
| Key bar profile | `Workspace.reportedProgram`: backend-reported program, else the local PTY's foreground, else the daemon's agent kind; the title stands in otherwise |

Still mock (the next agent's job; the apple-ffi calls now exist, docs/APPLE-FFI.md "Workspace",
"Editor", "Multiplayer", "Push"):

| Screen | File | Wire to |
|---|---|---|
| Inbox: Reply…, New Agent, unseen counts, history (Finished) | `Screens/InboxView.swift` (`LiveAgentFeed.reply/launch` are no-ops) | `attentionList()` / `attentionSeen`, `WorkspaceEvent.attention`, `prompt(paneId:text:submit:)`, `launchAgentPane(launch:)` |
| Diff review | `Screens/DiffReviewView.swift` (`MockDiffSource`) | `gitStatus`, `gitDiff`, `listTurns` / `turnDiff`, `sendReview` |
| Files | `Screens/FilesBrowserView.swift` (`MockFileSource`) | `fsList / fsStat / fsRead / fsWatch`, `uploadFile / downloadFile` |
| Editor | `Screens/EditorView.swift` (`MockFileSource`) | `openEditor` (serve-web over a forward, never a sign-in; tunnels opt-in only), `editorOpenInSession` |
| Browser | `Screens/BrowserView.swift` (fixed URL) | `ports()` / `.portsChanged`, `forward(localPort:target:)` |
| Links & paths | `Screens/LinksSheet.swift` (`MockLinks`) | daemon links extraction (DAEMON.md §5) |
| Share session, presence avatars | `Screens/InviteSheet.swift`, toolbar `PresenceStack` (`MockPresence`, shown only with `-mock`) | `createInvite`, `participants`, `MultiplayerEvent.presence`, `takeControl` … |
| Scrollback search counts | `TerminalSearchBar` in `SplitTreeView` (fixed 2/14) | renderer / daemon search |
