# App architecture: data and control layer

The Apple app talks to real hosts: paired daemons over iroh and plain SSH,
with "just ssh" → "Install helper" → daemon. This document is the contract between the data
layer (`apple/Packages/HostKit`, the `Workspace`/`Pane` glue in `apple/App`) and the views.
The views are the design system's (docs/DESIGN.md), bound to these models
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
                                                 │ UniFFI (GudoCore: DaemonClient, SshSession, SshPane)
```

## 1. Models the views bind to

All are `@MainActor @Observable`. Views never hold a socket or a `DaemonClient` (04 R7).

| Model | What a view reads | What a view calls |
|---|---|---|
| `AppModel` (App) | `hosts`, `lastError`, `localLayout` (this device's tabs, shared by windows), `openWindows` | `makeWorkspace(for:selecting:)` (a window's own workspace on a host; resolve on target change, never in `body`), `isHostOpen(_:elsewhereThan:)`, `endSharedPanes(of:)`, `handle(url:)` |
| `WindowModel` (App, one per window) | `destination` (terminal / inbox / hosts), `sheet`, palette (`paletteMode`: commands / go to tab / new tab on host) and search state, `groups: HostGroups`, `workspaces[groupId]` (one per open host, kept live), `target` / `workspace` (what the detail column shows), `currentTab: TabRef`, `connection: ConnectionState` (the shown host's status in design words, with when it went down), `hostName`, `hosts: any HostDirectory`, `agents: any AgentFeed`, `paneStatus: any PaneStatusSource`, `toasts` | `show(target)`, `focus(TabRef)`, `focus(pane:onGroup:)`, `newTab(onGroup:)`, `selectTab(shortcut:)` / `selectTab(offset:)`, `showHostPicker()`, `showTabFinder()`, `closeHost`, `restore(openHosts:collapsed:focus:)`, `addHost(mode:destination:)`, `retryConnection()`, `disconnect()`; windows (§17): `widthBucket`, `newWindow()`, `openInNewWindow(_:)`, `open(_ request:)`, `continue(_ payload:)`, `handoffMissing`, `close()` |
| `HostGroups` (HostKit, one per window) | `groups: [HostGroup]` (this device, then open hosts in open order, then hosts connected elsewhere: id, name, kind, `status`, `tabs`, `isReady`, `failure`), `tabs: [TabRef]` (the unified order), `openHosts`, `collapsed` | `open(id)` (never redials an open host), `close(id)`, `restore(ids)`, `tab(forShortcut:)`, `shortcutNumber(of:)`, `tab(after:offset:)`, `newTabHost(preferred:)` |
| `Workspace` (App, one per window per host) | `session` (the window's view: `WindowLayoutStore`), `sharedLayout`, `panes` (this window's terminals), `title(of:)` (the tab's name), `context(of:)` (agent task → program → shell title → repo:branch → directory), `canOpenTabs` | `apply(op)`; unnamed tabs get a friendly name (`FriendlyName`, sent as a rename so a daemon keeps it for every device) |
| `HostsModel` | `entries: [HostEntry]` (sorted: Needs you → pinned → recent), `installs[id]` (`InstallProgress.summary`), `installNotes[id]`, `sshConfigAliases`, `keys.keys`, `hostKeyPrompts.pending`, `network.isOffline` | `open(id)`, `pair(ticket, name:)`, `connectSSH(…)`, `installHelper(id)`, `loadSSHConfig(text)` / `loadUserSSHConfig()` (macOS) / `importSSHHosts(aliases)`, `rename`, `setPinned`, `disconnect`, `remove`, `foreground()/background()/networkChanged()` |
| `HostEntry` (value) | `name`, `kind` (`.daemon`/`.ssh`), `address`, `status: ConnectionStatus`, `needsYou: String?`, `blockedAgents`, `canInstallHelper`, `pinned`, `lastConnected` | - |
| `ConnectionStatus` (value) | `.idle/.connecting/.connected(rtt)/.reconnecting(attempt, reason)/.offline/.suspended/.needsAttention(reason)`; `summary` (words, A22), `isLive`, `needsUser` | - |
| `any HostConnection` (`Workspace.host`) | `status`, `isReady` | `retry()` (R9) |
| `DaemonConnection` | `blockedAgents`, `meta[pane]` (title, cwd, agent), `echoRoundTrip`, `timings` | `decide(requestId:optionId:)` |
| `Pane` (App) | `connection: PaneConnection` (`.live` / `.stale(reason)`), `title`, `workingDirectory`, `foregroundProgram` | - |
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
| `.snapshot(Data)` | `terminal.restore(snapshot:)` (TerminalCore, READY section): never blanks: on failure the old screen stays |
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

Predictions are drawn only when they hide latency someone could see: round trip above 30 ms
(hidden again below 20 ms), or a keystroke unconfirmed for 250 ms (a stall). They never move text
the shell drew right of the cursor (autosuggestions, right prompts): over such text only an empty
cell or the same character is predicted. A cell is underlined only once its echo is late (a round
trip plus 250 ms). `FlickerTests` replays zsh with highlighting and autosuggestions cut at every
byte and checks every presented frame.

Synchronized output (mode 2026): `Terminal.write` holds the bytes between `CSI ? 2026 h` and
`CSI ? 2026 l` and parses them in one piece (`SynchronizedOutput`), so no reader of the terminal
sees a half-drawn TUI frame however the stream was cut. A hold ends after 1 s (Ghostty's limit;
the surface keeps ticking to release it), past 4 MiB, on resize, and at a CSI query when the
terminal answers queries itself.

## 3. Connections and lifecycle (04 R1-R12)

| Rule | Where |
|---|---|
| R1 keepalive + probe on foreground | SSH: `SshSession` keepalives (15 s × 3); `HostsModel.foreground()` → `SshSession.setForeground(true)` (probe), `DaemonClient.reconnect()` for daemons not live and `DaemonClient.probe()` for daemons that say they are. Daemon links: QUIC keep-alive 3 s and idle timeout 12 s on both sides (`proto::KEEP_ALIVE`, `proto::IDLE_TIMEOUT`); `probe()` pings and drops a link with no pong in 3 s (10 s while packets still arrive: slow, not dead), also when a keystroke gets no ack within 1 s (`PaneRouter.onInputStalled`, at most every 5 s) |
| R2 "connected" = answered recently | `ConnectionStatus` comes from client-core / ssh session states, never a socket flag |
| R3/R5 suspend → resume | iOS `scenePhase == .background` → `DaemonClient.suspend()` (resume state kept), `.active` → `reconnect()`; panes resume from the ring or a snapshot |
| R7 stable handle | `HostConnection` per host id; transports swap underneath; `Workspace` holds the connection, views hold ids |
| R8 status from the input path | status is derived from the `DaemonClient`/`SshSession` that also sends input |
| R9 retry everywhere | `ConnectionBanner` (Retry), host row menu (Retry) |
| R10 budgets reset | `NetworkMonitor` (NWPathMonitor, debounced 300 ms) → `networkChanged()`; foreground; Retry |
| R11 end-to-end check | `DaemonIntegrationTests`, `DaemonUITests` type a marker and assert it comes back |
| R12 output independent of views | `PaneRouter` buffers per pane until the view starts; VT lives in `Pane`, not the view; stale panes keep their content |

Multi-host windows: a window shows every open host at once. `HostGroups` keeps the
window's open hosts; `HostsModel.connections` keeps one `HostConnection` per host for as long as it
is open, and `WindowModel.workspaces` one `Workspace` per open host (its panes stream in the
background, R12), so selecting a tab on another host only changes `WindowModel.target`: no dial
(`DaemonConnection.dials` counts dials; `MultiHostUITests` asserts it stays put while switching).
The iOS lifecycle is per app, not per window: `HostsModel.background()` suspends every connection,
`foreground()` resumes every one at once (R1/R3/R5); plain-SSH hosts still reconnect instead
(below). A failed `open` leaves no idle connection behind: the group shows the reason
(`HostGroups.failures`). Per window, `WindowRoot` persists `openHosts`, `collapsedHosts` and
`focusedTab` (`TabRef`) in scene storage, mirrored to user defaults for new scenes; launch
reopens them and selects the tab once its host's layout arrives (`-restoreLastTarget NO`
disables restore; design fixtures, `-mock` and Dogfood runs skip it).

Keyboard across hosts (iOS): one `KeyBar` for the app (`Workspace.sharedKeyBar`), so a host
switch keeps the same input accessory view (no input-view reload, no second line editor competing
for first responder); the old host's terminal resigns first responder before its view leaves the
window and the new host's focused pane inherits the keyboard (`Workspace.inheritsKeyboardFocus`);
the terminal answers the tab shortcuts itself (`TerminalView.appKeyCommands`), so ⌘1…⌘9,
⇧⌘[ ], ⌘T, ⌥⌘T and ⌘P never depend on the responder chain reaching the scene's menu commands.
Known gap (key bar): while the prompt line editor's text field holds the keyboard, ⌘ shortcuts
do not reach the app (the field lives in the keyboard's accessory window).

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

- Device key: `DeviceIdentity.load`: generated once (`generateDeviceKey`), Keychain item
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
  same host). Bootstrap enables systemd lingering itself (`loginctl --no-ask-password
  enable-linger`), because without it the daemon dies with the installing SSH session.

## 5. Logs and diagnostics

`CoreLog.install()` routes the Rust core's `tracing` (`install_log_sink`, new in apple-ffi) to
os_log category `core`. HostKit logs `daemon` (dial, connected after N ms, first paint, echo
RTT at debug), `ssh`, `hosts` (pairing, bootstrap action and time). In the simulator:
`xcrun simctl spawn <udid> log show --info --predicate 'subsystem == "dev.gudo.app"'`.

## 6. Test hooks (launch arguments)

`-testTicket <ticket>` pair and show; `-testTickets <t1>,<t2>` with `-testTicketNames a,b` pair
with several daemons and open them all in the window; `-hostsDirectory <path>` keeps saved hosts
and secrets in that folder. Without it, any `-test…` argument, `-dogfood`, `-snapshot`, `-screen`,
`-localEcho`, `-mock` or an XCTest environment uses `$TMPDIR/<bundle id>.test-data` (`AppData`):
tests, dogfood runs and screenshot scripts never touch the user's hosts, replays or Keychain; `-connectionProbe
YES` exposes each open host's connection identity and dial count to UI tests; `-testSSH user@host[:port]` with `-testSSHKey <path>` or
`-testSSHPassword <pw>`; `-testTrustHostKeys YES`; `-testInstallHelper YES`; `-testRelay
disabled`; `-testMirror YES` (core VT mirror for pane text); DEBUG `-posture
<folded|flat|book|tabletop>` draws an iPhone Duo posture over the window's real size (§24).

## 7. Tests

| | |
|---|---|
| `cd apple/Packages/HostKit && swift test` | unit tests with a fake `DaemonClientAPI` (layout conversion, store revisions/optimism, connection state machine, routing/buffering, prediction feed, hosts sorting/persistence, ssh_config import, keys, secrets) and `DaemonIntegrationTests` against a real local `gudo-hostd` (pair, echo, split, daemon restart → stale → live, suspend/resume, re-dial by saved ticket) |
| `cd apple/Packages/TerminalKit && swift test --filter snapshot` | READY restore + history pages + live bytes |
| `apple/scripts/daemon-ui-test.sh [udid]` | `DaemonUITests` on the iPad simulator against a local daemon, killed and restarted mid-test |
| `xcodebuild … -only-testing:AppTests test` | the workspace screens' models against a fake `DaemonWorkspaceAPI`: inbox merge (live agents + attention, history, commands, answered requests, yes/no option matching), file listing with git letters, previews, uploads that never replace, rename/trash/mkdir/download, diff line numbers and side-by-side pairing, turns and review routing, editor phases (install → load → reuse → open file → stop), ports (sorting, same-port forward, fallback, reuse, offers), links mapping, errors in words. HostKit: `DaemonWorkspaceTests` (one listener per client, pushes, unseen, seen requests, RPC answer pairing, re-watch after reconnect) |
| `apple/scripts/w3-ui-test.sh [udid] [test …]` | `W3UITests` on the iPad simulator against a local daemon set up by `w3-fixtures.sh` (HOME = a scratch dir with a git repo, a `claude` stand-in that drives the daemon's real hooks, a `code serve-web` stand-in): Files, Diff + notes, New Agent → Approve → finished summary → Reply → Open Pane → the turn's diff → review sent to the agent, Editor (workbench over the forward, ⌘P reaches the page, a path from Links opens at its line), a dev server offered and opened, Copy Last Command Output |
| `apple/scripts/multihost-ui-test.sh [udid]` | `MultiHostUITests`: two local daemons in one window; click and ⌘1/⌘2/⇧⌘[ switches with the same connections and no stale overlay, ⌘T on the current host, one daemon killed → its group reconnecting while the other stays live, then back |
| `HostGroupsTests` (HostKit) | the aggregation with fake connections: two daemons + one SSH host, open order, ⌘1-9 mapping, wraparound across hosts, status changes, no redial, lifecycle reaches every host, restore and failures |
| `TEST_RUNNER_SSH_TARGET=… TEST_RUNNER_SSH_KEY=… xcodebuild … -only-testing:AppUITests/RealHostUITests test` | just ssh → Install helper → daemon pane: ls, vim, Ctrl-C, htop, screenshots |
| `MacDogfoodUITests` | Ctrl-C, Ctrl-Z, vim, resize during output, closing a tab kills its process (pgrep), local and daemon |

## 8. Measurements (M5 Max, iPad Pro 13" simulator iOS 27.0, debug builds)

| | Local daemon (loopback, relays off) | Remote Linux x86_64 (ping 53.6 ms avg) |
|---|---|---|
| SSH connect + auth (just ssh, key) | - | 577-920 ms |
| Bootstrap ("Install helper") | - | `Upgraded` 6.3 s (upload + restart), `Reused` 0.55 s |
| iroh connect after the ticket (pair) | 0.27-0.31 s (app), 38-56 ms (HostKit test) | 0.34-0.55 s |
| Dial → first paint (snapshot on screen) | 53-83 ms | 0.58-0.80 s |
| Keystroke → echo | 0.4-0.6 ms (input→ack) | p50 65.6 ms, min 55, max 72 (20 keys) |
| Daemon restart → pane live again | ≈1.0 s | - |
| Suspend → resume (foreground) | 10-15 ms | - |

## 9. Gaps

- The macOS UI tests (`MacDogfoodUITests`, `ChromeUITests`,
  `testSidebarAppearsAfterSwitchingFromTabStrip`) need an unlocked Mac; on a locked one they
  fail with "Failed to activate application … Running Background". The same behaviours run
  in-app with `apple/scripts/dogfood.sh Dogfood/core.json`. On an unlocked Mac run
  `xcodebuild … -destination 'platform=macOS' -only-testing:AppUITests/MacDogfoodUITests
  -only-testing:AppUITests/ChromeUITests -only-testing:AppUITests/WorkspaceUITests test`.
- Keychain on ad-hoc signed Mac builds: no entitlement, so secrets fall back to owner-only files.
- QR scanning is untested (no camera in the simulator). Tailscale hints are not implemented.
- The daemon does not report the foreground program: key-bar profiles use the daemon's agent
  kind (`PaneMeta.agent`), else the title.
- No repeating animation may keep the app busy, or XCUITest waits for idle on every step.
  The longest "Wait for app to idle" in the iOS suite is 0.9 s (≤ 0.1 s in most tests);
  `RealHostUITests` runs in 53 s, `DaemonUITests` in 34 s, the 16 iOS UI tests in 280 s. The
  design's `Spinner` draws from a `TimelineView`, not a repeating Core Animation, and plain SSH
  shows no `ProgressView`. The secure-input badge loops its gradient only while a password is
  read.
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

## 10. Design screens: real data vs mock

`WindowModel` picks the sources: the live adapters in `App/Sources/Model/LiveSources.swift`, or,
with `-mock` (screenshots, `-screen <name>` fixtures), `App/Sources/Model/MockData.swift`. The
screens only see the protocols in `ScreenModels.swift`.

Real (HostKit / apple-ffi):

| Screen / element | Source |
|---|---|
| Hosts (`Screens/HostsView.swift`) | `LiveHostDirectory` over `HostsModel.entries`: this Mac first (macOS only), daemon + SSH hosts, "Needs you" (blocked agent summary or a connection that needs the user), Active / Pinned / Other, status dots and words from `ConnectionStatus` (RTT when known), tab counts, agent glyph counts from `PaneMeta.agent`, helper install progress (`installs[id].summary`). Menu: Connect, Retry, Install Helper, Pin, Rename, Copy Address, Disconnect, Forget. Import menu: `~/.ssh/config` (Mac), file, paste → `SSHConfigImportSheet` |
| Add Host (`Screens/PairingSheet.swift`) | SSH: `JustSSHFlow` (password, saved keys, ssh-agent on Mac, generate ed25519 / Secure Enclave, import key file, public key + install / ssh-copy-id commands); host-key TOFU / changed-key alert from `HostKeyPrompts` (also presented inside the sheet). Ticket: paste → `HostsModel.pair`. Scan (iOS): VisionKit `QRScannerView` inside the viewfinder when a camera exists; a scanned code fills the ticket. Deep link `<scheme>://pair/<ticket>` (`WindowModel.openLink`) opens the sheet on the ticket. Every path shows the ticket's host (name if already paired, else "New host", and its key's start) and pairs only on the user's tap |
| Plain-SSH upgrade | `HostNotices` over the terminal: "Plain SSH · Install Helper" (`install-helper`), install progress in words, install notes, offline notice |
| Reconnect | `connectionOverlay` (design card: dimmed/desaturated last frame, "Attempt N · last output Ns ago", Retry Now → `HostConnection.retry()`, Disconnect → back to this device) from the window host's `ConnectionStatus`; `StalePaneOverlay` marks stale panes (`stale-<pane>`); first connect shows `ConnectingView` |
| Sidebar header / footer, iPhone top bar | host name, `ConnectionDot`, status words |
| Tab names and context lines | friendly names (renamed on the daemon so every device shows them); context from `PaneMeta.agent` (task), local PTY foreground program, OSC title, `.git/HEAD` (local), cwd |
| Pane headers, tab strip, sidebar Agents section, palette | agent glyphs and program from `LivePaneStatus` (`DaemonConnection.meta[pane].agent`) |
| Key bar profile | `Workspace.reportedProgram`: backend-reported program, else the local PTY's foreground, else the daemon's agent kind; the title stands in otherwise |
| Share Session, presence, control, join, grants, audit | `MultiplayerSession` (§11): `Screens/InviteSheet.swift`, `Multiplayer/*` |
| Local notifications, actions, Live Activity | `Notifications/*` over `DaemonConnection.workspaceEvents` (§12) |

### Workspace screens

The developer-workflow screens read the daemon through `Model/LiveWorkspaceSources.swift`. Each
source resolves where it acts when asked (`HostContext`): the window's host when it is a
connected daemon, with its focused pane and that pane's directory (`PaneMeta.cwd`, OSC 7), else
the first connected daemon; with none, the screen says so ("Connect one in Hosts") instead of
failing. Per daemon, `HostKit.DaemonWorkspace` (`connection.workspace`) keeps ports, the
attention feed and its unseen count from the connection's shared `workspaceEvents` hub (observed,
as `AppNotifications` does; it never sets a `WorkspaceListener` of its own), relays them with
`observePorts` / `observeAttention`, re-establishes directory watches after a reconnect, and
pairs the pane RPCs' answers (`links`, `commands`, `commandOutput`, `search`, which arrive as `ClientEvent`s) with their
requests. `DaemonWorkspaceAPI` is the slice of `DaemonClient` it and the sources use, so both are
tested against fakes.

| Screen | Source | Calls |
|---|---|---|
| Agents (`Screens/InboxView.swift`) | `LiveAgentFeed` | live agents from `PaneMeta.agent`, then any other program's own OSC 7501 report (`DaemonConnection.programs`, `PaneReport`: a status row, never an approval card), merged with each host's attention feed (`attentionList`, `.attention` pushes): summaries of finished turns (`body`), failed agents and long commands whose pane is gone (history, newest 40), unseen dots and the per-host unseen count in the subtitle; on screen 1.5 s → `attentionSeen(up_to:)` on every device; Approve / Deny → signed `decide` with the option whose label says yes/no (whole words), shown as working until the daemon moves on; Reply… → `prompt(paneId:text:submit:)` (composer path); Open Pane → switch host, focus the pane, `attentionSeen(pane_id:)`; Mark Done hides it locally and marks it seen |
| New Agent (`Git/NewTaskSheet.swift`, ⇧⌘N) | `LiveAgentFeed.launch` | connected daemons; `launchAgentPane` in a new tab (`newTabIn`) in the host's focused pane's directory, or in a fresh `worktreeCreate` (own branch and `PORT`); the sheet closes as soon as the pane exists and the window shows it; the first prompt is typed through `prompt` once the agent reports idle (≤ 60 s, a toast says if it could not be) |
| Diff review (`Screens/DiffReviewView.swift`) | `LiveDiffSource` | `gitStatus` (repo, branch, ↑↓), `gitDiff` HEAD→worktree (untracked included) or staged, `listTurns` of the agent panes in the repo + `turnDiff` ("what this agent turn changed"); side by side on iPad/Mac (regular width; Layout menu: automatic/unified/side by side), unified on iPhone; monospace on the terminal background, palette green/red only; tap a line → note; notes → `sendReview` to the turn's agent (or the focused / first agent in the repo), Copy otherwise |
| Files (`Screens/FilesBrowserView.swift`) | `LiveFileSource` | `fsList` + `gitStatus` letters (a directory with changes inside gets M), `fsStat` / `fsRead` preview (UTF-8 text up to 1 MiB with line numbers, images up to 24 MiB, else a card), `fsWatch` (reloads on change), New Folder `fsMkdir`, Rename `fsRename` (never overwrites), Move to Trash `fsDelete(.trash)`, upload from the Files picker or by drop `uploadFile(createNew)` ("name 2.ext" when taken) with progress, download `downloadFile` → share sheet (iOS) / ~/Downloads + Finder (Mac); Open in VS Code, Reveal in Terminal (`cd`), Insert Path |
| Editor (`Screens/EditorView.swift`) | `LiveEditorSource` | `editorStatus` (is VS Code's CLI there?) → `openEditor(folder: <repo root or directory>, acceptVscodeLicense: true)` → a `WKWebView` on the forward, in an editor pane of the split tree (§20); steps "Set up VS Code on host (first run only) → Start the editor → Open the workbench" with seconds, never a licence prompt or sign-in, nothing about the VSCodium fallback; sessions kept per host+folder (closing leaves the server running; More → Stop Editor ends it, `closeEditor(stopServer:)`); a path from Links opens with `editorOpenInSession`; while an editor pane has the focus the app's ⌘ shortcuts step aside (except ⌘1-⌘9, ⌘W, ⌃⌘\`, §20) so every other key reaches VS Code |
| Browser (`Screens/BrowserPorts.swift`, `BrowserView.swift`) | `LivePortSource` | `ports` / `.portsChanged` (HTTP first, process and pane); a new HTTP port on the window's host is offered ("localhost:5173 is up · Open", 15 s); Open → `forward(localPort: <same port>, .tcp)` (any free port when taken here; existing forwards reused) → in-app browser with back/forward/reload/share/Open in Safari; palette lists "Open localhost:N" |
| Links & paths (`Screens/LinksSheet.swift`) | `LiveLinkSource` | `links(paneId:commands: 20)` (screen + the last 20 commands' output, paths resolved, missing ones dimmed); a path opens in VS Code at its line, a URL in the in-app browser (localhost through a forward); local panes: URLs and paths scanned from the visible text |
| Palette | `PaletteCommands` | Copy Last Command Output (`commandOutput`, the output without the prompt), Open in VS Code, Dev Servers & Ports, Open localhost:N |
| Scrollback search | `WindowModel.searchTotal` | the total over the whole scrollback from the daemon's `search` (debounced 180 ms); stepping through matches needs the renderer's highlights (not wired) |
| Acknowledgements | `SettingsView` | VS Code licence, VS Code Server licence, Microsoft privacy statement (`vscodeLicenseUrl()` …) |

Remote Linux host (x86_64, iPad simulator, relays on): pair → connected 100 ms →
first paint 391 ms → `openEditor` (the `code` CLI installed from Microsoft in that call,
`installedCli: true`, VS Code itself, no fallback) ready 1066 ms after Open → workbench loaded
1418 ms after Open; no prompt, no sign-in.
The 10-15 s first run of DAEMON.md §5.3 is a host without a cached VS Code server; this host
already had `~/.vscode-server`.

Gaps: VS Code's own light theme opens in a dark app (the workbench follows its own settings);
a turn that goes blocked → (approved) → idle gets no `AgentDone` attention item from
the daemon (DAEMON.md §5.8), so that row says "Waiting for your next prompt" without the agent's
last message; scrollback search shows the daemon's total but cannot step through matches;
uploads take files from the Files picker and drops (no Photos picker); "Open in Safari" for a
forwarded localhost page works only while the app keeps the forward (iOS suspends it in the
background); local (non-daemon) windows have no Files/Diff/Editor (they say so).

## 11. Multiplayer (DAEMON.md §6)

`DaemonConnection.multiplayer: MultiplayerSession` (HostKit, `@MainActor @Observable`) follows
the connection's `MultiplayerListener` pushes in order (an `AsyncStream` pumped on the main
actor) and wraps the requests. Views never hold the client; `MultiplayerClientAPI` is the seam
(tests use `FakeMultiplayerClient`, `-mock` uses `MockMultiplayerClient`).

| Reads | Calls |
|---|---|
| `me` (`JoinInfo`), `roles`, `isOwner`, `isGuest`, `canDrive`, `canPrompt`, `canApprove`, `isViewOnly`; `participants` (one per device), `others` (one per principal), `people(in:)`; `leases`, `holder(of:)`, `isDriving`, `isDrivenByOther`; `leaseRequests` (the holder's prompt), `pendingTakes`; `grants`, `devices`, `auditPage`, `invites`; `notice` (refusals, hand-overs, revocation in words); `inputGate` | `takeControl(pane, force:)`, `answer(request, give:)`, `releaseControl`, `giveControl`, `cancelTake`; `prompt(pane, text)`, `setTyping(pane?)`; `createInvite(InviteOptions)`, `refreshGrants()`, `revoke(RevokeTarget)`, `loadAudit()`, `setName` |

- **Input gate.** `inputGate` (no driver role → every pane; another connected principal holds
  the lease → that pane) is pushed into `PaneRouter`: gated keys, pastes and mouse bytes are
  dropped before they leave the device, echo prediction is off for gated panes (nothing would
  be acknowledged), and a throttled `notice` says why ("Mira is driving. Take control to
  type."). The daemon still enforces everything (`InputRejected`, `Forbidden` → `notice`).
- **Joining.** `HostsModel.join(invite:name:)`: `inspectInvite` → a guest `HostRecord`
  (`guest == true`, `inviter`, invite in the secret store under `host.<id>.invite`) dialled with
  `DaemonClient.join`; a refused first join leaves nothing behind. Deep links
  `<scheme>://join/…` open `JoinSheet` pre-filled (who invites, roles with what they allow,
  scope, expiry, uses); joining is always a tap. The palette has "Join a Session…".
- **Invite model.** `InviteDraft` (HostKit): name, roles beyond viewing, scope Host / Session /
  Tab / Pane (ids from the live layout), expiry 1 h / 24 h / 7 d / never, uses 1 / 5 /
  unlimited, delegate → `InviteOptions`; `summary` is the line the sheet shows.
- **Screens.** Toolbar `PresenceToolbarButton` (others' avatars with typing rings, or a share
  glyph) → `InviteSheet`: people here (role, where they are, typing, driving; swipe / context
  menu Revoke, Give Control), the invite composer (role tiles, scope, expiry, uses, "Can Invite
  Others") → link + QR (Core Image) + Copy + Share; owners get Access & Grants (`GrantsView`:
  active / ended invites with uses and expiry, devices, revoke with confirmation) and the Audit
  Log (`AuditLogView`: chain status, filters, search, approvals with signer key and
  signature). Guests see Your Access instead. On the panes (`SplitTreeView` hooks):
  `PanePresence` in split headers, `MultiplayerPaneOverlay` with the control chip ("Mira is
  driving · Take Control", "Asked Alex · yours if idle 4 s", owner "Take Now"), the holder's
  `LeaseRequestCard` (Keep / Hand Over with the idle countdown), a viewer's banner and a
  prompter's composer on agent panes. `MultiplayerWindowHooks` turns notices into toasts.
- **Mock.** `-mock` gives every window `MockMultiplayer.session` (owner + three guests, grants,
  devices, a ten-record audit log); `-mockPresence YES` also draws it on the panes,
  `-mockRole viewer|prompter|driver` shows a guest's side, `-mockLeaseRequest YES` the holder's
  prompt, `-shareRoute grants|audit` opens the sheet there.

Tests: `MultiplayerSessionTests` (fake client: role gates, lease gate, presence, take control
pending → granted, the holder's answer, invite options, prompt refusal and revocation words),
`MultiplayerIntegrationTests` (three `HostsModel`s against a local daemon: owner invites a
viewer by link, the viewer sees output, its keys are gated and, sent raw, refused with
`.role`; a driver asks for control, the owner is asked and hands over, the driver's keys
arrive; the owner revokes the driver; the audit chain verifies with join, redeem, lease and
revoke records), `MultiplayerUITests` via `apple/scripts/multiplayer-ui-test.sh` (iPad, a
guest joined through the `gudo` CLI: presence, invite + QR, grants, revoke, audit; the script
then checks the guest's `gudo who --watch` was disconnected).

## 12. Notifications (docs/PUSH.md)

`NotifyKit` (package, no core): categories `AGENT_APPROVAL` (Approve / Deny with
`.authenticationRequired`, Deny destructive, Open foreground), `AGENT_BLOCKED`, `AGENT_DONE`,
`COMMAND_DONE`; `NotificationPrefs` per kind (+ only in the background); `AttentionNote` →
`LocalNotifications.content` (one request per pane, thread per host, time-sensitive for
approvals); `NotificationActionHandler` over `NotificationActionClient` (local → signed
`decide` on the live connection, push → `sendPushAction` on a one-shot connection, Open →
the pane); `ServiceExtensionCore` (PushCrypto + paired-daemon check) and `SharedPushStore`
(Keychain group + app group, nil without the entitlement); `AgentRunAttributes` /
`AgentRunState` (ActivityKit).

App: `AppNotifications` (delegate set in `AppDelegate` before launch finishes) subscribes to
every daemon's `DaemonConnection.workspaceEvents` (`WorkspaceEventHub`, one
`WorkspaceListener` fanned out; other features can `observe` it too), posts
`.attention(.added)` items that are unseen and not `whileViewed` when the app is not active
(approval options from `PaneMeta.agent`), clears a host's delivered notes and sets the badge
from `unseen`. Permission is asked right after the user pairs a new host (`HostsModel.onFirstPairing`;
Apple's "ask in context"), never when a note fires while the app is away (it is then just not
posted). `-notificationPrompt NO` skips the ask; runs with the UI tests' pairing hooks skip it
unless `-notificationPrompt YES`. Approve / Deny from a notification also marks the item seen
(`NotificationActionClient.markSeen`), so the badge takes the daemon's new count at once. Settings ▸
Notifications edits the prefs. `AgentLiveActivities` (iOS) starts an activity per agent run,
updates it on blocked / done and ends it ten minutes after; `AgentActivityWidget` draws it.
`<scheme>://open/<host>/<pane>` (activity, notification tap) focuses the pane.

Push: `NotificationService` (app extension, iOS) calls `ServiceExtensionCore.shared()`.
Registration (`HostsModel.registerPush`: relay `/v1/register` → `pushRegister` with the
sealing key; `sendPushDecision` for the lock screen) runs only when the build has the
entitlement: `Brand.xcconfig` `PUSH_ENTITLEMENT = YES` (→ Swift `PUSH_YES`,
`registerForRemoteNotifications`), `PUSH_ENTITLEMENTS_FILE = App/Push.entitlements`,
`PUSH_KEYCHAIN_GROUP`, `PUSH_APP_GROUP`. The default (`NO`, free account) builds and runs
everything else unchanged.

Tests: `cd apple/Packages/NotifyKit && swift test` (NSE decrypt of every shared vector,
category from the payload, placeholder kept for the three rejects, an unpaired daemon and no
key; the handler with a fake client for local and push Approve / Deny / Open, an expired
token, a refusal; local content per kind; prefs; categories).

## 13. Push-to-talk dictation (VoiceKit)

`apple/Packages/VoiceKit` (no views, no terminal types) holds the engine and the logic;
`App/Sources/Voice/` the glue. Speech is recognized on the device only: `SpeechAnalyzer` +
`SpeechTranscriber` (iOS/macOS 26) when the language's model is installed, else
`SFSpeechRecognizer` with `requiresOnDeviceRecognition`. No network during dictation, no paid
entitlement. A missing SpeechAnalyzer model is never fetched mid-dictation: Settings › Voice shows
its state and a Download button (`AssetInventory`, the system's own model download).

| | |
|---|---|
| `PushToTalk` (VoiceKit, `@MainActor @Observable`) | `start(target:) -> Bool`, `stop() async -> Outcome`, `cancel()`, `transcripts() -> AsyncStream<Transcript>`; reads `phase` (`idle/starting/listening/finishing/failed(VoiceError)`), `isActive`, `transcript` (`finalized` + `volatile`, `text`), `settings` |
| `VoiceDictation.shared.voice` (App) | the app's instance; plain `start()` targets the terminal that is first responder, else the key window's focused pane. **The key bar's mic button calls `start()` on touch down, `await stop()` on touch up, `cancel()` when the touch is cancelled** |
| `DictationTarget` / `PaneDictationTarget` | the preview is the terminal's preedit (marked text at the cursor, `DictationPreview.fit` keeps the end that fits the row); nothing reaches the host before release. Release commits `Transcript.text` on one line, no Return: `surface.paste(_, source: .text)` (bracketed when the program enabled it); a guest who may prompt but not type gets `MultiplayerSession.prompt(_, _, submit: false)` on agent panes (`DictationRoute.resolve`) |
| Hardware chord | hold ⌃⌥Space in a terminal (`TerminalView.keyInterceptor` → `VoiceDictation.handleKey`, `HoldShortcut`); releasing Space commits. On a Mac with several input sources the system may take ⌃⌥Space first |
| Settings › Voice | `VoiceSettings.enabledKey` (default on), `VoiceSettings.localeKey` ("" = system language), model state and download |
| Indicator | `dictationIndicator()` on the workspace: "Listening · English" while active, the error in words for 5 s |

Info.plist: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` (project.yml).
Tests: `cd apple/Packages/VoiceKit && swift test` (fake recognizer: segment merging, preview, commit
without newline, cancel, empty, second start, release while starting, permission and recognizer
errors, finish timeout, routing, transcript stream, hold chord, settings). Only a device confirms
the microphone, the SpeechAnalyzer model assets per language, and latency.

## 14. Helper versions, updates and host names (DAEMON.md §2 "Version, host name and updating")

Every connection learns what the daemon is before `Welcome`: `ClientEvent.daemonInfo(info:)`
(build, `builtUnix`, protocol level, `selfUpgrade`, host name, OS, CPU; nil from daemons that
predate it). `DaemonConnection` keeps `daemonInfo`, `daemonInfoReported`, `incompatibility` (from
`ClientEvent.incompatible`: the daemon draws terminals in another format; status reads "This
host's helper needs an update") and `epoch` (the daemon run).

**This Mac's helper** (`LocalHelper`, macOS). The Mac app bundles its own daemon
(`Contents/MacOS/<name>-hostd`, from `cargo xtask build-hostd-macos`, copied and signed by the
"This Mac Helper" build phase) and a LaunchAgent plist (`Contents/Library/LaunchAgents/<bundle
id>.hostd.plist`, `BundleProgram`). At launch it registers the agent with `SMAppService` (runs at
login, survives quitting the app), or runs the daemon as its child when Settings ▸ This Mac ▸ Keep
Sessions Running in the Background is off or the login item is not allowed. The daemon uses its
default folder (`~/Library/Application Support/<name>`, where `gudo` and the agent hooks look); a
daemon already running there that is not an app's (`hostd service install`, a `run` in a
terminal: its executable is outside any `.app`) is used as is, and the app's own login item is
unregistered so launchd does not keep starting one that cannot take the folder. The app pairs
once with a `pair --json --local` ticket (loopback addresses: works offline; `gudo devices` lists
the device as "This Mac (Gudo app)") as the owner, saved as a host with `thisDevice` and named
"This Mac": listed first, no helper-update offers (a new app build restarts the login item:
`launchctl kickstart -k`), and an empty plain local group gives way to it (plain shells still
open stay until closed). When the helper refuses the app's device as removed (`InvalidGrant`,
`Revoked`: `gudo devices` removed it, or its pairing was lost), `HostsModel.onThisDeviceRemoved`
has `LocalHelper.pairAgain` mint a fresh local ticket and pair again without asking; the host
shows as connecting meanwhile, and the refusal (in words) only if that fails. Remote hosts never
pair again on their own. Stop Helper ends it and brings back a plain shell. Test
launches (`AppData`) never start it unless `-localHelper YES`, and then only as a child in the test
folder (`apple/Dogfood/this-mac.json`). iPhone and iPad have no helper.

**What the app bundles.** `cargo xtask build-hostd-linux` writes `build/hostd/hostd-manifest.json`
next to the two `.gz` daemons (file, OS, CPU, build, time, level); project.yml bundles it and
`AppModel` loads it once (`BundledDaemons`, `-testBundledDaemons <dir>` for tests).

**The rules** (`HelperCheck.assess`, HostKit, unit tested): guests get nothing; a daemon whose
`minClientProtocol` is above the app's, or that is newer and incompatible → "Update the app";
incompatible (or below `minDaemonProtocol()`) → `.required`, said plainly ("This host's helper is
too old for this app. Update it to connect."); a bundled build for its OS/CPU at a higher level, or
the same level from an earlier source with another build id → `.update`, offered quietly ("A newer
helper is available."). A daemon from before version reporting is offered an update only over SSH.
How: over the host's saved SSH login when it has one (set up by "just ssh" → Install Helper), else
over the connection when the daemon offers `selfUpgrade`, else not at all.

**Where it shows.** `HostEntry.helper` → `HostSummary.helper` (`HelperOffer`): the host row's
subtitle when connected ("A newer helper is available." with an arrow glyph, secondary) and its
menu action **Update Helper**; over the terminal, `HostNotices` shows one line with **Update** and
a dismiss button (or, when required, the statement and **Update Helper**), then the progress
(`HostsModel.helperUpdates[id].summary`: "Updating helper (3.1 MB of 7.0 MB)", "Restarting
helper…"). A success toast says the host runs the new helper.

**`HostsModel.updateHelper(id)`.** SSH: a short-lived `SshSession` with the saved credentials and
host-key policy runs `bootstrap` (uploads the bundled build when its SHA-256 differs, restarts
the service; the device stays paired). Connection: `DaemonConnection.updateHelper(path:build:)`
→ `DaemonClient.upgradeDaemon` streams the gzip; the daemon checks it, swaps it in and execs it.
Either way it returns once a new daemon run is live (epoch changed), within 60 s. Panes come back
from the daemon's layout and agents resume; shell processes restart (DAEMON.md lists what is lost).

**Host names.** `HostRecord.nameSource` (`placeholder` / `machine` / `user`) and `machine`
(host name, OS name, OS, CPU). Pairing without a name and "just ssh" make placeholders ("Host
1a2b3c4d", the address typed); a name given when pairing, an ssh_config alias, a guest's
"Alex's host" and every rename are the user's. On each `daemonInfo`, `HostsModel.daemonReported`
records the machine and renames a placeholder to `MachineName.display(hostname)` (first label:
`ubuntu-32gb-hel1-2.example.com` → `ubuntu-32gb-hel1-2`; nothing for empty or `localhost`), once
(source becomes `machine`). Records saved before this have no source: names that look like the
app's ("Host …", "test daemon…", the SSH address without an alias) count as placeholders, any
other name as the user's. The test hooks do not name hosts "test daemon" (`-testTicketNames`
still does). Hosts show "Ubuntu 24.04.1 LTS · x86_64" as their status line when idle.

Tests: `HelperVersionTests` (the rules, the manifest, machine names, placeholders, renaming once,
user names kept, advice following the connection, incompatible words) and
`HelperUpdateIntegrationTests` (a real local daemon installed as a copy: named after this Mac,
`.update` over the connection, `updateHelper` → restarted in place, layout and typing back;
about 2.5-3 s). Daemon side: `cargo test -p daemon --test it upgrade`.

Gaps: no release signing key (hash plus a run of the new build is the check); the SSH path has only
been exercised by the existing bootstrap tests, not by an update of a paired host; macOS hosts get
no offer (the app bundles Linux daemons only).

## 15. Native password prompts (DAEMON.md §9)

`DaemonConnection.askpass` (`AskpassSession`, HostKit) follows the core's askpass pushes: open
prompts (`prompts`, kept through a dropped connection as `stale` for 15 s so a sheet survives a
blip), detected hidden-input prompts by pane (`detected`), and why prompts closed. Both dialers
connect with `ConnectOptions.askpass = true`. In the pane (`App/Sources/Askpass`):

- `AskpassPaneOverlay` (in `PaneSlot`) shows `SecretPromptCard` at the top of the prompt's pane:
  the program's icon and "sudo needs your password" / "ssh needs a passphrase" (`AskpassCopy`),
  the asking command and host in SF Mono, the program's own prompt as the field label, a
  `SecureField` (`.password` content type, so password managers can fill it; a plain field for
  yes/no questions), "Remember in Keychain", Cancel (Esc) and OK (Return). The card is glass
  over the terminal, like the lease request; it takes focus and gives it back to the terminal.
- At a detected prompt the pane shows the "Enter Password Securely" chip at its bottom edge,
  just above the key bar; it opens the same card, whose OK types the secret and Return.
- `SecretEntry` holds the typed text only until it is sent. "Remember in Keychain" is opt-in per
  host and prompt: `AskpassVault` (`KeychainAskpassVault`, service `<bundle id>.askpass`) keeps
  it under `.userPresence` access control, `WhenUnlockedThisDeviceOnly`, keyed by a SHA-256 of
  host, program kind and prompt. A saved password is never sent by itself: the card shows a
  Face ID button, and the system asks before it is read. If the same question comes back right
  after it was used (`retry`), it is forgotten and the card says so. Settings › Passwords counts
  them and has "Forget Saved Passwords". Builds without a usable Keychain hide the toggle.
- Accessibility: the card is a container labelled with its title; the field is labelled with the
  program's prompt; the chip, the Face ID button and the toggle have labels and hints.

Tests: `AskpassSessionTests`, `AskpassCopyTests` (HostKit), `SecretEntryTests` (App), and
`AskpassUITests` against a local daemon (`apple/scripts/askpass-ui-test.sh`): `$SSH_ASKPASS`
answered in the card, Cancel, and the chip at a `stty -echo; read` prompt.

## 16. Agent usage meters

`DaemonWorkspace.usage` holds a host's `AgentUsageReport` while something shows it:
`beginWatchingUsage()` / `endWatchingUsage()` count viewers (the first sends `usageWatch`, the
last `usageUnwatch`), only for daemons whose `DaemonInfo.agentUsage` is true; pushes
(`WorkspaceEvent.agentUsage`) update it; a reconnect re-watches. `UsageFeed` (`LiveUsageFeed`,
`FakeUsageFeed` for `-mock` / `-fakeUsage YES`) is what views read. HostKit's `UsageMeter` makes
the compact line ("Claude · 62% of 5h · resets 14:20": the limited, else fullest, window that has
not reset) and its tone (quiet ≤ 80 %, amber above, red limited); `UsageDetail` the popover rows.
Views (`UsageViews.swift`): one line per agent under each daemon host's name in the sidebar, the
detail popover (also from the host menu's Agent Usage), and a quiet strip at the bottom of the
Inbox. Unknown means absent; the reason is in the popover. With agent accounts (§27) the daemon also
pushes usage per account (`DaemonWorkspace.accountUsage`); a pane's limit suggestion reads it. There is no setting: the daemon uses
only the tools' own data and documented commands, never the host's sign-ins.
Tests: `AgentUsageTests` (HostKit), `UsageFeedTests` (AppTests), `UsageUITests`.

## 17. Windows (iPad scenes, Stage Manager, external displays, Mac windows; Handoff; width buckets)

Every window is independent: its own host, tab and pane selection, its own terminals, its own
restore (`@SceneStorage`: open hosts, collapsed groups, focused tab, the request it opened).
`TerminalApp` is one `WindowGroup(for: WindowRequest.self)`; iPadOS multiple scenes come from
the generated scene manifest (`UIApplicationSupportsMultipleScenes`).

```
 window A ─ WindowModel ─ Workspace(A, host) ─ WindowLayoutStore ─┐            ┌─ Pane(A) ─ Terminal + surface + view
                                                                  ├─ host's one LayoutStore      │ tap
 window B ─ WindowModel ─ Workspace(B, host) ─ WindowLayoutStore ─┘            └─ Pane(B) ─ Terminal + surface + view
                                                         one stream per pane:  PaneRouter (daemon) / SharedPaneBackend (PTY, SSH, echo)
```

**Layout: one store per host, a view per window.** `WindowLayoutStore` (PaneLayout) wraps the
host's store: tabs, split trees, names and zoom are the host's; the active tab and each tab's
focused pane are the window's. Every op still goes to the host's store (focus too, so a daemon
hears the last focus); ops on "the active tab" (new tab, zoom) first focus this window's pane
there; a tab or pane the window creates becomes its selection once the store has it (at once
locally, after the daemon's answer remotely; 5 s timeout); a tab closed elsewhere hands over to
its neighbour. Tests: `WindowLayoutStoreTests`.

**Panes: a terminal per window, one stream per pane.** Two windows showing one pane each have a
`Pane` (VT, renderer, view): a view lives in one window only. The daemon keeps one subscription
per pane per connection, so the connection's `PaneRouter` fans each pane's stream out to taps
(one `DaemonPaneBackend` per window): subscribe with the first, unsubscribe with the last; acks
go to the tap whose keystroke they answer, hints to all, drawing offsets (`onOutputApplied`) per
tap. Local PTYs, plain-SSH channels and the echo stand-in are one process or channel per pane:
`SharedPaneBackend` (HostKit) owns it and hands out taps (`AppModel.sharedPane`). A tap that
starts while others run is seeded from one of their terminals (`Terminal.seedEvents()`: the
snapshot's READY section, then the whole scrollback), under the fan-out's delivery lock, so it
shows exactly what the others show without asking the host again. One size per pane: the window
that typed or took focus last drives it (`SharedPaneTap.claimSize`, also on every write); the
others render the same grid. When the last window showing a local or SSH pane closes while the
pane stays in the layout, its stream is parked in a headless terminal, and a later window starts
from it. Closing a host in a window ends its taps there; the connection stays while another
window shows the host (`HostGroups.isOpenElsewhere`). The daemon hears the union of every
window's visible panes and the last window's focus (`DaemonConnection.setWindowView`).
Tests: `PaneSharingTests`, `SharedPaneBackendTests`, `WindowsTests` (AppTests).

**Opening windows.** ⌘N (iPad: File ▸ New Window and the terminal's own key command; Mac:
`WindowGroup`'s New Window) opens a window like the current one (`WindowRequest.like`: same
hosts, same tab). Open in New Window is in the tab context menus (sidebar row, strip chip,
compact switcher) and the host group's menu. On iPad a tab row or chip dragged out of the window
carries the window activity (`TabDrag`): dropped outside, iPadOS opens a new scene that continues
it (same host id on this device).

**External displays.** With Stage Manager the display gets ordinary windows (above). Without it,
`AppDelegate` gives the `windowExternalDisplayNonInteractive` role its own scene
(`ExternalDisplaySceneDelegate`): a full-size presentation of the iPad's active window's tab with
its own terminals, at the display's scale (`traitCollection.displayScale`, and the screen's own
display link), the font scaled so the pane's grid fills the display; input stays on the iPad.

**Handoff.** Each window advertises `NSUserActivity` `<bundle id>.terminal`
(`NSUserActivityTypes`) with a `HandoffPayload`: kind, host id and name, the daemon's endpoint id
or the SSH address, tab, pane, installation id. Continuing (`onContinueUserActivity`) resolves the
host by id on the same device, else by daemon id, else by SSH address, and opens the tab and pane
(`WindowModel.select`; the `<scheme>://open/<host>/<pane>` path uses the same focus). A host the
device has not paired: an alert names it and offers Add Host (SSH pre-filled; ticket otherwise).
This device's own shell is never offered to other devices.

Drawings ride along: while a pane of the shown tab is in draw mode, or the focused
pane is a canvas pane, the payload's `drawing` names it (`artifact`, the `placement` being edited,
`canvas`) and `pane` is that pane (`Workspace.drawingFocus`, kept by `PaneDrawing`). Continuing
opens the host and pane, then (`WindowModel.continueDrawing`, retried while the pane connects and
its placements arrive) reopens that placement in draw mode, or a drawing not placed yet over the
pane, or just leaves the canvas pane focused. Payloads without `drawing` (older builds) continue as
before. "Open on Other Device" is Handoff itself. Tests: `WindowsTests` (payload, which pane),
`DrawingHandoffUITests` (draw mode in the activity and continued in draw mode; a canvas split
drawn with Excalidraw's rectangle tool, reopened after relaunch, continued focused).

**Width buckets.** `WidthBucket` picks the layout from the window's width, never the device:
under 600 pt compact (the iPhone layout: one pane, tab switcher, tab bar), else regular (sidebar
and splits), with 12 pt of hysteresis so a drag at the edge does not flip back and forth. The
window's `horizontalSizeClass` is overridden to match, so every screen agrees. A switch keeps the
workspace, tab, focused pane and terminals (views move between containers; scrollback and
viewport are the terminal's) and suppresses the cols × rows overlay for a second
(`Workspace.layoutChangeUntil`). Tests: `WindowsTests` (bucket logic), `WindowsUITests`.

**One model per scene.** `WindowRoot` makes its `WindowModel` once, when the scene first
appears (SwiftUI rebuilds the root struct, and a `@State` initial value would be evaluated each
time); `start()` then registers it (`ActiveWindow`, `AppModel.openWindows`) and opens this
device's workspace. Spare models never exist, so menu commands, design fixtures (`-screen`) and
dictation always act on a window on screen (`WindowsUITests.testOneModelPerWindowAndFixturesOnIt`).
Dictation's `AppModel.openWorkspaces` lists every window's workspaces, the key window's first. The
key bar stays one per app (`Workspace.sharedKeyBar`): only the key window's terminal has the
keyboard, and the input accessory view follows that first responder between scenes. Remote panes
follow the stream's size (`sizeFollowsStream`): the window that drives a pane resizes the PTY,
the others draw the stream's grid without reflowing it.

Test hooks: `-windowProbe YES` (bucket, host, tab, pane, Handoff payload, overlay count, window
and model counts, how the last activity resolved, as JSON on `window-probe`, plus narrow / wide /
front controls), `-resetWindows YES` (start from one window), `-continueActivity <json>` (continue a payload at launch),
`<scheme>://debug/width/<pt>` and `-windowWidth <pt>` (narrow the window, debug builds).
`apple/scripts/windows-ui-test.sh [ipad] [iphone]` starts a daemon, turns on Stage Manager in the
simulator (`SBChamoisWindowingEnabled`) and runs `WindowsUITests`.

Limits (need a device or a second device): real Split View / Slide Over and Stage Manager drags
(UI tests narrow the window with the debug width and rotate the iPhone instead); a real external
display (`xcrun simctl` cannot attach one; `ExternalDisplayTests` checks the scene configuration, the mirrored tab and the font scale); Handoff between
two devices needs both signed by the same team (a free Personal Team works for one person's own
devices, same Apple Account, Bluetooth and Wi-Fi on; ad-hoc "-" signed Mac builds have no team
and cannot hand off); a daemon host continued on another device opens that device's attached
session, so the tab and pane are found only when both attach the same session (else the host
shows on its active tab). Drawing placements are routed per pane id by `DrawingHub`, so with a
pane in two windows only the newest window's controller gets placement updates (drawing owner).

Test status: `WindowsUITests` passes Handoff contents,
both continuation cases, one-model-per-window + `-mock -screen splits`, and the iPhone rotation
(compact ↔ regular, same pane, no overlay). Two iPad cases are open harness gaps:
`testTwoWindowsOnOneHostTypeIndependently` opens the second window with ⌘N, follows the same
host and tab, starts its terminal from the first window's and types into its own new tab (all
passed, screenshots attached), but with iPadOS 26 windowing the new window covers the first and
neither the `debug/front` link (its "Open in…?" confirmation) nor the probe's front control has
reliably brought window 1 back for the last step; `testCrossingTheWidthBoundary…` reaches compact
through the debug link but not through the probe's controls, and after the link's confirmation
iPadOS restores keyboard focus to the first pane (the model then shows pane 1 while pane 3 keeps
the keyboard), which the content check trips on. The same behaviours are covered without UI by
`WindowsTests` and `WindowLayoutStoreTests`. Also seen: right after the system's "Open in…?"
confirmation, focus can move to a tab's first pane (pre-existing focus restoration, not fixed).

## 18. Command marks (OSC 133)

Every daemon pane gets a `PaneCommandMarks` (App/Sources/Panes), attached next to `PaneDrawing`:

- **Rows.** It reads the pane's `Commands` list (`DaemonWorkspace.commands`) on attach, after
  every snapshot (resume, reattach) and shortly after each `CommandMark` push for the pane.
  `CommandBlocks.blocks` (HostKit, pure, tested) turns it into blocks named like row anchors
  (rows from the bottom at the list's output offset): prompt row to the last output row. The
  end mark's row is the next prompt when the output ended with a newline; with a following
  command that is decided from its prompt row, for the newest command by the app's terminal
  (`Terminal.isPromptRow`, or the row reaching the cursor). The controller pins the rows with
  its own `RowTracker` (`onOutputApplied(observer: "command-marks")`; the router keeps one
  callback per observer), so blocks scroll with the output and are pinned again once the
  terminal reaches the list's offset.
- **Stripes.** `TerminalSurface.gutterMarks` (TerminalKit) asks for `GutterMark`s before every
  frame; the renderer draws them through the image pipeline (1×1 textures) in the left padding,
  clipped to the grid's rows: up to 3 pt wide, right-aligned 2 pt from the text when the padding
  allows. ANSI red (theme palette 1) for a non-zero exit, the foreground at 16 % for success,
  38 % while running (to the cursor). None on the alternate screen. Each stripe on screen has an
  accessibility element `command-mark-<id>` ("Command: …", value "Failed, exit 1" /
  "Succeeded" / "Running").
- **Menu.** `TerminalView.contextActions` adds a section to the iOS edit menu (long-press,
  selection, secondary click) and to the Mac right-click menu for the command whose rows are
  under the point, the likeliest next step first (the touch edit menu shows three items before
  it pages: after a failure Ask Agent, after a success Re-run): Copy Output (`CommandOutput` by
  id; the palette's Copy Last Command Output
  shares `WindowModel.copyCommandOutput`), Copy Command, Re-run (bracketed paste + Return; not
  while a command runs) and Ask Agent (`CommandBlocks.agentPrompt`: command, outcome and the end
  of the output, plain text within the prompt sanitizer's rules, typed with `prompt(submit:
  false)` into an agent pane of the window, this tab first; else New Agent opens with it as the
  prompt via `WindowModel.newTaskPrompt`).
- **⌘↑ / ⌘↓** (`WorkspaceAction.previousPrompt/nextPrompt`, Pane menu, terminal key commands):
  the nearest command prompt above or below the viewport's top row becomes the top row; past
  the last, back to the bottom. Panes without marks use libghostty-vt's own prompt rows
  (`scrollViewport(byPrompts:)`).
- **Sidebar.** `DaemonWorkspace.runningCommands` follows the marks (and lists); a tab row whose
  pane runs a shell command for 3 s or more shows "cargo build · 1m 12s" (monospaced digits,
  `TabSubtitle`) in place of its context line. Not for agent panes.

Tests: `CommandBlocksTests` (HostKit), `GutterMarkTests` and `promptRowsAndJumpingBetweenPrompts`
(TerminalKit), `CommandMarksUITests` (iPad, local daemon), the daemon's shell integration tests
(notification body).

## 19. Mixed tabs (panes from several hosts in one tab) and Two Columns

**Model.** A mixed tab is a `CompositeTab` (PaneLayout): an ordinary `Tab` over the composite's
own leaf ids plus `members` (leaf → `HostPane`, a host id and that host's `PaneId`). Every
arranging op (focus, directional focus, resize, zoom, rename) runs the same `Session` code as a
host tab, on a one-tab scratch session. The window owns its mixed tabs: `HostGroups.composites`
(`CompositeTabs`), persisted per window like `openHosts` (`@SceneStorage("mixedTabs")`, JSON, plus
the app's last copy). In the unified tab order they come first (`TabRef(hostId: HostGroups.mixedId,
tab: id)`), so ⌘1…⌘9, ⇧⌘[ ], Go to Tab and focus restore treat them like any tab. The sidebar
shows them under **Mixed** at the window's top, each row naming its hosts with their glyphs (the
link's state glyph while a host is down); the strip and the iPhone switcher list them too.

**Decisions.**
- *Where a host's panes live.* Each host's panes in a mixed tab live in one tab on that host, its
  **carrier**. The host layout stays the truth for pane lifetime: other windows and devices see
  the carrier as a plain tab (with the host's own arrangement of its panes); this window hides it
  from that host's group, since the mixed tab shows its panes.
- *What ⌘D / ⇧⌘D split onto.* The focused leaf's host: `.split(pane)` in its carrier there; the
  new pane is placed beside the focused leaf in the mixed tab once the host answers.
- *Split with Host…* (⇧⌥⌘D, Pane menu, header ⋯ menu, palette) on a host tab makes that tab a
  mixed tab in place (same tree, its tab the carrier) and asks the other host for a pane: a
  `.newTab` there (it becomes the carrier) or, with a carrier already, a split in it. ⌥⌘D itself
  is the system's Dock shortcut on Mac and iPad and never reaches the app, hence the ⇧.
- *Closing.* Closing a leaf sends `.close(pane)` to its host (the carrier shrinks, or closes with
  its last pane); closing the mixed tab sends `.closeTab(carrier)` to each host. Closing a host in
  the window drops its leaves (the panes stay on the host).
- *Reporting back.* `CompositeTabs.reconcile()` runs whenever a host's layout or link changes: a
  pane its (known, live) host no longer has leaves; a pane that appears in a carrier (split on
  another device) joins beside that host's last leaf; a split this window asked for is adopted
  when its answer arrives (10 s timeout). A host that is down or still connecting is *unknown*:
  its leaves stay, so a restart or outage never reshapes the tab. A mixed tab down to one host
  dissolves into that host's carrier tab, which shows again in its group.
- *setView priorities.* `WindowModel.screenViews()` gives each daemon the panes this window shows
  of it: a mixed tab's visible leaves on that host (the zoomed leaf alone when zoomed) plus the
  other column's; the focused pane only to the focused leaf's host. Hosts with nothing on screen
  get an empty view, as before.

**Focus and actions.** `target` (the workspace on screen) follows the focused leaf's host, so
everything that acts on "the focused pane" (find, links, prompt jumps, drawing, agents, the
toolbar host button) works unchanged. `SplitTreeView` renders any `PaneTree`: `HostTabTree` (a
host's tab) or `MixedTabTree`, whose leaves resolve through their own host's `Workspace` (panes
keep streaming per host, `WindowModel.workspaces`). A terminal taking the keyboard reports it
(`Workspace.onPaneFocus`), so a click in another host's pane moves the mixed tab's focus.
`WorkspaceAction.perform` first offers pane actions to the mixed tab (`performInMixedTab`). Each
leaf names its host in its pane header and carries its own host's connection overlay: one host
going down dims and labels its leaves only.

**Restore.** The window saves its mixed tabs and the focused `TabRef`; on relaunch the tab comes
back at once (leaves of hosts still connecting show the terminal background, then their panes).
This device's own panes do not outlive the app and hosts no longer open in the window are
dropped. A restarted daemon reuses ids: a carrier that no longer holds any of the composite's
panes is forgotten rather than trusted (pane ids a restarted daemon reuses can still be mistaken
for the old ones; daemons do not keep sessions across restarts today, so this needs a session
generation from the daemon to close fully).

**Two Columns** (View ▸ Two Columns, the toolbar's Pane menu, the palette).
Two tabs side by side, each column its own tab (any host, or a mixed tab), a 1 pt divider and a
26 pt header per column. The current tab's column takes the keyboard; the other is dimmed like an
unfocused split. Columns stay put: a tab picked in the sidebar replaces the current column's,
focus moving into the other column swaps which is current, and a closed tab's column takes the
next tab not shown (or offers New Tab, which lands there). On an open iPhone Duo with the
sidebar hidden it turns on by itself, one column per page with the fold between them (§24); the
user's choice per window wins and is restored, except that a book never runs one column across
its fold. Never in compact width.

Tests: `CompositeTabTests` (PaneLayout: tree mapping, split with host, ⌘D on a leaf, close,
answers, strays, host down, dissolve, timeout, close tab, round trip), `HostGroupsTests.
mixedTabsLeadAndHideTheirCarriers`, `FoldTests` (§24),
`MixedTabsUITests` (iPad: `apple/scripts/mixed-ui-test.sh` starts two daemons on 47421/47422:
split with host, type in both, ⌘D/⌘W on beta, relaunch restores, kill alpha and beta keeps
working; Two Columns with this iPad's echo shell).

## 20. VS Code editor panes

The editor is a pane kind of the split tree, like a canvas
pane, but owned by the window rather than any host: any number of editors at once, on different
folders, worktrees and hosts, in tabs of their own or beside terminals.

**Model.** An editor is a leaf of a window-owned tab (`CompositeTab`, §19): `editors: [PaneId:
EditorMember]` beside `members`, an `EditorMember` being an id (UUID), a host id and a folder. No host
knows editor leaves: opening, closing or moving one sends nothing to any daemon. A composite with an
editor never dissolves (no host tab could show it); one of editors only is a *VS Code tab*
(`isEditorOnly`). `CompositeTabs.openEditor` (a new tab), `addEditor(_:to:)` (beside the focused
leaf), `addEditor(_:besideHost:tab:)` (a host tab becomes a composite in place, as Split with Host
does), `close(leaf:in:)` (an editor leaf just leaves), `dropHost` (closing a host drops its editors).
Saved with the window's mixed tabs (`@SceneStorage("mixedTabs")`; old saves without `editors` still
load). `HostGroups.mixedTabs` lists VS Code tabs first, then mixed tabs, so ⌘N numbering matches the
sidebar.

**Opening.** Open in VS Code (palette, Open In menu, Files, Links, a path ⌘-clicked in a pane) resolves
the focused pane's host and directory, takes its worktree root (`gitStatus.root`), and:
- for a path, an editor already open on that host whose folder holds it (the focused one first)
  comes forward and opens the file at the line;
- else a new editor, every time (several on one folder are several windows on its one server, sharing
  its data store as browser windows would): a new VS Code tab (default), or, with ⌥ held / "Open in
  VS Code Beside" / Open In ▸ VS Code Beside, a leaf right of the focused pane in its tab. With
  several windows on one folder, a file opened through the server's CLI (`EditorOpen`, below) lands
  in the window the CLI picks, which may be another of them;
- "Open VS Code Through a Remote Tunnel…" opens the pane on the tunnel's offer.
On the Mac the in-app pane is the default too; desktop VS Code (Remote - SSH over our forward,
`DesktopVSCode`) is "Open in Desktop VS Code" in the palette, Open In and the pane's More menu.

**Panes.** `EditorPanes` (per window) holds an `EditorPane` per open editor: its `LiveEditorSource`
pinned to the member's host and folder (its own `openEditor` session and forward; the licence sheet
per host as before, shown in the focused pane; accepting it in one editor lets others on that host go
on), and its `WKWebView` (`TunnelBrowser`, both modes: serve-web and vscode.dev). The web view belongs
to the model, not to the view: a tab switch removes the view and brings it back with the same web
view, so the workbench never reloads. Panes are made when their leaf is first shown, so a relaunch
restores editor tabs without loading any until looked at; they go when their leaf closes (the server
keeps running on the host, as before; More ▸ Stop Editor ends it).

**Memory.** An editor off screen for 10 minutes (`-editorSuspendAfter <s>` for tests) is suspended:
its web view and web content process are released; a JPEG snapshot (taken every minute while on
screen, at most 900 pt wide) stands in under "Resuming VS Code" when it is shown again, and the
page it was on reloads (VS Code restores open files and unsaved changes from its own storage).

**Staying connected.** The workbench's websockets run through the local forward over the host's
one QUIC connection; VS Code reconnects by itself as long as the forward answers and the server
still holds its session. So:
- Leaving the app: `BackgroundGrace` (iOS) keeps connections up for the background time iOS grants
  and suspends them only when it runs out; a quick visit to another app comes back to a live
  workbench. Coming back resumes on `willEnterForeground`, before the page's timers run again.
- Network change: a live connection is kept (`DaemonClient.networkChanged`; iroh moves it to a
  working path), only a dead one is redialled.
- The forward: a connection made while the link is down waits for it, one that met a dead
  connection gets one more try, a broken link resets the local socket (VS Code takes a reset for a
  lost link and retries; an orderly close could pass for the server's goodbye), and the listener is
  bound again after a suspension (iOS defuncts a suspended app's sockets). DAEMON.md §5.1.
- The server: Microsoft's server is run directly with a 48 h reconnection grace and no idle stop
  while a workbench may come back (DAEMON.md §5.3), where serve-web ended sessions after its own
  hour-long idle stop or any VS Code update.
- When the page cannot go on anyway: its web content process ended, or VS Code shows "Cannot
  reconnect" (a user script watches its dialogs): the pane recovers by itself: the last snapshot
  under "Resuming VS Code", the source opened again (a new session when the server was replaced),
  the page loaded again (`EditorPane.recover`).

**Full screen.** ⌃⌘F (VS Code's own full-screen key on the Mac; the web workbench binds nothing to
it, so it passes the editor like ⌘W), the editor bar's Full Screen button, or the palette show the
focused editor alone: no sidebar, tab strip, toolbar, editor bar or status bar, the workbench edge
to edge (`WindowModel.isEditorFullScreen`, `FullScreenEditorView`; on iPhone the tab bar goes too).
The way back never takes a key from VS Code (Escape is its): ⌃⌘F again, or the top edge (a pointer
resting there or a tap brings up a glass Exit Full Screen button for three seconds). Full screen
belongs to that editor while it has the focus: ⌘1-⌘9 or Return to Terminal leave it. On the Mac the
window enters native full screen with it (and leaves it, if it entered it).

**Daemon.** `EditorLaunch` runs one server per folder with its own random connection token, reused
across opens, so N folders are N servers on the host and several panes on one folder share one.
One `serve-web` per host serving every folder through `?folder=` would save the per-server overhead,
but `EditorOpen`'s in-window path (the remote CLI through a connected window's
`VSCODE_IPC_HOOK_CLI`) finds the window by the server's process tree; with several windows on one
server it could not tell which window shows which folder and could open a file in the wrong editor.
Revisit with a way to map an extension host to its folder.

**Keyboard.** While an editor leaf has the focus and its workbench is up (`WindowModel.editorHasKeys`)
every key is VS Code's: the menu commands are disabled (as for the old cover) except
`WorkspaceAction.passesEditor`, and the Mac's shortcut monitor stands aside unless the key is one of
those. On the iPad the web view's container answers those keys itself from the responder chain
(`EditorWebHost`, as a terminal answers the app's shortcuts). What stays the app's, and why:
- **⌘1-⌘9** (select tab / last tab): the way to any other tab. VS Code's own ⌘1-⌘8 only focus editor
  groups (a browser takes them for its tabs in vscode.dev too).
- **⌘W** closes the editor pane, as it closes vscode.dev's tab in a browser. Nothing is lost: the
  server keeps running and VS Code keeps unsaved changes (hot exit). The system's Close Window
  moves to ⇧⌘W (`AppDelegate.buildMenu`), as in Safari.
- **⌃⌘F** shows the editor full screen and back (below).
- **⌃⌘\` Return to Terminal** (Pane menu): the terminal beside the editor in its tab, else the tab the
  editor was opened from (`lastTerminalTab`). VS Code binds nothing to ⌃⌘\` (its ⌃\` toggles its own
  terminal). ⌘⎋ was tried first: on the iPad it never reaches the app while a web view has the keyboard.
- Clicking or tapping any terminal, row or tab, as always.
Left to VS Code on purpose: ⌃Tab / ⌃⇧Tab (its recently used editors), ⇧⌘[ ] (previous/next editor),
⌥⌘arrows (editor navigation, multi-cursor), ⌘P, ⌘K chords, ⌘B, ⌘D, ⌘F, ⌘T, ⌘N. A tap or click in
the web view focuses its leaf (a gesture recognizer that never cancels the page's own touches; a
mouse-down monitor on the Mac); the focused leaf's web view takes first responder, and gives it up
when focus moves to a terminal.

**Chrome.** The sidebar's "VS Code" group lists VS Code tabs (code glyph `ProgramIdentity.vscode`,
the folder name, its host line); a composite with an editor beside terminals stays under Mixed, its
mark the code glyph while the editor has the focus. The strip, the iPhone switcher, the palette's Go
to Tab and Two Columns' headers do the same. The window's target follows the focused editor's host,
so ⌘T, Files and the toolbar act there. A host going down dims its editor leaves with its connection
overlay, as for its terminals.

**iPhone.** VS Code is laid out as in a small desktop window and scaled to fit (`EditorPhoneLayout`):
the page's viewport is set to the pane's width at a fixed scale that gives the workbench at least
600 × 400 CSS px (about 80 columns with the sidebar closed; 0.6 to 0.7 in portrait on a 12 mini to a
17 Pro Max, up to 1 in landscape), in steps of 0.05, ignoring the keyboard's height so it never
rescales. `WKWebView.pageZoom` was tried first: on iOS it shrinks the drawing without widening the
layout viewport. The scale is fixed (no pinch) because iOS zooms into any focused field with text
under 16 px, which is every VS Code input; More ▸ Zoom In / Zoom Out / Fit to Screen steps it
instead (one setting for all editors). Phone defaults go in as the workbench's
`configurationDefaults` (a user script edits the page's `vscode-workbench-web-configuration`
before VS Code reads it): word wrap on, no minimap or sticky scroll, font 13, activity bar at the
top of the sidebar, Chat's secondary sidebar hidden. The user's own settings still win and nothing
is written to their files. The first time a folder opens on the phone the sidebar is closed
(VS Code remembers it from then on). The pane's bar trades the host name and Reload (now in More)
for Explorer, Search, Go to File and Command Palette, which press VS Code's own keys in the page
(⇧⌘E, ⇧⌘F, ⌘P, ⇧⌘P; Explorer and Search hide the sidebar when it already shows them); the
software keyboard carries esc, tab, arrows and Hide Keyboard (`EditorKeyRow`) in place of the
browser's form controls. iPad and Mac are unchanged.

Tests: `EditorLeafTests` (PaneLayout: editor tab, beside a host tab, closing back to the host tab,
last editor, editors across hosts and ⌘D on an editor, dropping a host, order, round trip and old
saves), `EditorPanesTests` (one pane per editor and pruning, the web view kept across hide/show,
suspension only off screen and past the limit, reload on show; placement, several editors per folder, ⌘W, `editorHasKeys`, Return to Terminal, the keys that pass), `EditorPanesUITests` (iPad,
`UI_TEST_CLASS=EditorPanesUITests apple/scripts/w3-ui-test.sh`: two folders in two tabs keeping what
was typed and their load count, ⌘P reaching VS Code and ⌘2 the app, an editor beside the terminal,
⌃⌘\` then ⌘K reaching the app, relaunch restoring and lazily loading both tabs, closing; suspension after 3 s
reloading the page), and the existing `W3UITests` editor tests.

## 21. Browser panes and the agents' browser (DAEMON.md §9.1)

A browser page is a leaf of a window-owned tab, as an editor is (§20): `CompositeTab.browsers`
(`BrowserMember`: id, the host whose `localhost` it reaches, the URL it is on, kept as it
navigates and restored after a relaunch), a tab of its own (sidebar "Browser") or beside a
terminal. `BrowserPanes` keeps one `BrowserPane` (a `WebPage`) per leaf across tab switches; a
host's page uses that host's data store and claims this device's loopback port before a
`localhost:<port>` navigation (`DevServerRouting.prepareLoopback`). Opened from the palette (New
Browser Tab, Open Browser Beside), from the browser sheet (Open as Tab), and by the host: a URL a
pane opens through `BROWSER` comes up beside that pane (`openFromHost`), a sign-in in the system
sign-in sheet instead (`HostSignIn`). Where tools are leaves, a dev server or address opened from
a Ports leaf goes beside that Ports leaf (`openPage(_:hostId:besideTool:)`), whichever leaf had
the focus, so Ports stays a list with its pages next to it; the port offer and a pane's link go
beside the focused leaf; a leaf already showing the page comes forward instead (`PortsLeafPlacementTests`).

Agents' browser tools (`BrowserAgent`) act on the page beside the agent's pane, the first
`browser_navigate` opening it. Pages carry two scripts (`BrowserAgentScript`). One runs in
every frame in an isolated content world: Playwright's injected script (`AgentBrowser/`, built
from a pinned commit by `apple/scripts/build-agent-browser.sh`) under ours (`agent.js`).
Snapshots are Playwright's aria tree as `role "name" [ref_N]` lines; a ref keeps its element,
and one whose element was re-rendered is found again by role, name and index. Actions wait until
the target is visible, enabled and still, check that their point hits it (else name what covers
it), and send the event sequence of a real pointer or keyboard, one task per event (after
Playwright's WebView input; `textInput` makes typing native). The other script, in the page's
world, records console messages and fetch/XHR requests. After each action `BrowserAgentPage`
waits for what it started (a navigation up to 10 s, else its requests up to 5 s, then a quiet
DOM up to 3 s) and asks the page what changed; nothing changed means one retry with the
element's own `click()`, then a "no observable effect" answer saying what to try. Each action
is reported to `BrowserAgent.onAction` (`BrowserActionEntry`, with Playwright's selector and
locator) for recordings. Clicks that buy, pay or send, and submits of sign-in or
payment forms, wait for Allow on the page (or in the agent's own client when it supports MCP
elicitation); typing into password or card fields is left to the user (Done). Take Over stops
the agent's calls until Hand Back. Screenshots are the visible page at most 1280 px wide; their
pixels are the coordinates targets use.

Frames, windows, dialogs and files. Each frame, cross-origin ones too, announces itself to
`BrowserFrames` with its `WKFrameInfo`; snapshots inline a child frame under its iframe with
refs `ref_f<n>_<m>`, actions go to the ref's frame (`callAsyncJavaScript(in:)`), a screenshot
point over an iframe is moved into it, and labels draw in each frame. `WebPage` has no API for
new windows, so `BrowserWindows` stands in front of its web view's UI delegate: `window.open`
and `target=_blank` open a leaf beside the page (`openPopup`; popups are allowed only while an
agent acts, as its input carries no user gesture), and such a page's `window.close()` closes
its leaf. `alert`, `confirm`, `prompt` and file pickers hold the page as `BrowserPane.dialog` /
`fileChooser`: a card on the page lets the user answer, and tool results name it until
`browser_dialog` or `browser_upload` does. WebKit leaves pages without asking, so before a
navigation or tab close the app starts, `leavingAllowed` runs the page's `beforeunload`
handlers and asks the same way when one objects. Uploads set files as Playwright does
(`DataTransfer`, then `input` and `change`); a picker an action opened gets them as files.
A popup has no `window.opener` (it is a page of its own).

Tests: `BrowserLeafTests` (PaneLayout), `BrowserTests` (sign-in URLs), `BrowserAgentScriptTests`
(the page script on a fixture page: refs, deltas, refs found again, covered and disabled
targets, effects, typing and filling, secrets, what waits for the user),
`BrowserPageEventsTests` (pages served from two local origins: frames of both in snapshots,
actions, coordinates and labels; popups and `window.close`; each dialog; the leave check;
uploads into a field, a frame and a file picker),
`BrowserUITests` (iPad, `UI_TEST_CLASS=BrowserUITests apple/scripts/w3-ui-test.sh`: a sign-in
through `BROWSER`, a host page in a pane beside its terminal surviving a relaunch, an agent
driving a page with an approval on the device, learning what covers a button and what had
no effect, and an upload into a frame and a confirm answered by the agent and by the user).

### 21.1 Session Replay

Agents' browser sessions are recorded on the device (Settings ▸ Browser ▸ Record Agent
Sessions, on by default). `BrowserRecorder` takes each action from `BrowserAgent.onAction`
(`BrowserActionEntry`: tool, element ref/role/name/nth, Playwright selector and locator, URLs,
verdict), a JPEG of the visible page after it, and the page as rrweb events. A session is one
agent pane on one page, from its first action until 15 minutes without one. `ReplayStore`
keeps a folder per session (`session.json`, `events.jsonl`, `k<N>.jpg`) in Application Support,
at most 512 MB and 30 days in all (oldest first; never the session being recorded) and 96 MB of
events per session.

rrweb runs in its own content world (`gudo-replay`), in every frame, idle until the app
answers its hello with "record". An isolated world sees the same DOM (mutation observers, input
and scroll events), and the page sees nothing: no globals, no message handler in its world, no
patched prototypes. What it misses, style rules a page inserts through the CSSOM later, comes
back with a fresh full snapshot after actions (at most every 10 s). Frames from other origins
record themselves; their world's own `parent` sends their events to the app, which hands them
to the top frame's rrweb (its `message` listener is taken, never added to the page), so a page
never receives what its embedded frames (a payment form) recorded. Password and `cc-*` fields
are masked.

Session Replay (`SessionReplayView`, from the page's Replays button or More menu, an agent's
row in Agents ▸ Session Replay, the palette, or a `.gudoreplay` file opened in the app): the steps
(picture, tool, target, verdict) beside rrweb-player in its own `WebPage` (a throwaway data
store, no navigation, the recorded page in rrweb's script-less sandboxed frame; a session from a
file also loads nothing from the network). Play, pause, scrub (a tick per step), speed, and
previous/next step (← →, space); the list follows the playhead. In a leaf and on the Mac a
session opens in place over the Replays list with a back button in the tool's bar (as Files
browses in place: a push from a leaf would land in the window's navigation); an iOS sheet pushes.

Sharing: a `.gudoreplay` file (exported type `<bundle prefix>.gudoreplay`, opened by the app) is one
JSON document, `session` (the actions), `events` (rrweb) and `keyframes` (base64 JPEGs), the
same bytes for the same session. Export as Playwright Test (`ReplayPlaywright`) writes a
TypeScript test: `page.goto`, then each step on its recorded locator (`getByRole(…).click()`,
`.fill()`, `.check()`, `.selectOption()`, `keyboard.press`, `mouse.wheel`); without a locator it
falls back to role and name, then the screenshot coordinates, and says so in a comment. Replay
in Browser (`BrowserReplayRunner`) runs the steps again in a new tab by selector, healing by
role, name and index; steps that wait for the user are skipped, never approved.

Mac input (`BrowserNativeInput`): AppKit mouse, drag, wheel and key events handed straight to
the page's `WKWebView` (found by a token its content world carries), so the page gets trusted
events, `:hover` and menus that open on hover (WebKit takes buttonless moves only in the key
window), and pointer drags; the pointer on screen stays put. HTML drag and drop stays with the
page script: its system drag session follows the real pointer, so `drag` refuses a drag source.
Keys make the page first responder for the call and give the focus back. Agents' actions in
the top frame (click, double-click, hover, type, press, scroll, drag) use it when the page is in
a window: the page script still waits for the target, checks what covers it and reads the
effect, but lists the events (`native` in `act`) for the app to send. Frames, iOS (no public
equivalent) and pages off screen keep the script's events; `browser_drag` from an HTML drag
source always uses the script's DataTransfer drag.

Tests: `BrowserReplayTests` (store cap and age, `.gudoreplay` round trip and unsafe names,
Playwright export with and without locators), `BrowserRecorderTests` (a `WebPage` fixture with
a frame from another origin: rrweb's snapshot, mutations, masked input, nothing visible to the
page, playback in rrweb-player), `BrowserNativeInputTests` (Mac, a page in a window: hover,
clicks, drag, keys), `SessionReplayUITests` (iPad, `UI_TEST_CLASS=SessionReplayUITests
apple/scripts/w3-ui-test.sh`: `gudo-hook browser` drives a page, its Replays step through the
session and export the test).

## 22. Files app locations (File Provider)

Each paired host (owner hosts only; guests and plain SSH hosts are not offered) is a location in
the Files app: one `NSFileProviderDomain` per host, named after it, its home directory as the
root. The extension (`apple/FilesProvider`, an `NSFileProviderReplicatedExtension`) runs without
the app, so the app shares what dialling takes (`FilesShare`): `hosts.json` and the relay
settings in a folder of the App Group container, the tickets, this device's key and the relay
token in the shared Keychain group. `FilesLocations` publishes them whenever the hosts or the
relay settings change and adds, renames and removes the domains to match (`DomainPlan`).

Everything else is `FilesProviderKit` over the daemon's file RPCs (DAEMON.md §5.6-5.7):
- **Identity.** The daemon has no file ids that survive its own writes (an upload is a new
  inode), and Files wants an item to keep its identifier through renames, so identifiers are
  minted per path and saved (`ItemIdentifiers`): a rename or move made in Files keeps them, for
  the item and everything under it; a change made on the host reads as a delete and a create.
- **Items.** Files and folders (links to folders open as folders); sockets, FIFOs, devices and
  dangling links are left out; dot files are flagged hidden. The content version is the daemon's
  `inode-size-mtime_ns`, the metadata version adds the name.
- **Changes.** Folders from `FsMkdir`, new files uploaded with `create_new` (a name taken is a
  collision; with `mayAlreadyExist` the existing item is the answer), renames and moves with
  `FsRename` (never replacing), new contents uploaded with `if_match` on the version they were
  based on. If the host's file changed meanwhile both are kept: the host's under the name, these
  beside it as "name 2". Deletes go to the host's trash (Files' own delete is final, the host's
  trash is not); the home itself is refused.
- **Staying current.** No change journal: the working set is the folders listed lately (at most
  64) and what is in them, those folders are watched (`FsWatch`), and a watch event or a
  reconnect moves the sync anchor and signals the working set. Asked for changes since an older
  anchor, the enumerators answer `syncAnchorExpired` and the system lists again and works out
  what changed (`HostFilesSession`).

Builds: the extension builds by its own scheme (`FilesProvider`) and its kit is tested; the app
embeds it only with a paid team, which gives it a provisioning profile and the shared groups:
`FILES_PROVIDER = YES`, the groups in `Brand.xcconfig`, and `- target: FilesProvider` among App's
dependencies in `project.yml`. Free builds never embed it or add a location.

Tests: `FilesProviderKitTests` (`swift test` in `Packages/FilesProviderKit`, needs `cargo build
-p hostd`): items and hidden/link handling, identifiers through renames and moves and across
restarts, create without replacing, contents only over the version they came from (keep both),
fetch, delete into the host's trash, the working set, error mapping, what the app shares and the
domain plan, and the whole path against a real daemon (`DaemonFilesTests`: pair, share, dial as
the extension, browse, create, edit, rename, fetch, delete).

## 23. Projects (tab groups across hosts) and sidebar reordering

All the terminals of one app in one place, whatever host they run on (like Safari's tab groups,
or the iOS "drop onto an app to make a folder").

**Model.** A project is a named, coloured group of tabs: `ProjectInfo` (id, name, colour index,
order, updated) and per tab a `Membership` (project id, rank). Any tab can join: a daemon tab, a
tab on this device or a plain-SSH host, a window tab (mixed, VS Code, browser). A project exists
while it has tabs (Chrome), except one made from nothing (New Project): it waits empty in the
window (`HostGroups.emptyProjects`, saved with it) until its first tab joins, then lives on that
tab's host like any other.

**Only made on purpose.** A project is made by New Project (⌃⌘N, Safari's New Empty Tab Group;
File menu, the + menu, the Mac sidebar's footer and empty-space menu, the palette), New Project
from Tab, a drop onto a tab, or a suggestion's tap; never by anything else. A new terminal joins
one only when asked for from it: its header's + or New Terminal, or ⌘T while one of its tabs is
current (it lands right after that tab; `HostGroups.expectNewTab` / `claimNewTabs` take the
next tab that host makes, a daemon's a round trip later). The joined row lights in the project's
colour a moment and a collapsed project opens, so the join shows. A host's +, ⌥⌘T and the
palette's New Tab on Host make loose tabs. Restores never make one either: tab ids of this device
and of plain-SSH hosts start over each run, so the window keeps their memberships only within the
run that made them (`ProjectsState.launch`), and a plain-SSH host closed in the window drops
them (its next connection numbers tabs afresh).

**Names.** The repository root the tabs share (the daemon's repositories; on the Mac a `.git`
above a local tab's folder), else their folder, else "New Project" (`ProjectNaming`). Home and
every folder above it never name one (the host's own home where known, and `/Users/x`,
`/home/x`, `/root`… anywhere); OSC 7 directories are read as paths in both `file://` and
Ghostty's `kitty-shell-cwd://` form (read as a URL, a shell in home once named projects after
the user). Two projects never share a name: tabs grouped under a folder that already has a
project join it (one project for the same work; the drop label and the suggestion say "Add to
app"), and an explicit New Project or a rename to a taken name gets the next number ("app 2").
A project just made opens its name for typing at once, selected (Finder's New Folder, Safari's
New Tab Group); Return or leaving keeps it, Escape keeps the name it had. On iPhone an alert
asks for it.

**Sidebar.** Projects lead (after Agents, Hosts and Needs you), in their order, each a header
(colour dot, name, tab count when collapsed, + New Terminal) over its tabs in rank order, with a
2 pt thread of the project's colour down their leading edge. A project tab names its host on its
second line ("studio · cargo build") when the window shows more than one host. Below the projects,
every host keeps its own section with its loose tabs (and its repositories and agents): the host
header stays where connection state, + New Terminal, usage, agents, Retry and Disconnect live, so
nothing host-level moved. A host whose tabs are all in projects shows its header alone. Window
tabs not in a project stay under Mixed / VS Code / Browser. ⌘1…⌘9, ⇧⌘[ ], Go to Tab (whose rows
name the project) and the tab strip (a project's tabs carry its colour along their foot) follow
this order (`HostGroups.tabs`). Project colours are the theme's own ANSI hues softened like the
state colours (`ProjectColor`), so they sit in any theme.

**Gestures.** Drag a tab's row:
- onto the middle of another row: that row lights in the project's colour (the accent for a loose
  row; "will group", unlike the insertion gap) with a quiet label saying what the drop does
  ("Group", "Add to app"), and dropping groups them: into the row's project, or the project
  named for their shared folder, else a new one (see Names);
- onto the top or bottom of a row: the rows slide apart and the gap is where it lands; within a
  host section it is a reorder on the host, within a project a new rank, from a host section into
  a project it joins, from a project onto its host's section it leaves (a tab can only land in
  its own host's section: tabs live on their host; anywhere on another host's row groups);
- onto a project's header or an empty project's "Drag tabs here or press +" line: joins at the
  end (the header lights); a collapsed project springs open after 0.6 s; onto its host's header:
  leaves its project.
Drag a project's header to reorder projects. Menus (sidebar row, strip, compact switcher, Tab
menu): New Project from Tab, Move to Project ▸, Remove from Project; a project's header: Rename…
(in place), Colour ▸, New Terminal, Collapse, Ungroup, Close All Tabs (Delete Project for an
empty one). Keyboard: ⌃⇧⌘↑ / ⌃⇧⌘↓
(Tab ▸ Move Tab Up / Down; ⌃⌘arrows already move dividers, Ghostty) move the current tab within
its section; VoiceOver has Move Up / Move Down on each row. Suggestion: when two or more loose
tabs share a repository root (the daemon's repositories) or working directory, one quiet row
offers "Group 3 tabs in app" (one tap; dismissible, remembered per window; never automatic;
home folders do not count). Before the first project, while there are two tabs to group and no
suggestion, one small card teaches the gesture ("Group tabs into projects · Drop a tab onto
another tab, from any host."); its × or any first project retires it for good. Colours are
handed out far apart in hue (`ProjectInfo.colorOrder`: blue, orange, green, purple…) and are
the theme's hues barely softened, so neighbouring projects never look alike.

**Persistence and sync.** Daemon tabs keep their membership on the daemon (`LayoutOp::
SetTabProject` / `PutProject` / `RemoveProject`, pushed as `ServerCtl::Projects` to clients with
`Caps::PROJECTS`, behind `DaemonFeatures::PROJECTS`; DAEMON.md), in its layout.json too, so every
device of the owner attached to that session sees the same projects. The client merges every
host's report by project id: the newest `updated` wins a name, colour or order (an edit is
stamped after the copy it replaces, so two edits in one millisecond or a host's clock ahead never
lose one), ties broken by name. A rename, recolour or reorder of projects goes to every host
holding a member. Tabs without a daemon that keeps them (this device, plain SSH, window tabs,
older daemons) keep their membership with the window (`@SceneStorage("projects")`, JSON, and the
app's last copy), as their tabs do (this device's and plain SSH's only within one run, above). Guests: the daemon sends `Projects` only to connections with
the owner role and refuses the ops for any other role, so a guest sees plain tabs and never the
owner's grouping. Collapsed projects are per window.

**Optimism without double moves.** The old reorder collided for three reasons: every
`LayoutChanged` replaced the store's session wholesale, so an older echo (the focus the click sent
just before the drag) put the tab back and the move's own echo moved it again; each row was its
own drop target with no live preview, so nothing made room while dragging; and the drop landed
without an animation. Now `DaemonLayoutStore` keeps the ops it applied optimistically that set a
state (focus, move, rename, project changes) until their `OpResult` arrives and replays them on
every layout and project report, so an echo can never show an order the user has left; a failed
op drops its change and shows the daemon's truth. The sidebar's tab list is one flat list
(`SidebarTabList`, items keyed by `TabRef`, so a row moving between a host and a project slides
rather than fading) under one drop target that hit-tests the rows' frames. While dragging it
draws the drop as a plan applied to its rows (`SidebarDrop`): neighbours slide apart with a
spring (`DS.Motion.reorder`, interruptible), the dragged row leaves a gap where it will land
(the system's lifted preview follows the pointer or finger), never sliding over its neighbours.
On drop the plan is committed to the stores in the same transaction that clears it, so the order
on screen does not change, nothing moves twice, and the row fades into its gap.

**iPad, iPhone, Mac.** The sidebar is the same on iPad, a foldable's open screen and the Mac
(drag with a long press on touch). The compact switcher lists each project as a menu section
("app · 2 hosts") before the window's and the hosts' loose tabs, each ending in New Terminal in
it, with the project items in the tab's menu and New Project in the + menu.

Tests: HostKit `ProjectModelTests` (definitions, last writer wins, merge across hosts, planner
for every gesture, suggestions), `SidebarDropTests` (edges, middle, other hosts, plans applied
to sections, loose order → session index), `ProjectStoreTests` (an old echo after an optimistic
move, a refused move, project changes shown at once and reconciled), `HostGroupsProjectTests`
(drops end to end, ⌘ order, a preview equals what the commit leaves, rename/recolour/reorder),
`ProjectNamingTests` (home and above, OSC 7 forms, repository roots, unique names),
`ProjectCreationTests` (new tabs, restores and reconnects never make or fill one; ⌘T/+ joins;
same-named grouping joins; empty projects),
`DaemonIntegrationTests.projectsComeBackFromTheDaemon` (a real daemon keeps them for the next
connection); App `ProjectSidebarTests` (the list while dragging is the list after the drop,
grouping, ⌘T in and out of a project, New Project, the drop label, keys); snapshots `MacSnapshotTests.testProjects` (frame sequences of a reorder, a drop,
"will group", a row joining another project) and `TouchSnapshotTests`; daemon and proto tests in
DAEMON.md.

## 24. Foldable (iPhone Duo)

The design is in DESIGN.md "Foldable".

### Reading the fold

iOS has no posture value (Apple DTS). The window reads two things, both public iOS 27.1 API,
through `FoldProbe` (`Windows/FoldProbe.swift`). It is a UIKit view that fills the window, so its
coordinates are the window's.

- **The hinge.** `UIHingeInteraction` calls back with the first state and every change. Its
  `UIHinge.Status` and `angle` become `HingeReading`; no update (or a nil hinge) means no foldable.
- **The fold.** `reservedRegions(kind: .division, options: .includeInactive)`, read in
  `updateConstraints()` so UIKit runs it again whenever the region moves. Inactive regions too, so
  a flat screen still says where its fold is.

`FoldGeometry` (`Model/Fold.swift`, plain values, no UIKit) turns those into a posture:

| Posture | Rule |
|---|---|
| `none` | no hinge (iPhone, iPad, Mac) |
| `folded` | status closed; or partly open, or unknown, with no fold in a phone-width window (the cover, half-closed) |
| `flat` | status fully open; or unknown on a regular-width window |
| `book` | partly open with an active division taller than wide (the fold runs top to bottom) |
| `tabletop` | partly open with an active division wider than tall (laptop) |

The angle is kept, but nothing is laid out by it: Apple calls its rate and precision system policy.

### Layout

`FoldLayout.plan` maps the fold to one of three layouts. `WindowModel.foldLayout` adds two rules:
an external display's copy and any compact-width window always get `standard`.

- **`standard`.** Whatever the window's width gives, as before. Used on the cover, in a Split View
  half (the fold lies outside the window), and on a flat inner screen held tall (Apple: scrolling
  content may cross a flat fold).
- **`pages(leading:gutter:)`.** A fold running top to bottom, open flat or as a book.
  - The left page ends at the fold's band. The band is the division frame with its margins, or
    12 pt over a flat fold (`flatGutter`); the right page starts after it.
  - Sidebar shown: the sidebar is the left page, exactly as wide, with no resize divider. The tab
    is the right page.
  - Sidebar hidden: Two Columns, one tab per page. On by default flat (the user's choice per window
    holds); always on in a book, so one column never runs under an active fold. Turning Two
    Columns on gives the left page to a tab (the sidebar hides).
  - The tab strip gives way to each page's header, so no chip sits on the crease.
  - A flat band shows the split divider's line down its middle; a book's crease is its own divider.
- **`deck(top:gutter:)`.** A fold running across, partly open.
  - The tab is the upper screen, without the sidebar.
  - `TabletopDeck` is the lower screen: the Inbox (approve, deny and reply inline), with a Keyboard
    button that gives the focused pane the keyboard.
  - The upper screen ignores the keyboard's safe area. The keyboard rises over the deck only, so
    the terminal never reflows for it.

A page or deck is used only if both sides hold at least a phone (320 pt pages, 200 pt deck
halves); otherwise the window stays `standard`.

**Placement.** Views place the fold against their own frame in window points:
- `WorkspaceView.regular` measures the window's frame, which its content cannot change;
- `FoldPages` (Two Columns) uses a `GeometryReader`.

So a leading vertical bar or inset moves the content, never the fold. An earlier version measured
the view's own origin; once its content overflowed, the two fed each other and the pages ran to
2700 pt.

### Continuity

Folding is a size and trait change, not a teardown (Apple DTS): the window model, workspaces,
panes and their terminal views live on.

- **Nothing rebuilt.** `updateFold` animates a layout change with `DS.Motion.fold` (0.4 s; none
  under Reduce Motion). Every layout keeps its views in place: the sidebar's width, an optional
  band, an optional deck. Two Columns' children keep their slots whether or not there is a fold.
- **One reflow.** `quietLayoutResizes(for:)` holds the grids through the animation, so each pane
  resizes once when it settles. The cols × rows overlay stays quiet for the animation plus the
  resize's round trip.
- **Same pane, same text.** The tab, focused pane, scrollback, cursor and the key bar's per-pane
  drafts (keyed by the pane's view) carry over. Two Columns keeps its tabs.
- **Hinge alone, no reflow.** An angle change that leaves the layout as it was does nothing.

### Input across the fold

- **Pages.** The key bar (the terminal's input accessory, in the keyboard's window) keeps to the
  page under the focused terminal (`FoldProbe.page(containing:)`, `KeyBar.foldPage()`). No key
  sits in the crease and the keys stay under the text they type into. Focus moving to the other
  page moves the bar with it.
- **Deck.** The keyboard and key bar sit on the lower screen; the terminal stays readable above.
- **Hardware only.** How the system keyboard splits on a half-folded Duo, and where it docks
  relative to the fold.

### Drag between pages

- A column's header drags (as a tab) onto the other page's header: the two trade places.
- Any tab dropped on a page's header shows there and takes the keyboard
  (`WindowModel.place(_:inLeftColumn:)`).
- Within a page, dragging a tab onto a pane's edge merges it there, as before (`TabDrop`).

### Test hooks

DEBUG only; the simulator folds only by hand in Device Hub.
- `-posture <none|folded|flat|book|tabletop>` at launch, or the Darwin notification
  `dev.gudo.debug.posture.<name>` at run time (`DebugPostures`;
  `xcrun simctl spawn <udid> notifyutil -p …`; `real` returns to the device's hinge).
- Either feeds `FoldGeometry.simulated` (the fold through the window's middle, a 24 pt band when
  partly open) through the same path as the real API.
- `-windowProbe YES` adds `posture`, `fold` (layout) and `hinge` to the probe's JSON.
- Real inner-screen sizes: `xcrun devicectl device appResize start --device <udid>
  --preferred-size 951x669` (or `669x951`; `appResize set` resizes it).

### Tests

- **`FoldTests`** (unit, any simulator):
  - posture from hinge and direction;
  - the cover, a Split View half and an unknown hinge;
  - each posture's layout;
  - the band covers the fold, and content starts outside it;
  - a fold too close to an edge;
  - placement relative to the view;
  - Two Columns per posture, and a book never running one column across;
  - a compact window keeps the phone layout;
  - dropping tabs on pages;
  - a full fold cycle keeping the tab, focus, pane objects and columns;
  - only a layout change holds the grids.
- **`DuoUITests`** (iOS, on an iPhone Duo simulator):
  - the closed Duo's real `UIHingeInteraction` reports `closed`, read as `folded` on the cover;
  - folding through every posture keeps the tab, the pane, its output and its size.

**Hardware only:**
- division margins (crease width) and when they turn active;
- the system's fold animation against ours;
- vertical bars on the wide inner screen;
- the split keyboard;
- 50/50 Split View;
- touch at the crease.

## 25. Tab history: what a window opens with, recently closed tabs, idle tabs, multi-select

Tabs behave like a browser's. Models in HostKit `TabHistory.swift`
(pure, unit-tested), window actions in `Model/TabHistoryActions.swift`, views in
`Views/TabHistoryViews.swift`.

**Opens with** (Settings ▸ Appearance ▸ Tabs, `launch-tabs`; Safari's "Safari opens with"):
*Your Previous Tabs* (default: today's restore) or *A New Terminal*. With the latter, every
window restored in the first seconds of a launch (`AppModel.isLaunching`; a later New Window
restores as before) opens its hosts as before, but the tabs each host reports first go into the
window's `HostGroups.hiddenTabs`: out of the sidebar, strip, ⌘-numbers and Go to Tab, still
running on their hosts. The rule (`RestoreDecision`): a tab with an agent (the daemon's agent
state, or any program's own status report) or a running command (a program in front of a local
shell; for daemon tabs, asked of the host: the foreground program is not the shell, or the
prompt is running a command) is never hidden: running work never leaves sight. Then one new
terminal opens: on This Mac's helper (or the Mac's own shell), on iPhone and iPad on the host
used last. "Restore N Tabs" at the top of the sidebar, History ▸ Reopen Previous Tabs, the
palette and the compact switcher bring them back; the row's × only hides the row. Selecting a
hidden tab any other way (an agent toast, a notification, Handoff) brings that one back.

macOS's "Close windows when quitting an application" is respected for what it governs: which
windows (their number, frames) the system brings back. It does not decide tabs: our sessions
outlive the app on their hosts either way, and the setting above is explicit and per app, so
the two never fight. Every window the system restores follows the setting.

**Recently closed** (`RecentlyClosed`, app-wide like Safari's History; this device only, never
sent to a host, so guests never see the owner's history and a guest's closes on someone else's
host are not kept): the last 20 tabs, newest first, in UserDefaults across launches. Each keeps
only what reopening needs: title and name, host id and name, the daemon pane id, its last
directory, the agent's kind, its project (id, name, colour) and its places in the project and
on its host, when it closed, and a batch id for tabs closed together. No terminal contents.
Every close of a host tab goes there: ⌘W on a tab's last pane, the row and strip menus, Close
All Tabs of a project, bulk close, the idle suggestion. Panes closed within a split are not
kept (tabs only). ⇧⌘T reopens the last close (a whole batch at once); History ▸ Recently Closed
lists them with "host · project · 12 minutes ago"; History ▸ Show All Recently Closed… (⌘Y,
Safari's Show All History) is the palette listing them, searchable; the palette's empty query
has a Recently Closed section. Undo on a close toast is the same reopen.

Reopening (`WindowModel.reopen`): on a daemon host, `DaemonConnection.reopenTab` sends `NewTab`
with `PaneLaunch::Reopen` for the kept pane (DAEMON.md "Persistence"), named as before; the
daemon resumes its Claude Code or Codex session or starts a shell in its last directory. Then
`HostGroups.place` puts the tab back at its place among its host's tabs and in its project at
its place; a project gone with its last tab comes back by name (and colour). On This Mac's own
shell or a plain-SSH host a new tab opens there (nothing outlived the close). A failed reopen
says why and keeps the entry.

**Keys.** ⇧⌘T is every browser's Reopen Closed Tab; Move Pane to New Tab moved to ⌥⇧⌘T
(⌥ for "take the pane along"). Both are menu items and terminal key commands on iPad.

**Idle tabs.** `IdleTabRule`: every pane of a daemon tab sits at its shell's prompt (asked of the
host), no agent or program report, nothing running, and the tab was neither shown on this
device (`TabTouches`, kept across launches; first sight starts the clock) nor had a command run
on the host from any device (the foreground's `since`) for 3 days. Checked 20 s after a window
opens, then every 30 minutes; never the tab on screen. One quiet row "Close N Idle Tabs";
tapping closes them as one batch (Undo, ⇧⌘T). Not Now restarts their clocks. Never automatic.

**Last tab.** Closing a host's last tab leaves its session (empty) on the daemon: the host stays
listed with its New Terminal row and the window shows the welcome view; Undo reopens into the
same session. The client also reconciles a session that disappears (`DaemonConnection` on
`Sessions`: tabs and pending ops dropped, attach anew), so a tab whose panes are gone can never
stay on screen. For the owner an input rejected for an unknown pane says "That terminal has
closed." (the scoped-invite wording is a guest's). A collapsed host shows the count of the
loose tabs the collapse hides, nothing when its tabs all live in projects.

**Multi-select** (`TabSelection`, Finder's rules; `WindowModel.clickTab`): ⌘-click toggles
(starting from the tab on screen), ⇧-click selects the range from the anchor in sidebar order,
⌘A (while a selection is up) selects every visible tab, Esc ends it; a plain click goes back to
one tab. Modifiers come from AppKit on the Mac and from the hardware keyboard
(`GCKeyboard`) on iPad. Touch: the row menu's Select Tabs enters Select mode (taps toggle, check
circles); iPhone: the switcher's Select Tabs… sheet. Bulk actions (row menu, the selection bar,
Tab menu, ⌘W): Close Tabs (one confirmation when any runs an agent or a command; one batch),
Move to Project ▸, New Project from Tabs. Dragging a selected row carries the selection
(`SidebarDrop.carrying`): inserts land in a run after the dragged row (a host section takes only
its own host's tabs), a group drop groups them all; the preview is the commit.

Tests: HostKit `TabHistoryTests` (restore decision × activity, the store's order, cap,
persistence and batches, what an entry keeps, idle rule incl. a command from another device,
touches, selection, carried drops, reopen placement into a project and on the host, a project
that went with its last tab, hidden tabs), `DaemonConnectionTests.aClosedSessionNeverLeavesItsTabsBehind`,
`DaemonIntegrationTests.closingTheLastTabLeavesTheHostEmptyAndUndoBringsItBack` (real daemon);
App `TabHistoryWindowTests` (what a close keeps, bulk close as one batch, clicks, dragging a
selection, "A New Terminal" and Restore, ⌘W and ⇧⌘T); snapshots `MacSnapshotTests.testTabHistory`
and `TouchSnapshotTests.testTabHistory`. The History menu is the system's menu and is not
captured by the in-process snapshots; the palette list shows the same entries.

## 26. Instant start: the saved workspace before the host answers

Opening the app must show the workspace as it was left, at once, never an
empty window waiting for the host (ARCHITECTURE.md §4 "Resume", §5 "Never a blank screen").

**What is saved, per daemon host** (`CachedWorkspace`, HostKit `WorkspaceCache.swift`): the layout
(tabs, split trees, names, zoom, the active tab and each tab's focus), the session id and name,
the projects, each pane's title, directory and size, and each pane's screen: the READY section
of a Ghostty snapshot of the app's own terminal (the same format the daemon sends, images left
out) plus the newest 32 KiB of scrollback records and how far the viewport was scrolled back.
Bounds: a screen over 256 KiB is not kept; 2 MiB of screens per host, the active tab's panes
first (focused first), then the other tabs in order; panes the layout no longer has go. Names
and the layout always stay.

**Where and how.** One file per host in Caches/<bundle id>/Workspaces (tests: the isolated
`AppData` folder): binary plist, LZFSE-compressed, behind a magic and a version. The folder is
0700 and excluded from backups, files are 0600, and on iOS written with
`completeUntilFirstUserAuthentication`. App Lock's cover hides the window as before, so a saved
screen is never shown while locked. A file is dropped when it is not the host's any more: another
daemon id (paired again), another session than the record's, an older format, older than 14 days,
unreadable; forgetting a host deletes it. **Guests:** a guest's view of someone else's host is
never saved or shown from disk (`HostsModel.openDaemon` skips guests; the writer skips them), so
nothing of the owner's terminals outlives the invite on the guest's device.

**When.** `WorkspaceCacheWriter` (App) saves a live, owned host 2 s after its layout, names,
projects or status change, every 30 s while its screens changed (`Pane.outputGeneration`), and
at once on background (scene phase) and quit (`applicationWillTerminate`). It never saves a host
while one of its panes still shows a saved screen. Screens are encoded off the main actor.

**Showing it.** `HostsModel.openDaemon` seeds the new `DaemonConnection` before dialling
(`seed`): `DaemonLayoutStore.isCached` holds the saved session (ops wait: there is no session to
send them to yet), `meta` the saved titles, and `cachedScreen(for:)` each pane's screen until the
daemon sends its own. `HostConnection.showsCachedLayout` lets `HostGroups` list the saved tabs
(`HostGroup.isCached`; `isReady` stays false, so New Terminal waits for the host). `Workspace`
makes its panes at once; `Pane` restores the saved screen into its terminal before the stream
starts, so the renderer draws it in the first frame. The panes are quietly marked: a wash of the
terminal background and half saturation (`SavedScreenOverlay`), "Connecting…" at the end of the
header's subtitle, the host's spinner after its 1 s grace; the connection overlay adds its notice
only after 2 s and never dims saved screens while connecting. Reconnecting, unreachable and
failure states are the existing ones (notice, dim, card at 40 s): a host that cannot be reached
keeps showing its saved workspace under them. A restored focused tab is selected synchronously
when the saved layout has it.

**Going live.** Panes subscribe before the attach, so the daemon's snapshot usually arrives with
or before its layout. Each snapshot replaces the terminal in place (same `Pane`, view and
surface: no layout change, no blank frame) and drops the wash with a short fade. The daemon's
layout replaces the saved one wholesale: tabs closed elsewhere vanish (the window's selection
hands over to a neighbour as for any closed tab), their saved titles and screens are dropped
(`DaemonConnection.reconcileCache`); saved projects stay until the daemon's own report, which
follows its layout, so they never blink out.

**Input before live.** Keys, pastes and mouse reports typed over a saved screen are held per pane
(`DaemonPaneBackend.holdInputUntilLive`), never queued in the core. When the daemon's screen for
that pane is on the terminal, the held input is sent as if typed then only if the screen reads
the same as the saved one the user typed at (visible text); otherwise, or after 30 s, or past
4 KiB, it is dropped and a toast says so ("What you typed while connecting wasn't sent: the
screen had changed."). A pane holding input shows "Sends when connected". So an approval prompt
that changed while connecting never receives the "y" meant for another.

**This Mac.** The helper usually already runs as a login item: `AppModel.connectEarly` dials it
in `AppModel.init`, before any window, when its `endpoint.json` names a live process with the
paired daemon id; the helper's own start (login item checks, pairing) runs as before and redials
at once a dial that started before it was up (a redial cancels a dial in flight). A connection
on its way shows nothing for a 1 s grace: no notice, no "Connecting to…" page, saved tabs at
full strength (`HostGroup.showsAsLive`). `LaunchTimeline` logs process start → first frame → live (category
`launch`). Numbers: docs/PERFORMANCE.md "Instant start".

**Scroll position.** A pane saved scrolled back keeps that position when it goes live: the
host's snapshot has only its screen, so `Pane` asks for older scrollback pages until the rows
above reach the saved distance from the bottom (or there are none), then scrolls there. Scrolling
or typing before then cancels it.

**The first frame.** `WindowRoot` makes the window's model in the scene's first update (a box in
`@State` makes it on first use), and `WindowContent` restores the window's hosts while its first
frame is built when nothing else is to be opened (no request, launch hook or Handoff), so the
first frame is the saved workspace rather than the terminal background or this device's shell.

**Not covered.** Plain-SSH hosts and this device's own shells (nothing outlives the app to come
back to; they start as before).

Tests: HostKit `WorkspaceCacheTests` (round trip incl. scrollback and scroll position, file
protection, bounds, invalidation, seeding and reconciliation with a changed layout, saved tabs in
`HostGroups`, guests, held input sent / dropped / overflow / a second window),
`DaemonIntegrationTests.instantStartShowsTheSavedWorkspaceThenGoesLive` (real daemon: saved
workspace at once, live in place, early input sent; prints the times); App `InstantStartTests`
(the first frame is the saved workspace with no host connected, drawn by the renderer, then
swapped in place; a restored window's first layout is its saved workspace; a scrolled-back pane
keeps its position going live; input before live; first-frame times); snapshots
`MacSnapshotTests.testInstantStart` (`instant-start-{cached,live}[-ipad]-{dark,light}`).

## 28. Floating panes (windows over a tab), rearranging by drag, zoom

The host keeps the model (DAEMON.md "Floating windows", `proto::float`): a floating window is a
subtree of its tab's tree with a frame in fractions of the tab, a z order, minimized and pinned
flags. The tree on the wire is unchanged, so a client without `Caps::FLOATS` shows the panes as
a split. Every change is a `LayoutOp` (`NewFloat`, `FloatPane`, `SetFloat`, `DockPane`,
`MovePaneToEdge`), so every device shows the same windows.

**Model (PaneLayout).** `Session` mirrors the daemon's rules for the app's own shells and for
optimistic updates: `floats` back to front, `tiledRoot(of:)` (the tree without its windows),
`root(of:)` (a window's subtree), raise on focus, cascade (`freeFrame`), a tab always keeps a
tiled pane, resizes only move dividers in the pane's own layer, a split inside a window joins
it (`adopt`), and `tidyFloats` restores the invariants after any change. `FloatGeometry` is the
arithmetic in points: snapping with guides, flick projection, resize limits, drop zones, the
tray's chips, picture-in-picture corners that avoid the fold. `DaemonLayoutStore` holds a
layout until its `Floats` push arrives so a new window never flashes as a split; float,
set-float and dock in place apply optimistically.

**Canvas (App, `Views/PaneCanvas.swift`, `Views/SplitTreeView.swift`).** `SplitTreeView` draws a
tab as one flat `ForEach` of panes keyed by pane id; `CanvasLayout` turns the session (tiled
tree, `FloatScene`, zoom, the canvas size, cell size and padding) into a frame, z, corner radii
and visibility per pane, divider frames per layer, window cards and tray chips. Because the
views never change identity, floating, docking, zooming, a drop and the tray are frame changes
animated by one spring; `ShapeMemo` picks `lift` (a pane changing layer) or `split` by what
changed. Before the first frame, every terminal the change resizes is told where it is going
(`PaneArrangement.prepareTerminals` → `TerminalSurface.prepareResize`): its grid changes then,
once (one SIGWINCH, so the shell redraws early), and its layer shows its last frame, anchored
top-left, until the view is within a point of its new size and the program's output has gone
quiet; only then does it draw, at its new size. No frame on the way reallocates a drawable or
reflows. A zoomed pane grows over its neighbours (z above them, `CanvasLayout.zoomZ`), which
stay laid out under it until it has settled; a new pane comes in under the panes making room
for it. A zoom is one critically damped spring (`DS.Motion.splitSpring`) from start to end:
against a host, `DaemonLayoutStore` replays a zoom the host has not answered as the state it
leads to (`Session.setZoom`), so the echo of an earlier op (the focus a header's Zoom button
sends first) never draws it undone mid-flight. The sidebar holds frames the same way without a known end (`holdFrames`) and changes
grids once it settles. A minimized window's panes sit hidden inside their chip's frame, so
restoring grows them out of it.

**Resize zones (`Views/ResizeZones.swift`).** Every divider (the sidebar's too) is held 6 pt
either side of its gap on a Mac and 22 pt on iPad (44 pt in all); a window's edges 6 pt outside
and 3 pt inside, its corners 10 + 8 (iPad 30 + 14, corners 30 + 22), mostly outside so its
header's buttons and the text at its edge stay within reach. The Mac shows the system resize
pointers; the iPad pointer highlights the line. A terminal sets its own pointer only where a
click would land on it (`AppKitTerminalView.isUnderPointer`), as its tracking area also hears
moves under the zones drawn over its edge.

**Arranging (`PaneArrangement`, one per window: `WindowModel.arrangement`).** Live state only:
frames of windows following the hand (`live`, not animated), snap `guides`, the dragged pane
(`paneDrag`: point, drop, lit region), the `preview` layout the drop leads to, a held window's
dock offer (`dockPreview`, after a 0.38 s dwell over a pane's outer quarter) and the `landing`
region kept lit until the pane arrives (until the host has moved the pane). A drop's outcome is
worked out by applying its op to a copy of the session (`outcome(of:)`, `CanvasLayout(session:
like:)`), so what is lit, and where the preview puts every pane, is what the host's layout will
be; the canvas draws the preview while dragging (terminals hold their frames, `holdFrame`) and
until the host's layout arrives. Zones come from the layout as it was when the drag began, with
12 pt of hysteresis. Gestures end in one op each: `movePane`, `movePaneToEdge`, `float`
(centred where let go), `dock`, `setFloat`.

**Stills.** A platform view (the Metal terminal) neither scales nor fades with its SwiftUI
parents, so a pane that changes layer or goes in or out of sight is drawn, for the length of
the motion, as a still of its last frame (`TerminalSurface.snapshot`, `PaneArrangement.stills`,
the `paneStill` environment value), with the live view hidden under it. The tray never resizes
a pane: its leaf keeps its window frame and is drawn shrunk onto its chip
(`CanvasLayout.shrink`), so no grid, and no program, sees a resize.

**Actions (`Model/FloatActions.swift`, `WorkspaceAction`).** Float/Dock ⌥⌘↩, Minimize ⇧⌘M, Next
Window ⌥⌘], Hide/Show Windows ⌥⌘F (per window, the host keeps them), Focus Next/Previous Pane
⌘] / ⌘[ (tiled panes in reading order, then windows front to back), Move Pane ⌥⇧⌘ arrows,
Split Best Fit ⌘↩; ⌃⌘ arrows resize a window. In the Pane menu, the palette's Pane section and
the iPad ⌘-hold overlay. A host whose helper predates floats says so in a toast.

**iPhone (`Views/PictureInPicture.swift`).** Compact width shows the focused pane alone; other
windows become picture-in-picture miniatures drawn at half scale at their own grid (never
resized, so the program and other devices keep their layout), resting in corners from
`FloatGeometry.pipCorners`, which on a foldable keeps them to one side of the fold.

**Not covered.** Mixed tabs (panes from several hosts) do not float: their layout is the app's
own composite and has no windows. A dragged pane cannot leave its host's session.

Tests: PaneLayout `FloatTests`, `FloatGeometryTests`; App `PaneArrangementTests` (drop
regions and their ops, every zone lighting exactly the frame its drop gives, a pane dragged out
of a two-pane split, zone hysteresis, edges, the Float target, snapping, dock after a dwell,
resize limits, the tray keeping a pane's size), `PaneResizeTests` (a zoom resizes a pane once,
before it moves), `ZoomMotionTests` (each edge of a zooming pane heads one way per display
frame, against a host whose layouts arrive on the way), `ResizeZoneTests` (zone geometry; a zone
over a terminal is the hit there); TerminalKit `LayoutMotionTests`; daemon `layout` unit tests and `tests/it/floats.rs`; snapshots
`MacSnapshotTests.testFloating*`, `TouchSnapshotTests.testFloating` (DESIGN.md "Floating
panes").
## 27. Agent accounts (DAEMON.md §5.15)

A host can keep several Claude Code and Codex sign-ins, such as Personal and Work. Each account is a directory on the host the agent is launched with. Signing in is the agent's own login in a terminal tab, which the user completes, so the app never sees a password or a token. A host without accounts looks exactly as before: nothing names an account until an agent has a second one.

**Model.**
- `DaemonWorkspace.accounts` (`AccountsReport`) is filled by the daemon's push (`WorkspaceEvent.accounts`, owner devices with `Caps::ACCOUNTS`) or by `loadAccounts()`. Views that only label panes call `loadAccountsIfNeeded()` once per connection.
- `DaemonWorkspace.accountUsage` is updated while usage is watched.
- `supportsAccounts` follows `DaemonInfo.accounts`.
- `AccountBook` (HostKit `Accounts.swift`) is the pure reading of a report:
  - `resolve(agent, project:, override:)`: the tab's pick, else the project's default, else the host's, else the system account. A pick or default whose account is gone falls back to the next.
  - `paneLabel` (nil unless the agent has more than one account).
  - `limitHint`.
  - `defaultAccount`.
- `DaemonAccountsAPI` is the FFI's `account*` calls.

**Settings ▸ Agents ▸ Accounts** (`Views/AccountsSettings.swift`):
- One row per owned host, with a summary such as "Claude: 3 · Codex: 1". Each opens `HostAccountsView` (`SettingsPage.hostAccounts`).
- The page has one section per agent:
  - Each row has its colour dot, name, a Default badge, who it is signed in as ("sam@acme.example · Team · Acme"; "Not signed in" in the attention colour) and its tightest window.
  - The context menu has Sign In… / Sign In Again…, Use by Default, Rename…, and Sign Out and Remove… (confirmed; the agent signs out on the host before the folder goes).
  - Add Claude Account… / Add Codex Account… open a name-and-colour sheet. "Add and Sign In" makes the account and opens the agent's login in a new tab on the host, revealed: `account_sign_in`.
- Codex uses `--device-auth` unless the host is this Mac (`AccountHosts.usesDeviceCode`).
- The footer says what isolation means: a folder only the user can open on that host.
- Search finds it ("accounts", "sign in", "work").
- Guests never see it, because the daemon refuses them.

**Choosing.**
- New Agent shows an Account picker when the agent has more than one account on the chosen host.
  - It defaults to the current tab's project default, else the host's (`WindowModel.currentProjectId`). The pick is per host and agent, and only for that launch.
  - `AgentLaunchRequest.account` → `AgentLaunch.account` → `PaneLaunch::AccountAgent`.
- A new worktree task follows the host's default, shown read-only. `TaskCreate` is frozen on the wire; this is a follow-up.
- Project and host defaults are set on the daemon (`account_set_default`, by every owner device alike). Resume always runs under the session's own account; the daemon enforces this.

**Pane.**
- The header shows the account after the program: "Claude Code · ● Work" (`PaneAccountLabel`, the account's colour dot from the project palette).
- When the pane's account is at a plan limit and another account of the same agent is signed in and not limited, a quiet "At Limit" mark appears (`LimitHintMenu`). Its menu reads "Work is at its 5h limit · resets 14:20" and offers "New Tab with Personal" (`WindowModel.startAgent`). Nothing switches by itself and the running session stays where it is: automatic rotation is what Anthropic's "ordinary, individual usage" rules out.

**Mock.** `MockAccounts.book`, used under `-mock`:
- Claude: Personal (the system account, Max), Work (Team, Acme, at its 5-hour limit) and Side Project (signed out).
- One Codex account.
- The mock's Claude pane (pane 3) runs under Work.

**Tests and snapshots.**
- HostKit `AccountBookTests` cover the resolution order, removed defaults, labels only with a choice, the limit hint (and when it stays quiet) and the status words.
- App `AccountsTests` cover the fixture, project defaults, search and row words.
- Snapshots: `MacSnapshotTests.testAccounts`, run with `TEST_RUNNER_SNAPSHOT_ONLY=settings-agents,settings-accounts,account-pane` in dark and light.
