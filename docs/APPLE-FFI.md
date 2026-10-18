# Apple FFI (`crates/apple-ffi` → `UnnamedCore`)

Status: working on macOS (Swift tests against a local daemon and the Linux VM), iOS device and
simulator slices build and link; 2026-10-18. ARCHITECTURE D6: the Swift app talks to the Rust core
through UniFFI (0.32, proc-macro mode, no UDL). Swift owns UI, rendering, lifecycle, keys and
persistence; the core owns connections, SSH, resume.

```
crates/apple-ffi (lib name unnamed_core)        apple/Packages/UnnamedCore (Swift package)
  client.rs   DaemonClient, ClientEvent,          UnnamedCore.xcframework   (generated, gitignored)
              ClientEventListener                 Sources/UnnamedCore/
  ssh_api.rs  SshSession, SshPane, keys,            UnnamedCore.swift       (generated, gitignored)
              known_hosts, ssh_config,              Streams.swift           (AsyncStream adapters)
              bootstrap                           Tests/UnnamedCoreTests/   (swift test)
  types.rs    mirrors of proto types
```

## 1. Building

```sh
cargo xtask build-xcframework               # iOS + iOS simulator + macOS, arm64, release (~2 min cold)
cargo xtask build-xcframework --macos-only  # enough for `swift test` on a Mac
cargo xtask build-hostd-linux               # apple/build/hostd/unnamed-hostd-{aarch64,x86_64}-linux.gz
```

`build-xcframework`:

1. `cargo build --release --lib -p apple-ffi --target …` for `aarch64-apple-ios`,
   `aarch64-apple-ios-sim`, `aarch64-apple-darwin` (`CARGO_PROFILE_RELEASE_DEBUG=false`,
   deployment targets iOS/macOS 26). libghostty-vt is built by `ghostty-vt-sys` with Zig for each.
2. Swift bindings with `uniffi_bindgen`'s library mode from the macOS archive's metadata; names
   from `crates/apple-ffi/uniffi.toml` (module `UnnamedCore`, C module `UnnamedCoreFFI`).
3. Per slice, **hides everything but the UniFFI API** (§4) and strips debug info.
4. `xcodebuild -create-xcframework` → `apple/Packages/UnnamedCore/UnnamedCore.xcframework`, and
   copies the generated `UnnamedCore.swift` into the package.

The app depends on the local package `apple/Packages/UnnamedCore` (product `UnnamedCore`). Rebuild
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
the xcframework is named `libUnnamedCoreFFI.a` (a `libUnnamedCore.a` would collide with
SwiftPM's own product for the `UnnamedCore` target).

Requirements: Xcode (iOS SDKs), Zig 0.16, `rustup target add aarch64-apple-ios
aarch64-apple-ios-sim` (in `rust-toolchain.toml`), `cargo install cargo-zigbuild` for the daemons.

## 2. API

Everything below is generated Swift; Rust names are snake_case, Swift camelCase.

Byte payloads (`PaneBytes`, snapshots, history, keys, exec output, daemon builds) are Swift
`Data`. On the Rust side they are `unnamed_core::Bytes`, which declares UniFFI's `Vec<u8>` wire
type but converts with one `memcpy`: UniFFI's stock converter is the generic `Vec<T>` one and
moves bytes one at a time (§5). `sendInput` takes `&[u8]`, which Swift passes without copying.

### Daemon connections

| | |
|---|---|
| `generateDeviceKey() -> Data` | 32-byte device key; the app keeps it in the Keychain |
| `DaemonClient.connect(ticket:config:listener:) throws(ClientError)` | dial by `unnamed://pair/…` ticket, keep the connection up, resume followed panes |
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

`ClientEvent` mirrors `client_core::ClientEvent`: `connected, disconnected, refused, sessions,
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
| `session.bootstrap(binaries:ticketMinutes:waitSecs:listener:) async throws -> BootstrapReport` | install/upgrade/reuse `unnamed-hostd`, start it, mint a ticket (`report.ticket` → `DaemonClient.connect`); `BootstrapListener.onStep` progress; `HostdBinary.file(path:)` or `.data(data:)`, gzip or raw |

Errors are typed Swift enums: `ClientError` (`Ticket`, `Key`, `Io`), `SshError` (`Io`, `Protocol`,
`Timeout`, `Disconnected`, `AuthFailed{user,host,tried,allowed}`,
`HostKeyMismatch{host,expected,actual}`, `HostKeyRejected`, `Key`, `KeyEncrypted`, `Signer`,
`Config`, `Remote{status,stderr}`, `ChecksumMismatch`, `Bootstrap`, `Closed`), `SignerError`
(`Cancelled`, `Failed`) for the signer to throw.

## 3. Threading

- **One runtime.** The FFI layer owns a single multi-thread tokio runtime (2 workers, threads
  named `unnamed-core`, plus tokio's blocking pool), started on first use. Every
  `DaemonClient` (via `client_core::Client::connect_on`) and `SshSession` runs on it.
- **Nothing blocks the caller.** Synchronous methods queue work and return; `async` methods
  (`connected`, `exec`, `bootstrap`) spawn onto the runtime and await the task, so they can be
  awaited from the main actor. Releasing a `DaemonClient` aborts its tasks and closes the
  connection in the background; releasing an `SshSession` (and its panes, which keep it
  alive) closes it.
- **Callbacks** arrive on runtime threads, never the main thread:
  - `ClientEventListener.onEvent`, `SshSessionListener.onState`,
    `BootstrapListener.onStep`, `KnownHostsListener.changed`: a runtime worker, in order, one at
    a time per client / pane / session. Return quickly (hop to the main actor or a render queue);
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
exported-symbols list of only `_uniffi_unnamed_core_*` / `_ffi_unnamed_core_*`, so libghostty-vt,
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
and pane text). Alternative, if size matters later: export `ghostty_*` from UnnamedCore as well
(add it to the exported list and ship the Ghostty headers in the xcframework) and drop the app's
own copy; that couples the renderer to the core's Ghostty pin, which is the same pin today.

## 5. Measurements (M5 Max, macOS 26, release)

| | |
|---|---|
| FFI crossing per `PaneBytes` event, Swift release build (`bench_pane_bytes`, no-op listener, Rust-side allocation and conversion subtracted) | 64 B: 3.1 µs · 4 KiB: 3.7 µs · 64 KiB: 14 µs |
| same, Swift debug build (`swift test`) | 64 B: 1.9–5.6 µs · 4 KiB: 6–15 µs · 64 KiB: 90–215 µs |
| same with UniFFI's stock `Vec<u8>` converter (debug), before [`Bytes`] | 64 B: 5.5 µs · 4 KiB: 20 µs · 64 KiB: 194 µs |
| xcframework (3 slices) on disk | 109 MB (gitignored; static archives with symbols for dead-stripping) |
| per slice (`libUnnamedCoreFFI.a`) | 36 MB (raw Rust staticlib: 185 MB) |
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
cargo build -p hostd                       # the Swift tests spawn target/debug/unnamed-hostd
cargo xtask build-xcframework --macos-only
cd apple/Packages/UnnamedCore && swift test
# SSH (OrbStack VM `un-linux`): scripts/ssh-test-vm.sh, then
source ../../../target/ssh-test/env && swift test --filter SshTests
```

- Offline: keys, ssh_config + ProxyJump + destinations, known_hosts persistence callback, typed
  errors, the `PaneBytes` crossing benchmark.
- Daemon (`UN_HOSTD_BIN` overrides the binary): connect by ticket to a spawned `unnamed-hostd
  --no-relay`, attach, input → echo, paste + Enter as a key event, split, search; and without the
  Rust mirror (bytes and snapshots still flow).
- SSH (enabled when `UN_SSH_TEST_HOST` is set): key auth with TOFU through the delegate and the
  known_hosts listener, exec, `SshPane` echo and close, bootstrap (prefers the gzipped
  `apple/build/hostd/*.gz` the app bundles) with progress, pairing by the returned ticket and an
  echo through the daemon; a changed host key goes to `trustChangedHost` and a refusal is
  `SshError.HostKeyMismatch`.

## 7. Not done / follow-ups

- No `tracing` bridge to `os_log` yet: Rust logs are dropped in the app.
- `HostdBinary` data is inflated and re-gzipped for upload (≈0.3 s for 19 MB); the `ssh` crate
  could take pre-gzipped bytes directly.
- macOS daemon builds for bootstrapping Mac hosts are not produced by `xtask` (the `ssh` crate
  supports them; add `build-hostd-macos` when Mac targets are tested, docs/SSH.md §6).
- x86_64 simulator / Intel Mac slices are not built (arm64 only, ARCHITECTURE §6).
- `libc` is pinned to 0.2.189: 0.2.190+ declares `in6_ifreq` for macOS only and netdev 0.46
  (iroh → netwatch) uses it on iOS too.
