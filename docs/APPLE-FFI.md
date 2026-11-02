# Apple FFI (`crates/apple-ffi` → `GudoCore`)

Status: working on macOS (Swift tests against a local daemon and the Linux VM), iOS device and
simulator slices build and link; 2026-10-19. ARCHITECTURE D6: the Swift app talks to the Rust core
through UniFFI (0.32, proc-macro mode, no UDL). Swift owns UI, rendering, lifecycle, keys and
persistence; the core owns connections, SSH, resume.

```
crates/apple-ffi (lib name gudo_core)        apple/Packages/GudoCore (Swift package)
  client.rs   DaemonClient, ClientEvent,          GudoCore.xcframework   (generated, gitignored)
              ClientEventListener                 Sources/GudoCore/
  ssh_api.rs  SshSession, SshPane, keys,            GudoCore.swift       (generated, gitignored)
              known_hosts, ssh_config,              Streams.swift           (AsyncStream adapters)
              bootstrap                           Tests/GudoCoreTests/   (swift test)
  types.rs    mirrors of proto types
  workspace.rs  git, worktrees, files, transfers,
                ports, attention, agent launcher
  ws_types.rs   mirrors of proto::workspace
  editor.rs   serve-web default flow, tunnel,
              desktop links
  mp.rs       invites, roles, leases, presence,
              grants, audit
  notify.rs   push keys, register, NSE open,
              lock-screen actions
  artifacts.rs  drawings, images, Excalidraw,
                placements, send to agent, blobs,
                on-device drawing helpers
  art_types.rs  mirrors of proto::artifact
  assist.rs   input assistance (prompt state,
              submit, history, completion,
              file search, blocked options)
```

## 1. Building

```sh
cargo xtask build-xcframework               # iOS + iOS simulator + macOS, arm64, release (~2 min cold)
cargo xtask build-xcframework --macos-only  # enough for `swift test` on a Mac
cargo xtask build-hostd-linux               # apple/build/hostd/gudo-hostd-{aarch64,x86_64}-linux.gz
cargo xtask build-hostd-macos               # apple/build/hostd/macos/gudo-hostd (This Mac's helper)
```

`build-xcframework`:

1. `cargo build --release --lib -p apple-ffi --target …` for `aarch64-apple-ios`,
   `aarch64-apple-ios-sim`, `aarch64-apple-darwin` (`CARGO_PROFILE_RELEASE_DEBUG=false`,
   deployment targets iOS/macOS 26). libghostty-vt is built by `ghostty-vt-sys` with Zig for each.
2. Swift bindings with `uniffi_bindgen`'s library mode from the macOS archive's metadata; names
   from `crates/apple-ffi/uniffi.toml` (module `GudoCore`, C module `GudoCoreFFI`).
3. Per slice, **hides everything but the UniFFI API** (§4) and strips debug info.
4. `xcodebuild -create-xcframework` → `apple/Packages/GudoCore/GudoCore.xcframework`, and
   copies the generated `GudoCore.swift` into the package.

The app depends on the local package `apple/Packages/GudoCore` (product `GudoCore`). Rebuild
the xcframework after any change to `apple-ffi`, `client-core`, `ssh` or `proto`; the generated
Swift and the binary must come from the same build (UniFFI checks API checksums at first use and
traps on a mismatch).

`build-hostd-linux` runs `cargo zigbuild --release -p hostd` for both musl targets with
`CARGO_PROFILE_RELEASE_STRIP=symbols CARGO_PROFILE_RELEASE_DEBUG=false` (rustc strips at link
time; macOS `strip` cannot process ELF) and gzips with level 9. The app bundles the two `.gz`
files as resources and passes their paths to `SshSession.bootstrap` (gzip is detected and
inflated in Rust).

The package's target links CoreFoundation, Network (netdev's path monitor on iOS), Security,
SystemConfiguration and libresolv; the app gets them through the package. The library inside
the xcframework is named `libGudoCoreFFI.a` (a `libGudoCore.a` would collide with
SwiftPM's own product for the `GudoCore` target).

Requirements: Xcode (iOS SDKs), Zig 0.17, `rustup target add aarch64-apple-ios
aarch64-apple-ios-sim` (in `rust-toolchain.toml`), `cargo install cargo-zigbuild` for the daemons.

## 2. API

Everything below is generated Swift; Rust names are snake_case, Swift camelCase.

Byte payloads (`PaneBytes`, snapshots, history, keys, exec output, daemon builds) are Swift
`Data`. On the Rust side they are `gudo_core::Bytes`, which declares UniFFI's `Vec<u8>` wire
type but converts with one `memcpy`: UniFFI's stock converter is the generic `Vec<T>` one and
moves bytes one at a time (§5). `sendInput` takes `&[u8]`, which Swift passes without copying.

### Daemon connections

| | |
|---|---|
| `generateDeviceKey() -> Data` | 32-byte device key; the app keeps it in the Keychain |
| `DaemonClient.connect(ticket:config:listener:) throws(ClientError)` | dial by `gudo://pair/…` ticket, keep the connection up, resume followed panes |
| `ClientConfig(secretKey:relay:mirrorVt:)` | `relay: .default / .disabled`; `mirrorVt: false` when the app feeds its own VT |
| `attach(sessionId:)`, `listSessions()` | |
| `op(op: LayoutOp) -> UInt64` | `.split / .closePane / .focus / .focusDirection / .resize / .toggleZoom / .newTab / .closeTab / .moveTab / .selectTab / .renameTab / .renameSession / .createSession / .closeSession`; answer: `.opResult(opId:outcome:)` |
| `subscribe / unsubscribe(paneId:)`, `setView(focused:visible:)`, `resize(paneId:size:)` | |
| `sendInput(paneId:data:)` | raw bytes, borrowed from Swift (no copy into a RustBuffer) |
| `sendKey(paneId:key: KeyEvent)`, `sendMouse(paneId:event:)`, `sendPaste(paneId:text:)` | encoded on the daemon for the program's modes |
| `search(paneId:query:cursor:limit:)`, `links(paneId:commands:)`, `commands(paneId:)`, `commandOutput(paneId:commandId:)` | return a request id; answers arrive as `.searchResult / .links / .commands / .commandOutput` (`page`/`links`/… or `error: RpcError`) |
| `fetchHistory(paneId:maxBytes:) -> Bool` | older scrollback as `.paneHistory` |
| `launchAgent(paneId:agent:axis:)`, `decide(requestId:optionId:)` | agent panes and approvals; agent state in `PaneMeta.agent`, raw events in `.agentEvent(paneId:json:)` |
| `paneText / paneTextAll / paneSnapshot / paneVt / paneSeq / paneScrollbackRows` | from the Rust VT mirror (`mirrorVt: true`) |
| `reconnect()`, `suspend()` | network change / foreground; app suspended |
| `forwardPort(localPort:remotePort:) throws -> UInt16` | `127.0.0.1` → daemon host's `localhost` |
| `stats()` | counters |
| `daemonInfo() -> DaemonInfo?`, `isIncompatible()`, `protocolLevel()`, `minDaemonProtocol()` | what the daemon said before `Welcome` (build, level, `selfUpgrade`, host name, OS, CPU); also `ClientEvent.daemonInfo`, `.incompatible` |
| `upgradeDaemon(path:build:progress:) async throws(UpgradeError)` | send a daemon build (raw or .gz) to the daemon, which checks, swaps and restarts into it (owner only); returns the new build's `DaemonInfo` |

`ClientEvent` mirrors `client_core::ClientEvent`: `daemonInfo, incompatible, connected, disconnected, refused, sessions,
attached, layout, paneMeta, paneClosed, paneBytes, paneSnapshot, paneResized, inputAck, echoHint,
agentEvent, opResult, paneHistory, paneHistoryGone, commandMark, commandFinishedUnseen,
searchResult, links, commands, commandOutput`. Split trees are flattened: `TabLayout.nodes[0]` is
the root, `LayoutNode.split(axis:ratio:first:second:)` holds child indices. Ids are `UInt64`.

`ClientEventStream` (hand-written, `Streams.swift`) is a listener exposing `events:
AsyncStream<ClientEvent>`; `SshStateStream` does the same for SSH session states.

### SSH

| | |
|---|---|
| `SshConfigFile.parse(text:home:localUser:)` | `~/.ssh/config` text (the app reads or the user pastes it); `hostAliases()` for import, `resolve(alias:)`, `target(destination:defaultUser:)` (ProxyJump chains expanded), `warnings()` |
| `parseSshDestination(text:)` | the "just ssh" field: `[ssh://][user@]host[:port]`, `[v6]:port` |
| `generateEd25519Key(comment:) -> GeneratedSshKey` | `privateKey: Data` (OpenSSH PEM, for the Keychain), `publicKey` (authorized_keys line), `fingerprint` |
| `inspectPrivateKey(pem:passphrase:)`, `privateKeyIsEncrypted(pem:)` | import checks |
| `SshAuth` | `.password`, `.keyFile(path:passphrase:)`, `.keyData(pem:passphrase:)`, `.signer(SshSigner)`, `.agent(socketPath:)` (macOS), `.interactive(SshInteractiveResponder)`; tried in order on every hop |
| `SshSigner` (Swift implements) | `publicKey()` + `sign(data:) throws(SignerError)`: the Secure Enclave P-256 key (raw `r‖s` or DER), may wait for Face ID |
| `KnownHostsStore(text:listener:)` | OpenSSH known_hosts in memory; `KnownHostsListener.changed(text:)` after every change, so the app persists it (Keychain); `check / add / pin / remove / toText` |
| `HostKeyPolicy` | `.strict`, `.acceptNew`, `.ask(delegate: HostKeyDelegate)`: `trustNewHost(key:)` (TOFU) and `trustChangedHost(key:expected:)` (key changed; `true` replaces the record, `false` → `SshError.HostKeyMismatch`). Pinned keys never ask |
| `SshSession.start(target:auth:knownHosts:hostKeys:options:listener:) throws(SshError)` | self-healing connection (docs/SSH.md §2); `state()`, `setForeground`, `networkChanged`, `reconnectNow`, `close`, `rtt()`; `SshSessionListener.onState` gets `SshConnectionState` (`.needsAttention(error: SshError)` carries the typed error) |
| `SshOptions()` | keepalive / timeouts / compression / background budget, all defaulted |
| `session.connected() async throws`, `session.exec(command:) async throws -> SshExecOutput` | |
| `session.openPane(options:listener:) -> SshPane` | plain-SSH fallback pane: **the same `ClientEvent`s as daemon panes** (`connected`, `paneBytes` with a running `seq`, `paneResized`, `disconnected`, `refused`, `paneClosed`); `sendInput / resize / close`; `tmuxSession` re-attaches after drops |
| `session.bootstrap(binaries:ticketMinutes:waitSecs:listener:) async throws -> BootstrapReport` | install/upgrade/reuse `gudo-hostd`, start it, mint a ticket (`report.ticket` → `DaemonClient.connect`); `BootstrapListener.onStep` progress; `HostdBinary.file(path:)` or `.data(data:)`, gzip or raw |


Requests are `async throws(WorkspaceError)` methods on `DaemonClient`; they run on the core
runtime and can be awaited from the main actor. Times are Unix ms (`*Ms`), ids `UInt64`,
payloads `Data`. Pushes go to a separate `WorkspaceListener` (`setWorkspaceListener`):
`WorkspaceEvent.portsChanged / fsChanged / attention / vsCodeTunnel`. Types mirror
`proto::workspace` one to one (`GitStatus`, `GitDiff`, `FileStat`, `DirListing`, `WriteTarget`,
`WorktreeInfo`, `AttentionItem`, `PortInfo`, …), in `crates/apple-ffi/src/ws_types.rs`.

The setter replaces the previous listener, so the app sets exactly one per connection
(`HostKit.WorkspaceEventHub`, `DaemonConnection.workspaceEvents`) and every feature observes
that. The generated `errorDescription` of `WorkspaceError` is Swift's reflection of the case;
`DaemonWorkspaceAPI` (the slice of `DaemonClient` the screens use) and `DaemonWorkspace` (ports,
attention, watches, pane RPC pairing; docs/APP-ARCHITECTURE.md §10).

| | |
|---|---|
| `forward(localPort:target:) throws(ClientError) -> UInt16` | `127.0.0.1:localPort` (0 picks) → `ForwardTarget.tcp(port:)` or `.unix(path:)` on the host; one QUIC stream per connection, survives reconnects; returns the bound port |
| `stopForward(localPort:) -> Bool`, `forwards() -> [ForwardInfo]` | |
| `ports()` (last push), `listPorts() async` | detected listening ports; changes as `.portsChanged` |
| `gitStatus(path:)`, `gitDiff(request:)` | `GitDiffRequest(path:base:files:context:hunks:)`, `DiffBase.head / .index / .staged / .rev / .mergeBase` |
| `listTurns(paneId:)`, `turnDiff(paneId:turn:context:hunks:)`, `sendReview(review:)` | what an agent turn changed; review notes typed into the agent as a prompt |
| `worktreeCreate / worktreeList / worktreeRemove / worktreeLaunch` | worktrees with their `PORT`; `worktreeLaunch` returns the new pane |
| `fsList / fsStat / fsRead / fsWrite / fsMkdir / fsRename / fsDelete / fsWatch / fsUnwatch` | ≤ 1 MiB reads/writes; `WriteTarget.ifMatch` for conflicts; watches end with the connection (re-watch after `.connected`) |
| `uploadFile(localPath:target:progress:)`, `uploadBytes(data:target:)`, `downloadFile(remotePath:localPath:offset:len:progress:)` | own stream at bulk priority; `TransferProgress.onProgress(done:total:)` per 64 KiB |
| `attentionList()`, `attentionSeen(seen:)` | the inbox and its unseen count; seen syncs to every device; changes as `.attention` |
| `perform(op:) async throws -> OpOutcome` | `op` that waits for its own `OpResult` (the event still reaches the listener) |

### Editor (DAEMON.md §5.3)

-> EditorSession`:

1. `EditorLaunch(choice: .auto)`: the daemon starts `code serve-web --host 127.0.0.1 --port <free>
   --connection-token <random>` in the folder (reused if one already serves it). `.auto` never
   switches to openvscode-server and never runs `code tunnel`.
2. No `code` CLI on the host: with `acceptVscodeLicense` the host downloads it from Microsoft
   (`vscodeCliInstall(acceptLicense: true)`, SHA-256 checked) and step 1 is retried; without it
   the call fails with `WorkspaceError.unavailable` saying what to do. No licence accepted →
   nothing is installed or started.
3. A local forward to the server, on the host's port number when it is free here (so the
   editor's own `localhost:<port>` URLs stay valid), else any port; an existing forward is
   reused.
4. Returns `url` = `http://localhost:<local>/?tkn=…&folder=…` for the `WKWebView`, the
   `localPort`, the `EditorInstance` and whether the CLI was installed now.
5. No editor choice in the app. `acceptVscodeLicense` defaults to `false`, so
   `openEditor(folder:)` is the whole call. With the licence accepted, if Microsoft's CLI cannot
   be obtained (download blocked, no build for the host) or cannot run there, the call falls
   back to VSCodium's Web Host (MIT, Open VSX, no prompt, no sign-in) by itself:
   `instance.kind == .vscodium` and `fallbackReason` says why (show a quiet note at most).
   `EditorSession.fallbackReason` is a new field that defaults to `nil`.

`acceptVscodeLicense` means the user accepted `vscodeLicenseUrl()` (the CLI) and
`vscodeServerLicenseUrl()` (serve-web) in the app. `closeEditor(session:stopServer:)`,
`editorOpenInSession(session:path:line:column:) -> String?` (a URL to load, `nil` when the file
opened in the window already showing). Lower level: `editorStatus / editorLaunch / editorStop /
editorOpen`.

**VS Code Remote Tunnel, opt-in fallback** (needs a GitHub/Microsoft sign-in, only on the
user's explicit choice): `vscodeTunnelStatus / vscodeCliInstall / vscodeTunnelStart /
vscodeTunnelStop / vscodeTunnelOpen`. The device code arrives as
`WorkspaceEvent.vsCodeTunnel(status)` with `status.state == .needsLogin(login:)`
(`verificationUrl`, `userCode`).

Desktop links (`client_core::vscode`): `vscodeRemoteSshUri(host:path:line:column:)`
(`VsCodeSshHost(host: "127.0.0.1", user:, port: <forward to .tcp(port: 22)>)` for an
iroh-only host), `vscodeSshAuthority`, `vscodeTunnelUri`, `vscodeTunnelWebUrl`,
`vscodeSshConfigEntry`; `microsoftPrivacyUrl()`.

### Agents

| | |
|---|---|
| `launchAgentPane(launch: AgentLaunch) async -> AgentLaunched` | Claude/Codex split off `splitFrom`, in a `worktree` (with its `PORT`), a `cwd`, or `resume`-ing a session; an optional first `prompt` goes through the composer path once `PaneMeta.agent` reports idle (`readyTimeoutMs`, default 30 s). A refused or late prompt is `promptError`; the pane exists either way |
| `launchAgent(paneId:agent:axis:)` | unchanged fire-and-forget op |
| `decide(requestId:optionId:)` | **signed**: client-core signs `"approval-v1\0" ‖ postcard(daemon, request, option, actor)` with the device key (`Decide.sig`, DAEMON.md §6.6) |

Agent state stays in `PaneMeta.agent` (`.blocked(requestId:summary:options:)`), raw agent
events in `ClientEvent.agentEvent(paneId:json:)`, decisions by anyone in
`MultiplayerEvent.decided`.

What any program in a pane says about itself (OSC 7501 or `status_set`: pi, opencode, scripts)
arrives as `ClientEvent.programStatus(paneId:status:)` with `ConnectOptions.programStatus` on;
`DaemonClient.programStatus(paneId:)` returns the latest `ProgramReport` (state, kind, app,
message, progress). `nil` once cleared, and for every known pane when the connection drops. A
blocked report has nothing to decide; the app lets `PaneMeta.agent` win where both exist.


Principal, device and grant ids are lowercase hex strings. Errors: `MultiplayerError`
(`forbidden`, `notFound`, `invalid`, `conflict`, `failed`, `disconnected`).

| | |
|---|---|
| `DaemonClient.join(invite:config:listener:)`, `joinWith(…options:…)` | join as a guest by link or QR text (any case, `#` fragment form too) |
| `inspectInvite(invite:) -> InviteInfo` | join card without dialling: inviter, label, roles, scope, expiry, uses |
| `createInvite(options: InviteOptions) -> CreatedInvite` | `roles: [Role]` (`.viewer / .prompter / .driver / .approver / .owner`), `scope` (`.daemon / .session / .tab / .pane`), `ttlSecs`, `maxUses`, `delegate`, `label`, `inviter`; returns `link`, `qrPayload` (upper-cased link → QR alphanumeric mode), `grantId`, `expiresMs`. A guest with `delegate` signs a narrower child |
| `setMultiplayerListener(listener:)` | `MultiplayerEvent.joined / participants / presence / lease / leaseRequested / inputRejected / forbidden / decided / alreadyDecided / revoked / peers / peerChanged` |
| `me()`, `participantList()`, `lease(paneId:)` | last pushed state, no round trip |
| `whoAmI()`, `participants()`, `setName(name:)`, `leases()` | |
| `takeControl(paneId:force:)`, `giveControl(paneId:to:)`, `answerControl(paneId:give:)`, `releaseControl(paneId:)` | `LeaseOutcome.granted / .pending(holder:) / .kept` |
| `prompt(paneId:text:submit:) -> UInt32` | composer path (sanitized; the prompter role's only input) |
| `setTyping(paneId:typing:)` | typing indicator |
| `listGrants()`, `listDevices()`, `revoke(target:)`, `audit(after:limit:)` | owner only; `RevokeTarget.grant / .device / .principal`; `AuditPage.chainOk` |
| `knockInvite(invite:config:options:name:listener:) -> KnockResult` | free function: knock and wait (cancel the Swift task to stop); `KnockListener.onWaiting(knockId:)`; `.admitted(invite:)` is the link to join with, `.denied`; `KnockError.invalid / unreachable / refused` |
| `pendingKnocks()`, `admitKnock(knockId:roles:sinceJoin:ttlSecs:) -> GrantInfo`, `denyKnock(knockId:)` | owner; events `knockAdded(knock:)`, `knockGone(knockId:outcome:by:)` |
| `approvalPolicy(sessionId:)`, `setApprovalPolicy(sessionId:policy:)`, `approvalPolicyCached()` | `ApprovalPolicy(mode: .anyApprover / .ownerOnly / .twoPerson / .claim, maxRisk: .readOnly / .edits / .any)`; event `approvalPolicy(sessionId:policy:)` |
| `claimApproval(requestId:claim:) -> ApprovalStatus`, `approvalStatuses()`, `riskOfTool(tool:)` | where a request stands (risk, held approvals, claim); event `approvalStatus(status:)` |

### Push (docs/PUSH.md)

| | |
|---|---|
| `generatePushSealKey() -> PushSealKey` | X25519 `secret` (Keychain group shared with the NSE) and `publicKey`; `pushSealPublicKey(secret:)` |
| `pushRelayRegisterBody(apnsToken:environment:daemonId:kind:) -> String` | JSON for `POST <relay>/v1/register` (the app posts it with URLSession; `defaultPushRelayUrl()`); the answer's `cap` goes into the registration |
| `pushRegister(registration:)`, `pushUnregister()`, `pushStatus()` | per daemon, over the connection; `PushRegistration(cap:sealKey:relayUrl:prefs:activityCap:)` |
| `openPushNotification(deviceSecret:sealed:) throws(PushError) -> PushNotification` | NSE: decrypt + verify the daemon's signature (check `daemon` is paired); `category` is the `UNNotificationCategory` id |
| `pushActionToken(token:)`, `sendPushAction(…) async`, `sendPushActionBlocking(…)` | lock-screen Approve/Deny on a one-shot connection signed with the device key → `Decided`; `PushActionError` |


Requests are `async throws(ArtifactError)` methods on `DaemonClient`; pushes go to an
`ArtifactListener` (`setArtifactListener`). Ids are `UInt64`, blob hashes 64 hex digits,
payloads `Data`. Types mirror `proto::artifact` (`art_types.rs`); the element types are
prefixed so they do not shadow Swift names: `DrawElement`, `DrawElementKind`
(`.stroke(tool:points:) / .shape / .text / .image`), `DrawStyle`, `InkTool`, `Pt`, `DrawOp`
(`.add / .move / .restyle / .setZ / .delete / .clear / .setTitle`), `ArtifactPreview`,
`SentToAgent`.

| | |
|---|---|
| `listArtifacts(sessionId:)`, `artifactCreate(create: ArtifactCreate)`, `artifactDelete` | `ArtifactCreate(sessionId:kind:title:space:anchor:image:ops:)`; `kind: .drawing / .image / .excalidraw`, `space: .canvas / .cells` |
| `artifactGet(artifactId:since:) -> ArtifactScene`, `artifactApply(artifactId:base:ops:) -> UInt64` | batches after `since` or every element; apply commits one batch, everyone gets `.changed` |
| `artifactScene(artifactId:) -> CachedScene?` | the client's cached copy (version, elements in draw order), kept in step with pushes and resynced after gaps / reconnects (`.synced`) |
| `artifactSetAnchor(artifactId:anchor:)`, `artifactSetPreview(artifactId:version:png:)` | `AnchorRequest(paneId:atSeq:fromBottom:)`; `RowAnchor.state` `.live / .detached(reason:)` |
| `artifactExport(artifactId:version:format:) -> ExportedFile` | `.png / .svg / .ascii`; `data` is PNG bytes or UTF-8 text; large PNGs come via the blob stream transparently |
| `inkLive(chunk: InkChunk)` | live points every ~16 ms (fire and forget); others get `.ink(InkLive)` with the author's `actor` |
| `blobUpload(sessionId:data:progress:) -> ImageRef`, `blobDownload(hash:progress:) -> DownloadedBlob` | own stream at bulk priority; `TransferProgress` per 64 KiB |
| `excalidrawGet(artifactId:since:)`, `excalidrawPut(artifactId:elements:appState:files:) -> ExcalidrawApplied`, `excalidrawScene(artifactId:) -> CachedExcalidraw?` | per-element reconcile (higher `version`, tie → lower `versionNonce`); `rejected` are the stored winners to `applyRemote`; remote changes arrive as `.excalidraw` |
| `place(request:)`, `placePng(request:png:)`, `unplace(placementId:)`, `listPlacements(paneId:)`, `placements(paneId:)` | inline placements (`PlaceRequest(paneId:artifactId:version:anchor:col:cols:rows:replace:)`); `placements` is the pushed state, no round trip |
| `importToPane(paneId:name:data:) -> Placement` | pasted / dropped image or `.excalidraw` file |
| `sendToAgent(paneId:artifactId:version:png:) -> SentToAgent` | `ArtifactError.NotAgentPane` for a pane without an agent |
| `canvasPanes(sessionId:)` | canvas leaves, as last pushed (`.canvases`) |
| `op(op: .split(paneId:axis:launch: .canvas(artifactId:)))` | a canvas split (`PaneLaunch.canvas`; `nil` = a new Excalidraw scene) |

`ArtifactEvent`: `created, changed(info:batch:), info, deleted, ink, canvases, excalidraw,
placed, unplaced, synced(artifactId:version:)`.

On-device helpers (the `drawing` crate, no connection): `packInkPoints(points:) -> Data` /
`unpackInkPoints(packed:)` (`InkPoint(x:y:pressure:altitude:azimuth:tMs:)`, ~6 B a point,
1/32 unit), `simplifyInkPoints(points:epsilon:)` (RDP keeping pressure swells),
`renderAscii(elements:space:maxCols:)`, `renderSvg(elements:space:title:)`,
`renderPng(elements:space:scale:background:)` (the daemon's CPU rasteriser),
`renderExcalidrawAscii(elements:maxCols:)`, `excalidrawElement(json:)` (reads `id`,
`version`, `versionNonce`, `isDeleted` for a put), `excalidrawWins(incoming:current:)`,
`sniffImage(data:) -> ImageInfo?`.

### Input assistance (DAEMON.md §8)

Requests are `async throws(AssistError)`; pushes go to an `AssistListener`
(`setAssistListener`): `AssistEvent.foreground(Foreground)` for panes of the attached session,
`.prompt(PromptState)` for watched panes. Text positions count Unicode scalars (use
`String.unicodeScalars`), not UTF-16 units.

| | |
|---|---|
| `watchPrompt(paneId:watch:) -> PaneAssist` | start/stop prompt pushes; returns the state now. Watches end with the connection: re-watch after `.connected` |
| `paneAssist(paneId:)`, `promptState(paneId:)`, `foreground(paneId:)` | state now (round trip) / last pushed (no round trip) |
| `PromptState(paneId:promptId:atSeq:phase:)` | `phase: .atPrompt(input: PromptInput) / .running(commandId:) / .unknown`; `PromptInput` has `text`, `cursor`, `confident` (prefill only when true), `doubt`, `suggestion`, `rightPrompt`, `shell`, `bracketedPaste`, `keymap` |
| `Foreground(paneId:pid:name:argv:profile:sinceMs:)` | `profile: .shell / .vim / .pager / .monitor / .tmux / .repl / .claude / .codex / .other` for the key bar; `classifyProgram(name:argv:)` offline |
| `submitLine(paneId:promptId:text:run:) -> UInt64` | atomic replace + Return as one write; refused with `AssistError.NotAtPrompt(state:)` (the state now, nothing written) when the prompt id is stale |
| `history(query: HistoryQuery) -> [HistoryEntry]` | `HistoryQuery(cwd:prefix:contains:sinceMs:limit:)`, frecency order |
| `complete(paneId:line:cursor:limit:) -> Completions` | replace `line[start..<end]` with `text`; `kind: .history / .path / .dir / .gitRef / .gitPath / .command / .flag / .snippet` |
| `fileSearch(query:root:limit:) -> FileMatches` | fuzzy, `.gitignore`-aware; `positions` for highlighting; `Denied` outside the allowed roots |
| `blockedOptions(paneId:) -> BlockedPrompt?`, `answerBlocked(paneId:index:label:)` | a blocked agent's options (`optionId` for the signed `decide`, `keys` for the dialog on screen) |

### Native password prompts (DAEMON.md §9)

Connect with `ConnectOptions(relayCaDer:askpass: true)` (`connectWith` / `joinWith`) to be sent
them. Pushes go to an `AskpassListener` (`setAskpassListener`): `AskpassEvent.prompt(prompt:)`,
`.closed(id:paneId:reason:)` (`AskpassCloseReason.answered(by:) / .cancelled(by:) / .timedOut /
.abandoned / .movedToTerminal`), `.detected(prompt:)`, `.detectedGone(paneId:)`, and `.reset`
when the connection drops (open prompts come back with the same ids after reattaching).

| | |
|---|---|
| `SecretPrompt(id:paneId:source:prompt:program:echo:retry:expiresAtMs:)` | `source: .sudo / .ssh / .git / .gpg / .other`; `echo` = a yes/no question (show what is typed); `retry` = the last answer was probably wrong |
| `answerAskpass(id:secret:)`, `cancelAskpass(id:)` | first answer wins; `AskpassError.Gone` if it closed first, `.Denied` without Driver |
| `typeSecret(paneId:secret:)` | secret + Return into a detected prompt; `.NotHidden` (nothing written) once the pane echoes again |
| `openAskpass()`, `detectedPrompt(paneId:)` | last pushed, no round trip; `looksLikePasswordPrompt(line:)` offline |

Secrets cross as `String` and are zeroed on the Rust side once sent.

### Relays

`DaemonClient.connectWith(ticket:config:options:listener:)` with `ConnectOptions(relayCaDer:
[Data])` trusts a private CA for self-hosted relays; `relayUrls` / `relayAuthToken` send every
daemon through the device's own relays instead of the ticket's. `inspectPairTicket(ticket:).relays`
says what the ticket asks for: `TicketRelays.default / .custom(urls:hasAuthToken:) / .disabled`
(docs/RELAYS.md); the app's own `RelayMode.disabled` still wins, and a `.disabled` ticket stays
direct. `setRelays(relay:options:)` applies new settings to a running client (redial on a new
endpoint; `askpass` is kept).

Errors are typed Swift enums: `ClientError` (`Ticket`, `Key`, `Io`), `SshError` (`Io`, `Protocol`,
`Timeout`, `Disconnected`, `AuthFailed{user,host,tried,allowed}`,
`HostKeyMismatch{host,expected,actual}`, `HostKeyRejected`, `Key`, `KeyEncrypted`, `Signer`,
`Config`, `Remote{status,stderr}`, `ChecksumMismatch`, `Bootstrap`, `Closed`), `SignerError`
(`Cancelled`, `Failed`) for the signer to throw, `WorkspaceError` (`Denied`, `NotFound`,
`Conflict`, `Invalid`, `Unavailable`, `Failed`, `Disconnected`, mirroring `proto::WsError`),
`MultiplayerError`, `ArtifactError` (`NotFound`, `Forbidden`, `TooLarge`, `Invalid`,
`NotAgentPane`, `Failed`, `Disconnected`), `AssistError` (`Denied`, `UnknownPane`,
`NotAtPrompt{state}`, `Invalid`, `NotFound`, `Failed`, `Disconnected`), `PushError` (`Malformed`, `Open`, `Signature`, `Json`, `TooLarge`,
`Expired`) and `PushActionError` (`Client`, `Token`, `Unreachable`, `Refused`, `Rejected`).

## 3. Threading

- **One runtime.** The FFI layer owns a single multi-thread tokio runtime (2 workers, threads
  named `gudo-core`, plus tokio's blocking pool), started on first use. Every
  `DaemonClient` (via `client_core::Client::connect_on`) and `SshSession` runs on it.
- **Nothing blocks the caller.** Synchronous methods queue work and return; `async` methods
  (`connected`, `exec`, `bootstrap`) spawn onto the runtime and await the task, so they can be
  awaited from the main actor. Releasing a `DaemonClient` aborts its tasks and closes the
  connection in the background; releasing an `SshSession` (and its panes, which keep it
  alive) closes it.
- **Callbacks** arrive on runtime threads, never the main thread:
  - `ClientEventListener.onEvent`, `WorkspaceListener.onWorkspaceEvent`,
    `MultiplayerListener.onMultiplayerEvent`, `ArtifactListener.onArtifactEvent`,
    `AssistListener.onAssistEvent`, `TransferProgress.onProgress`,
    `SshSessionListener.onState`, `BootstrapListener.onStep`, `KnownHostsListener.changed`: a
    runtime worker, in order, one at a time per client / pane / session / transfer. Return quickly (hop to the main actor or a render queue);
    a slow listener stalls that connection.
  - `HostKeyDelegate`, `SshSigner.sign`, `SshInteractiveResponder.respond`: the blocking pool,
    after the key exchange and before credentials are sent. These may wait for the user (a
    "Trust this host?" banner, Face ID).
- Listener protocols are `Sendable` (UniFFI 0.32): implement them as `final class`es with
  thread-safe state, as `ClientEventStream` does.

## 4. libghostty-vt in the app twice, and how it is resolved

`client-core` links libghostty-vt (via `ghostty-vt-sys`, built by Zig) for its VT mirror, and
the app links its own copy for the renderer (`apple/scripts/build-libghostty-vt.sh` →
TerminalKit's `CGhosttyVt`). Linked as-is, the Rust archive would export every `ghostty_*`
symbol, Zig's `compiler_rt`, and all of Rust std/crates; with the app's copy that is order-
dependent at best and, with `-all_load` (or any force-load), **141 duplicate symbols** (measured).

Decision: **the core's copy is private**. `xtask` prelinks each slice (`ld -r`) with an
exported-symbols list of only `_uniffi_gudo_core_*` / `_ffi_gudo_core_*`, so libghostty-vt,
compiler_rt and Rust std become local symbols of one object. The app keeps linking its own
libghostty-vt, and both copies coexist (checked by linking a binary with TerminalKit's archive,
the xcframework slice and `-all_load`: no duplicates). Details that keep it small:

- Members are pulled in from the API symbols (`-u`), as a final link would, not force-loaded:
  libghostty-vt's archive carries Zig's compiler_rt, which overlaps Rust's compiler_builtins.
- Hand-written assembly objects (ring, compiler_builtins' LSE atomics) are not marked
  `MH_SUBSECTIONS_VIA_SYMBOLS`; including them would unmark the prelinked object and stop the app
  linker from dead-stripping it (+6.6 MB text, measured). They stay separate archive members with
  their (versioned or standard) global names.
- Only debug info is stripped; local symbols remain so dead-stripping works per function.

Cost: two copies of libghostty-vt's code in the app (the core's VT is used only for the mirror
and pane text). Alternative, if size matters later: export `ghostty_*` from GudoCore as well
(add it to the exported list and ship the Ghostty headers in the xcframework) and drop the app's
own copy; that couples the renderer to the core's Ghostty pin, which is the same pin today.

## 5. Measurements (M5 Max, macOS 26, release)

| | |
|---|---|
| FFI crossing per `PaneBytes` event, Swift release build (`bench_pane_bytes`, no-op listener, Rust-side allocation and conversion subtracted) | 64 B: 3.1 µs · 4 KiB: 3.7 µs · 64 KiB: 14 µs |
| same, Swift debug build (`swift test`) | 64 B: 1.9–5.6 µs · 4 KiB: 6–15 µs · 64 KiB: 90–215 µs |
| same with UniFFI's stock `Vec<u8>` converter (debug), before [`Bytes`] | 64 B: 5.5 µs · 4 KiB: 20 µs · 64 KiB: 194 µs |
| xcframework (3 slices) on disk | 109 MB (gitignored; static archives with symbols for dead-stripping) |
| per slice (`libGudoCoreFFI.a`) | 36 MB (raw Rust staticlib: 185 MB) |
| app size delta, iOS arm64 (every UniFFI function referenced, `-dead_strip`, stripped) | 14.5 MB file, 13.7 MB `__TEXT` (macOS: 14.9 MB) |
| … of which the symbol hiding costs | +0.25 MB `__TEXT` vs. linking the raw archive |
| `cargo xtask build-xcframework` | cold ≈ 4 min (3 × Zig libghostty-vt + Rust release), warm 20–35 s |
| `cargo xtask build-hostd-linux` | cold ≈ 6 min; 18.3 → 7.7 MB (aarch64), 20.0 → 8.2 MB (x86_64) |

The fixed ≈3 µs per event is UniFFI's callback path (handle lookup, buffer lift, enum
construction); the per-byte part is a few bulk copies (Rust buffer → `Data` → `[UInt8]` →
`Data`). At a 64 KiB frame that is ≈4.5 GB/s, far above any link. The size delta is above the
libghostty-vt.

## 6. Tests

```sh
cargo build -p hostd                       # the Swift tests spawn target/debug/gudo-hostd
cargo xtask build-xcframework --macos-only
cd apple/Packages/GudoCore && swift test
# SSH (OrbStack VM `un-linux`): scripts/ssh-test-vm.sh, then
source ../../../target/ssh-test/env && swift test --filter SshTests
```

- Rust, `cargo test -p apple-ffi` (`tests/workspace.rs`, an in-process daemon with `$HOME` in
  a temp dir and no `code` CLI): file round trip with upload/download progress, typed
  `Conflict`/`Denied`/`NotFound`; git status and HEAD diff in a temp repo; a forward to a local
  TCP echo server, then stop; invite + join with a second client (QR text inspected, `joined`,
  a viewer's keys refused with `inputRejected(.role)`, take-control forbidden, owner lists and
  revokes the grant, the guest gets `revoked`, audit chain ok); an agent turn's attention item
  marked seen and the push; editor status without a `code` CLI and `openEditor` without the
  licence → `Unavailable` naming the fix, no forward left behind; the VSCodium fallback (a
  blocked CLI download, a `code` that cannot run) and VSCodium asked for explicitly, with a fake
  `codium-server`; push register / status /
  unregister and the relay body.
- Rust, `tests/drawing_assist.rs` (same in-process daemon): **assist** with zsh — watch a
  pane, the shell's foreground profile, `echo h` typed and pushed, then `echo hi` read back
  (cursor, confident), `submitLine` runs it exactly once, a stale prompt id refused with
  `NotAtPrompt` carrying the new prompt, history has it once with exit 0, `complete("ec")`
  offers echo over `0..<2`, `fileSearch` finds a temp file (and `/etc` is `Denied`), no
  blocked options in a shell; **drawing** with two clients — create seen by the other, live
  ink (packed points, author actor, no echo to the sender), a stroke + rectangle batch arrives
  as `changed` and in the other client's cache, SVG and ASCII export (plus local ASCII), a
  device-rendered PNG uploaded and downloaded with progress, `placePng` seen as `placed`
  (`placements` and `listPlacements` agree), `unplace`, `sendToAgent` into the shell pane →
  `NotAgentPane`, an Excalidraw put pushed to and cached by the other client, delete.
- Swift `AssistDrawingTests` (zsh daemon with `HOME`/`ZDOTDIR` in its state dir): prompt
  state of a typed `echo hi`, `submitLine`, stale-prompt refusal, history, completion; a
  drawing created with a rectangle and an ink stroke, exported as SVG and ASCII.
- Swift `WorkspaceTests` (daemon with `[files] allow` set to its state dir): forward to an
  echo server, `fsList` / `fsWrite` / `fsRead`, invite + join as a viewer with refused input.
- Offline: keys, ssh_config + ProxyJump + destinations, known_hosts persistence callback, typed
  errors, the `PaneBytes` crossing benchmark.
- Daemon (`GUDO_HOSTD_BIN` overrides the binary): connect by ticket to a spawned `gudo-hostd
  --no-relay`, attach, input → echo, paste + Enter as a key event, split, search; and without the
  Rust mirror (bytes and snapshots still flow).
- SSH (enabled when `GUDO_SSH_TEST_HOST` is set): key auth with TOFU through the delegate and the
  known_hosts listener, exec, `SshPane` echo and close, bootstrap (prefers the gzipped
  `apple/build/hostd/*.gz` the app bundles) with progress, pairing by the returned ticket and an
  echo through the daemon; a changed host key goes to `trustChangedHost` and a refusal is
  `SshError.HostKeyMismatch`.

## 7. Not done / follow-ups

- `openEditor` with the licence accepted on a host without the CLI downloads from Microsoft;
  only the refusal path is tested here (the daemon's `tests/it/vscode.rs` covers the install
  with a fake update service). The serve-web page in a real `WKWebView` is not tested.
- `launchAgentPane`'s prompt-after-idle is not tested against a real Claude/Codex.
- Selections are not shared (live presence carries focus, viewport, drafts and following).
- `HostdBinary` data is inflated and re-gzipped for upload (≈0.3 s for 19 MB); the `ssh` crate
  could take pre-gzipped bytes directly.
- macOS daemon builds for bootstrapping Mac hosts are not produced by `xtask` (the `ssh` crate
  supports them; add `build-hostd-macos` when Mac targets are tested, docs/SSH.md §6).
- x86_64 simulator / Intel Mac slices are not built (arm64 only, ARCHITECTURE §6).
- `libc` is pinned to 0.2.189: 0.2.190+ declares `in6_ifreq` for macOS only and netdev 0.46
  (iroh → netwatch) uses it on iOS too.
