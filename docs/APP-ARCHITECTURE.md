
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
| `AppModel` (App) | `hosts`, `lastError`, `localLayout` (this device's tabs, shared by windows), `openWindows` | `makeWorkspace(for:selecting:)` (a window's own workspace on a host; resolve on target change, never in `body`), `isHostOpen(_:elsewhereThan:)`, `endSharedPanes(of:)`, `handle(url:)` |
| `WindowModel` (App, one per window) | `destination` (terminal / inbox / hosts), `sheet`, palette (`paletteMode`: commands / go to tab / new tab on host) and search state, `groups: HostGroups`, `workspaces[groupId]` (one per open host, kept live), `target` / `workspace` (what the detail column shows), `currentTab: TabRef`, `connection: ConnectionState` (the shown host's status in design words, with when it went down), `hostName`, `hosts: any HostDirectory`, `agents: any AgentFeed`, `paneStatus: any PaneStatusSource`, `toasts` | `show(target)`, `focus(TabRef)`, `focus(pane:onGroup:)`, `newTab(onGroup:)`, `selectTab(shortcut:)` / `selectTab(offset:)`, `showHostPicker()`, `showTabFinder()`, `closeHost`, `restore(openHosts:collapsed:focus:)`, `addHost(mode:destination:)`, `retryConnection()`, `disconnect()`; windows (§17): `widthBucket`, `newWindow()`, `openInNewWindow(_:)`, `open(_ request:)`, `continue(_ payload:)`, `handoffMissing`, `close()` |
| `HostGroups` (HostKit, one per window) | `groups: [HostGroup]` (this device, then open hosts in open order, then hosts connected elsewhere: id, name, kind, `status`, `tabs`, `isReady`, `failure`), `tabs: [TabRef]` (the unified order), `openHosts`, `collapsed` | `open(id)` (never redials an open host), `close(id)`, `restore(ids)`, `tab(forShortcut:)`, `shortcutNumber(of:)`, `tab(after:offset:)`, `newTabHost(preferred:)` |
| `Workspace` (App, one per window per host) | `session` (the window's view: `WindowLayoutStore`), `sharedLayout`, `panes` (this window's terminals), `title(of:)` (the tab's name), `context(of:)` (agent task → program → shell title → repo:branch → directory), `canOpenTabs` | `apply(op)`; unnamed tabs get a friendly name (`FriendlyName`, sent as a rename so a daemon keeps it for every device) |
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

Multi-host windows (2026-10-19): a window shows every open host at once. `HostGroups` keeps the
window's open hosts; `HostsModel.connections` keeps one `HostConnection` per host for as long as it
is open, and `WindowModel.workspaces` one `Workspace` per open host (its panes stream in the
background, R12), so selecting a tab on another host only changes `WindowModel.target` — no dial
(`DaemonConnection.dials` counts dials; `MultiHostUITests` asserts it stays put while switching).
The iOS lifecycle is per app, not per window: `HostsModel.background()` suspends every connection,
`foreground()` resumes every one at once (R1/R3/R5); plain-SSH hosts still reconnect instead
(below). A failed `open` no longer leaves an idle connection behind: the group shows the reason
(`HostGroups.failures`). Per window, `WindowRoot` persists `openHosts`, `collapsedHosts` and
`focusedTab` (`TabRef`) in scene storage, mirrored to user defaults for new scenes; launch
reopens them and selects the tab once its host's layout arrives (`-restoreLastTarget NO`
disables restore; design fixtures, `-mock` and dogfood runs skip it).

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

`-testTicket <ticket>` pair and show; `-testTickets <t1>,<t2>` with `-testTicketNames a,b` pair
with several daemons and open them all in the window; `-hostsDirectory <path>` keeps saved hosts
and secrets in that folder (tests never touch the user's hosts or Keychain); `-connectionProbe
YES` exposes each open host's connection identity and dial count to UI tests; `-testSSH user@host[:port]` with `-testSSHKey <path>` or
`-testSSHPassword <pw>`; `-testTrustHostKeys YES`; `-testInstallHelper YES`; `-testRelay
disabled`; `-testMirror YES` (core VT mirror for pane text).

## 7. Tests

| | |
|---|---|
| `cd apple/Packages/HostKit && swift test` | unit tests with a fake `DaemonClientAPI` (layout conversion, store revisions/optimism, connection state machine, routing/buffering, prediction feed, hosts sorting/persistence, ssh_config import, keys, secrets) and `DaemonIntegrationTests` against a real local `unnamed-hostd` (pair, echo, split, daemon restart → stale → live, suspend/resume, re-dial by saved ticket) |
| `cd apple/Packages/TerminalKit && swift test --filter snapshot` | READY restore + history pages + live bytes |
| `apple/scripts/daemon-ui-test.sh [udid]` | `DaemonUITests` on the iPad simulator against a local daemon, killed and restarted mid-test |
| `apple/scripts/w3-ui-test.sh [udid] [test …]` | `W3UITests` on the iPad simulator against a local daemon set up by `w3-fixtures.sh` (HOME = a scratch dir with a git repo, a `claude` stand-in that drives the daemon's real hooks, a `code serve-web` stand-in): Files, Diff + notes, New Agent → Approve → finished summary → Reply → Open Pane → the turn's diff → review sent to the agent, Editor (workbench over the forward, ⌘P reaches the page, a path from Links opens at its line), a dev server offered and opened, Copy Last Command Output |
| `apple/scripts/multihost-ui-test.sh [udid]` | `MultiHostUITests`: two local daemons in one window; click and ⌘1/⌘2/⇧⌘[ switches with the same connections and no stale overlay, ⌘T on the current host, one daemon killed → its group reconnecting while the other stays live, then back |
| `HostGroupsTests` (HostKit) | the aggregation with fake connections: two daemons + one SSH host, open order, ⌘1–9 mapping, wraparound across hosts, status changes, no redial, lifecycle reaches every host, restore and failures |
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
| Key bar profile | `Workspace.reportedProgram`: backend-reported program, else the local PTY's foreground, else the daemon's agent kind; the title stands in otherwise |
| Share Session, presence, control, join, grants, audit | `MultiplayerSession` (§11): `Screens/InviteSheet.swift`, `Multiplayer/*` |
| Local notifications, actions, Live Activity | `Notifications/*` over `DaemonConnection.workspaceEvents` (§12) |


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
| Agents (`Screens/InboxView.swift`) | `LiveAgentFeed` | live agents from `PaneMeta.agent` merged with each host's attention feed (`attentionList`, `.attention` pushes): summaries of finished turns (`body`), failed agents and long commands whose pane is gone (history, newest 40), unseen dots and the per-host unseen count in the subtitle; on screen 1.5 s → `attentionSeen(up_to:)` on every device; Approve / Deny → signed `decide` with the option whose label says yes/no (whole words), shown as working until the daemon moves on; Reply… → `prompt(paneId:text:submit:)` (composer path); Open Pane → switch host, focus the pane, `attentionSeen(pane_id:)`; Mark Done hides it locally and marks it seen |
| New Agent (`Git/NewTaskSheet.swift`, ⇧⌘N) | `LiveAgentFeed.launch` | connected daemons; `launchAgentPane` in a new tab (`newTabIn`) in the host's focused pane's directory, or in a fresh `worktreeCreate` (own branch and `PORT`); the sheet closes as soon as the pane exists and the window shows it; the first prompt is typed through `prompt` once the agent reports idle (≤ 60 s, a toast says if it could not be) |
| Diff review (`Screens/DiffReviewView.swift`) | `LiveDiffSource` | `gitStatus` (repo, branch, ↑↓), `gitDiff` HEAD→worktree (untracked included) or staged, `listTurns` of the agent panes in the repo + `turnDiff` ("what this agent turn changed"); side by side on iPad/Mac (regular width; Layout menu: automatic/unified/side by side), unified on iPhone; monospace on the terminal background, palette green/red only; tap a line → note; notes → `sendReview` to the turn's agent (or the focused / first agent in the repo), Copy otherwise |
| Files (`Screens/FilesBrowserView.swift`) | `LiveFileSource` | `fsList` + `gitStatus` letters (a directory with changes inside gets M), `fsStat` / `fsRead` preview (UTF-8 text up to 1 MiB with line numbers, images up to 24 MiB, else a card), `fsWatch` (reloads on change), New Folder `fsMkdir`, Rename `fsRename` (never overwrites), Move to Trash `fsDelete(.trash)`, upload from the Files picker or by drop `uploadFile(createNew)` ("name 2.ext" when taken) with progress, download `downloadFile` → share sheet (iOS) / ~/Downloads + Finder (Mac); Open in VS Code, Reveal in Terminal (`cd`), Insert Path |
| Editor (`Screens/EditorView.swift`) | `LiveEditorSource` | `editorStatus` (is VS Code's CLI there?) → `openEditor(folder: <repo root or directory>, acceptVscodeLicense: true)` → a `WKWebView` on the forward, in an editor pane of the split tree (§20); steps "Set up VS Code on host (first run only) → Start the editor → Open the workbench" with seconds, never a licence prompt or sign-in, nothing about the VSCodium fallback; sessions kept per host+folder (closing leaves the server running; More → Stop Editor ends it, `closeEditor(stopServer:)`); a path from Links opens with `editorOpenInSession`; while an editor pane has the focus the app's ⌘ shortcuts step aside (except ⌘1–⌘9, ⌘W, ⌃⌘\`, §20) so every other key reaches VS Code |
| Browser (`Screens/BrowserPorts.swift`, `BrowserView.swift`) | `LivePortSource` | `ports` / `.portsChanged` (HTTP first, process and pane); a new HTTP port on the window's host is offered ("localhost:5173 is up · Open", 15 s); Open → `forward(localPort: <same port>, .tcp)` (any free port when taken here; existing forwards reused) → in-app browser with back/forward/reload/share/Open in Safari; palette lists "Open localhost:N" |
| Links & paths (`Screens/LinksSheet.swift`) | `LiveLinkSource` | `links(paneId:commands: 20)` (screen + the last 20 commands' output, paths resolved, missing ones dimmed); a path opens in VS Code at its line, a URL in the in-app browser (localhost through a forward); local panes: URLs and paths scanned from the visible text |
| Palette | `PaletteCommands` | Copy Last Command Output (`commandOutput`, the output without the prompt), Open in VS Code, Dev Servers & Ports, Open localhost:N |
| Scrollback search | `WindowModel.searchTotal` | the total over the whole scrollback from the daemon's `search` (debounced 180 ms); stepping through matches needs the renderer's highlights (not wired) |
| Acknowledgements | `SettingsView` | VS Code licence, VS Code Server licence, Microsoft privacy statement (`vscodeLicenseUrl()` …) |

Real host (Hetzner x86_64, 2026-10-19, iPad simulator, relays on): pair → connected 100 ms →
first paint 391 ms → `openEditor` (the `code` CLI installed from Microsoft in that call,
`installedCli: true`, VS Code itself, no fallback) ready 1066 ms after Open → workbench loaded
The 10–15 s first run of DAEMON.md §5.3 is a host without a cached VS Code server; this host
(`*-editor-first-run-*` is the `-mock` first-run state).

a turn that goes blocked → (approved) → idle gets no `AgentDone` attention item from
the daemon (DAEMON.md §5.8), so that row says "Waiting for your next prompt" without the agent's
last message; scrollback search shows the daemon's total but cannot step through matches;
uploads take files from the Files picker and drops (no Photos picker); "Open in Safari" for a
forwarded localhost page works only while the app keeps the forward (iOS suspends it in the
background); local (non-daemon) windows have no Files/Diff/Editor (they say so).



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
guest joined through the `un` CLI: presence, invite + QR, grants, revoke, audit; the script
then checks the guest's `un who --watch` was disconnected).


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
from `unseen`. Permission is asked the first time something would be posted. Settings ▸
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
other name as the user's. The test hooks no longer name hosts "test daemon" (`-testTicketNames`
still does). Hosts show "Ubuntu 24.04.1 LTS · x86_64" as their status line when idle.

Tests: `HelperVersionTests` (the rules, the manifest, machine names, placeholders, renaming once,
user names kept, advice following the connection, incompatible words) and
`HelperUpdateIntegrationTests` (a real local daemon installed as a copy: named after this Mac,
`.update` over the connection, `updateHelper` → restarted in place, layout and typing back;
about 2.5–3 s). Daemon side: `cargo test -p daemon --test it upgrade`.

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


`DaemonWorkspace.usage` holds a host's `AgentUsageReport` while something shows it:
`beginWatchingUsage()` / `endWatchingUsage()` count viewers (the first sends `usageWatch`, the
last `usageUnwatch`), only for daemons whose `DaemonInfo.agentUsage` is true; pushes
(`WorkspaceEvent.agentUsage`) update it; a reconnect re-watches. `UsageFeed` (`LiveUsageFeed`,
`FakeUsageFeed` for `-mock` / `-fakeUsage YES`) is what views read. HostKit's `UsageMeter` makes
the compact line ("Claude · 62% of 5h · resets 14:20": the limited, else fullest, window that has
not reset) and its tone (quiet ≤ 80 %, amber above, red limited); `UsageDetail` the popover rows.
Views (`UsageViews.swift`): one line per agent under each daemon host's name in the sidebar, the
detail popover (also from the host menu's Agent Usage), and a quiet strip at the bottom of the
Inbox. Unknown means absent; the reason is in the popover. Settings › Agents › Check Usage with
Your Claude and Codex Sign-In (`AgentUsageSettings.apiFallbackKey`, off) re-watches every host.
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
`Pane` (VT, renderer, view) — a view lives in one window only. The daemon keeps one subscription
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

Drawings ride along (2026-10-21): while a pane of the shown tab is in draw mode, or the focused
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
devices, same Apple Account, Bluetooth and Wi-Fi on; ad-hoc "-" signed Mac builds have no team
and cannot hand off); a daemon host continued on another device opens that device's attached
session, so the tab and pane are found only when both attach the same session (else the host
shows on its active tab). Drawing placements are routed per pane id by `DrawingHub`, so with a
pane in two windows only the newest window's controller gets placement updates (drawing owner).

Test status (2026-10-19, after merging main 8cf7810): `WindowsUITests` passes Handoff contents,
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

Two tabs side by side, each column its own tab (any host, or a mixed tab), a 1 pt divider and a
26 pt header per column. The current tab's column takes the keyboard; the other is dimmed like an
unfocused split. Columns stay put: a tab picked in the sidebar replaces the current column's,
focus moving into the other column swaps which is current, and a closed tab's column takes the
next tab not shown (or offers New Tab, which lands there). It turns on by itself on a phone
window that is regular both ways (`WidthBucket.isTwoSegment`: a foldable's open inner screen; a
phone's portrait width and landscape height are both under 600 pt); the user's choice per window
wins and is restored. Never in compact width.

Tests: `CompositeTabTests` (PaneLayout: tree mapping, split with host, ⌘D on a leaf, close,
answers, strays, host down, dissolve, timeout, close tab, round trip), `HostGroupsTests.
mixedTabsLeadAndHideTheirCarriers`, `WindowsTests.testTwoColumnsComeOnByThemselvesOnlyOnAnOpenFoldable`,
`MixedTabsUITests` (iPad: `apple/scripts/mixed-ui-test.sh` starts two daemons on 47421/47422 —
split with host, type in both, ⌘D/⌘W on beta, relaunch restores, kill alpha and beta keeps
working; Two Columns with this iPad's echo shell).

## 20. VS Code editor panes

editor was one full-window cover per window. It is now a pane kind of the split tree, like a canvas
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
- When the page cannot go on anyway — its web content process ended, or VS Code shows "Cannot
  reconnect" (a user script watches its dialogs) — the pane recovers by itself: the last snapshot
  under "Resuming VS Code", the source opened again (a new session when the server was replaced),
  the page loaded again (`EditorPane.recover`).

**Full screen.** ⌃⌘F (VS Code's own full-screen key on the Mac; the web workbench binds nothing to
it, so it passes the editor like ⌘W), the editor bar's Full Screen button, or the palette show the
focused editor alone: no sidebar, tab strip, toolbar, editor bar or status bar, the workbench edge
to edge (`WindowModel.isEditorFullScreen`, `FullScreenEditorView`; on iPhone the tab bar goes too).
The way back never takes a key from VS Code (Escape is its): ⌃⌘F again, or the top edge — a pointer
resting there or a tap brings up a glass Exit Full Screen button for three seconds. Full screen
belongs to that editor while it has the focus: ⌘1–⌘9 or Return to Terminal leave it. On the Mac the
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
- **⌘1–⌘9** (select tab / last tab): the way to any other tab. VS Code's own ⌘1–⌘8 only focus editor
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
sign-in sheet instead (`HostSignIn`).

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

Tests: `BrowserLeafTests` (PaneLayout), `BrowserTests` (sign-in URLs), `BrowserAgentScriptTests`
(the page script on a fixture page: refs, deltas, refs found again, covered and disabled
targets, effects, typing and filling, secrets, what waits for the user),
`BrowserUITests` (iPad, `UI_TEST_CLASS=BrowserUITests apple/scripts/w3-ui-test.sh`: a sign-in
through `BROWSER`, a host page in a pane beside its terminal surviving a relaunch, an agent
driving a page with an approval on the device, and learning what covers a button and what had
no effect).

### 21.1 Session Replay

Agents' browser sessions are recorded on the device (Settings ▸ Browser ▸ Record Agent
Sessions, on by default). `BrowserRecorder` takes each action from `BrowserAgent.onAction`
(`BrowserActionEntry`: tool, element ref/role/name/nth, Playwright selector and locator, URLs,
verdict), a JPEG of the visible page after it, and the page as rrweb events. A session is one
agent pane on one page, from its first action until 15 minutes without one. `ReplayStore`
keeps a folder per session (`session.json`, `events.jsonl`, `k<N>.jpg`) in Application Support,
at most 512 MB and 30 days in all (oldest first; never the session being recorded) and 96 MB of
events per session.

rrweb runs in its own content world (`unnamed-replay`), in every frame, idle until the app
answers its hello with "record". An isolated world sees the same DOM (mutation observers, input
and scroll events), and the page sees nothing: no globals, no message handler in its world, no
patched prototypes. What it misses — style rules a page inserts through the CSSOM later — comes
back with a fresh full snapshot after actions (at most every 10 s). Frames from other origins
record themselves; their world's own `parent` sends their events to the app, which hands them
to the top frame's rrweb (its `message` listener is taken, never added to the page), so a page
never receives what its embedded frames (a payment form) recorded. Password and `cc-*` fields
are masked.

Session Replay (`SessionReplayView`, from the page's Replays button or More menu, an agent's
row in Agents ▸ Session Replay, the palette, or a `.unreplay` file opened in the app): the steps
(picture, tool, target, verdict) beside rrweb-player in its own `WebPage` (a throwaway data
store, no navigation, the recorded page in rrweb's script-less sandboxed frame; a session from a
file also loads nothing from the network). Play, pause, scrub (a tick per step), speed, and
previous/next step (← →, space); the list follows the playhead.

Sharing: a `.unreplay` file (exported type `<bundle prefix>.unreplay`, opened by the app) is one
JSON document — `session` (the actions), `events` (rrweb) and `keyframes` (base64 JPEGs) — the
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

Tests: `BrowserReplayTests` (store cap and age, `.unreplay` round trip and unsafe names,
Playwright export with and without locators), `BrowserRecorderTests` (a `WebPage` fixture with
a frame from another origin: rrweb's snapshot, mutations, masked input, nothing visible to the
page, playback in rrweb-player), `BrowserNativeInputTests` (Mac, a page in a window: hover,
clicks, drag, keys), `SessionReplayUITests` (iPad, `UI_TEST_CLASS=SessionReplayUITests
apple/scripts/w3-ui-test.sh`: `un-hook browser` drives a page, its Replays step through the
session and export the test).
