# Host daemon (`unnamed-hostd`) and client core

Status: MVP path working end to end on macOS and Linux (2026-10-18). Crates: `daemon` (library),
`hostd` (binaries `unnamed-hostd` and the `un-hook` shim), `client-core` (library), `un` (dev CLI).
Wire types live in `proto`; see its crate docs for the frame format and compatibility rules.

## 1. Model

Shared with the Apple app (same names on both sides):

```
Daemon ─┬─ Session "main" ─┬─ Tab (ordered) ── split tree ── panes
        │                  └─ Tab …
        └─ Session "work" …
Node = Leaf(PaneId) | Split { axis, ratio, first, second }
Tab  = { tab_id, name, root, focused: PaneId, zoomed: Option<PaneId> }
```

- `Axis::Horizontal` lays children out left → right, `Vertical` top → bottom; `ratio` is the
  first child's share (clamped to 0.05–0.95). Split puts the new pane *after* the old one and
  focuses it.
- Ops (`proto::LayoutOp`): split, close pane, focus, focus direction, resize (moves the nearest
  divider on that axis), toggle zoom, new/close/move/select/rename tab, create/rename/close
  session. Closing a tab's last pane closes the tab; closing a session's last tab closes the
  session. A pane whose process exits is closed like `ClosePane`.
- The daemon is the source of truth. Every change bumps the session's `revision` and is
  view is the truth"). A client applies a layout only if its revision is not older than the
  one it has. `OpResult` is sent after the requesting client's `LayoutChanged`.
- Pane, tab and session ids are never reused and survive daemon restarts.

## 2. Architecture

```
            ┌──────────────────── unnamed-hostd (tokio, multi-thread) ───────────────────┐
 iroh  ───► │ accept loop ─► per connection: ctl reader, ctl writer, event forwarder,      │
 (QUIC)     │                input reader, port-forward splicers, one task per pane stream │
            │ Core: Layout (Mutex) · panes · broadcast<Event> · persistence (debounced)    │
            │ per pane task: VT events → title/cwd/prompt/echo hints/agent arbiter         │
            │ hook socket (Unix) ◄── un-hook ◄── Claude/Codex hooks                        │
            └──────────────┬──────────────────────────────────────────────────────────────┘
                           │ per pane: PtyActor (pty crate)
                           │   pty-io thread: poll → ring buffer (1 MiB, Seq-addressed)
                           │                  └ output hook → libghostty-vt Terminal (truth)
                           │   pty-wait thread: waitid
```

### Threading model

- **PTY threads** (from `pty`): two OS threads per pane. The I/O thread reads output into the
  ring and, under the ring lock, calls the output hook, which feeds the pane's authoritative
  `ghostty_vt::Terminal`, scans OSC 0/2/7/9/133/7501, and notes alt-screen changes. Terminal
  query replies (DA, DSR, …) go through a reply sink back to the PTY. Lock order: ring → VT;
  nothing calls into the ring while holding the VT lock.
- **tokio**: everything else. One task per pane (metadata, echo hints, agent arbiter ticks,
  exit), one accept loop, and per connection: `ctl` reader, `ctl` writer (coalesces queued
  messages into one write), an event forwarder (subscribed to the daemon's broadcast bus),
  the `input` reader, and one streamer task per subscribed pane. Snapshot encoding (≤ a few
  ms) runs on `spawn_blocking`.
- No `std::sync::Mutex` guard is held across an `.await`.


| Stream | Opened by | Priority | Content |
|---|---|---|---|
| `ctl` bidi | client, first | 100 | `Hello`/`Welcome`, attach, ops, layout, meta, echo hints, agent events, acks |
| `input` uni | client | 90 | `Input{pane, input_seq, principal, bytes}`, one write per frame |
| `pane/<id>` uni | daemon per subscription | 80 focused / 50 visible / 10 other | `Bytes`, `SnapshotZstd`, `Resized`, `InputAck` |
| forward bidi | client | default | `StreamHeader::PortForward{port}` → `ForwardReply` → raw bytes |


- Each pane stream tracks wire bytes in flight per frame (`InFlight`) against the client's
  cumulative `Ack{seq}` (client acks at most every 5 ms).
  path: focused 50 ms (64 KiB – 1 MiB), others 10 ms (16 – 256 KiB). Over budget the stream drops
  bytes and marks the pane dirty; once everything sent is acked it sends one snapshot and resumes
  bytes from the snapshot's `seq`. One frame always goes through when nothing is in flight.
  zstd level 3, cached per (seq, resize count) so many clients share one encode. Rate limit:
- **Resizes are in-band**: `Resized{seq, size}` is sent at its exact offset in the byte stream,
  so client VTs resize at the same point as the daemon's.
- `InputAck{input_seq, at_seq}` (the head when the input was written) goes on the pane's stream.


- The client keeps `(seq, snap_gen)` per followed pane (plus a VT mirror if enabled). On
  reconnect `Hello.resume` lists them, focused first; the daemon starts streaming those panes
  immediately, before reading anything else: from the ring if `seq` is still retained and
  `snap_gen` matches, else a snapshot. Resize records at or after `seq` are replayed (re-applying
  a size is harmless).
- `snap_gen` is the daemon run's epoch, so after a daemon restart every resume point is invalid
  and clients get snapshots.


`EchoHintAt{hint, at_seq, prediction}` is sent whenever termios ECHO/ICANON, the alt screen or
the OSC 133 prompt state changes, tagged with the output head. `proto::Prediction::decide`:
hidden input (`-echo icanon`) never; alt screen never; cooked with echo yes; raw mode only at a
shell prompt (after 133;B, before 133;C).

### Sizing

Each client sends its size per pane (`Resize`); the PTY follows the client that **last typed**
policy is always `LastInput` for now.


- `daemon.key` (Ed25519, iroh endpoint id), `owner.json` (the single owner principal),
  `devices.json` (allowlist: device key → principal), `pairing.json` (pending one-time secrets).
- A ticket (`proto::Ticket`, `unnamed://pair/<base32>`) carries the daemon id, direct
  addresses, home relay, owner principal, a 128-bit one-time secret and expiry. Dialing by key
  pins the daemon in the TLS handshake.
- `Hello.grant.v = PAIRING` presents the secret; success allowlists the device key (proven by the
  QUIC handshake). Later connections use `v = DEVICE`. `client-core` tries `DEVICE` first, then
  the ticket's secret. Principal ≠ device, input carries the principal and is rejected if it is
  not the connection's (`InputRejected{Role}`), roles are a bitset (MVP issues `OWNER`).

### Agents

- `PaneLaunch::Agent{Claude|Codex}` runs the adapter's launch recipe (`claude --settings
  <hooks> --session-id <uuid>`, `codex -c …osc9…`) through the login shell, then drops to a
  shell when the agent exits. Agents started by hand are detected from the foreground process.
- Each agent pane has an `Arbiter`. Inputs: hooks (via `un-hook` → Unix socket
  `<state>/hook.sock`, one JSON line each way, token-checked), OSC 9 and OSC 7501, screen
  manifests (every 500 ms after output), timers, process exit. Events go to clients as
- A Claude `PermissionRequest` hook is held open; the first client `Decide` answers it with the
  hook decision JSON (single-flight; later deciders get `AlreadyDecided`).
- Claude session ids are pinned at launch and persisted; on restart agent panes resume with
  `claude --resume <id>`. Codex ids are not reported by its OSC 9 notifications, so a Codex
  pane restarts fresh (follow-up: Codex hooks).

### Persistence

`<state>/layout.json`: layout plus per-pane `{launch, cwd, agent{kind, session_id}}`, written
atomically (tmp, fsync, rename, fsync dir) 500 ms after the last change and on shutdown. On
start the layout is restored with the same ids; shells restart in their last directory
(OSC 7), agents resume, one-off commands come back as shells. An unreadable file is moved
aside, never overwritten.

### Port forwarding

`Client::forward_port(local, remote)` listens on `127.0.0.1:local` on the device and opens one
forward stream per accepted TCP connection; the daemon connects to `localhost:remote`
(IPv4, then IPv6) and splices both directions with half-close. Only loopback targets exist.

## 3. Running it

```sh
cargo build --release -p hostd -p un

# Host
unnamed-hostd run                 # prints a pairing QR + ticket if nothing is paired yet
unnamed-hostd pair                # new one-time ticket (QR + text), valid 10 min
unnamed-hostd status
unnamed-hostd service install     # systemd --user (Linux) / LaunchAgent (macOS)
unnamed-hostd service uninstall
#   --state-dir DIR (or $UN_STATE_DIR), run: --bind ADDR, --no-relay, --shell PATH
#   logs: UN_LOG=debug

# Client (anywhere)
un pair 'unnamed://pair/…'        # saves the ticket and a device key under ~/.config/unnamed
un attach                         # focused pane in this terminal; follows focus; Ctrl-] detaches
un ls
un split [-v] [--agent claude|codex]
un focus left|right|up|down|<pane>   un zoom   un close   un resize h|v <delta>
un tab new [name]|close|next|prev|select <n>|move <n>|rename <name>
un session new <name>|rename <name>|close      un -s <name> attach
un forward <remote-port> [--local <port>]
#   --no-relay for direct-only; --ticket to override the saved one
```

`un attach` proxies raw bytes, so the local terminal also answers queries the remote program
sends (the daemon's VT answers them too); a program that queries in a loop may see doubled
replies. It is a test tool; the app renders from its own VT.

Default state directory: `$XDG_STATE_HOME/unnamed`, else `~/.local/state/unnamed` on Linux and
`~/Library/Application Support/unnamed` on macOS. One daemon per state dir (`hostd.lock`).

### Cloud VMs and headless Linux

- Everything is plain text over SSH: `pair` prints a Unicode half-block QR (upper-cased ticket,
  alphanumeric mode) and the copyable ticket.
- **No inbound ports or security-group rules are needed.** Cloud VMs normally allow outbound
  UDP, so iroh hole-punches a direct path; where UDP is blocked the n0 relay over HTTPS (443)
  carries the connection. `--no-relay` is only for LAN/Tailscale setups.
- `service install` writes `~/.config/systemd/user/unnamed-hostd.service`
  (`Restart=on-failure`); run `sudo loginctl enable-linger $USER` once so it starts at boot and
  survives logout. Stopping the service ends the panes; the layout and agent sessions come back
  on the next start.
- Static binaries: `cargo zigbuild --release -p hostd -p un --target
  {x86_64,aarch64}-unknown-linux-musl` (zig 0.16, `cargo install cargo-zigbuild`). Stripped
  sizes: `unnamed-hostd` 18.7 MB, `un-hook` 2.3 MB (aarch64).

## 4. Tests and numbers

`cargo test -p daemon --test it` runs daemon and client in one process over iroh with relays
off: attach + echo, split with both panes live, disconnect/reconnect from the ring, eviction
forcing a snapshot, layout broadcast to two clients, port forward to a TCP echo server, daemon
restart restoring the layout, an agent permission answered from a client, and typing next to a
40 MB flood. `client-core`'s tests cover refusal, one-device tickets and mirror-less clients.

Loopback, release build, M5 Max, 3 runs each (Linux: OrbStack Ubuntu 24.04 arm64 VM):

| | macOS 26 | Linux |
|---|---|---|
| first attach: client endpoint bind, two handshakes (device refused, then pairing), attach, first snapshot | 22–26 ms | 3.3–3.5 ms |
| resume from ring (reconnect → missed output on screen) | 2.1–2.5 ms | 2.2–3.3 ms |
| resume after eviction (reconnect → snapshot on screen) | 3.2–3.3 ms | 4.4–4.8 ms |
| worst keystroke → echo during a 40 MB flood in a visible pane | 3.3–6.6 ms | 2.9–6.8 ms |

Cross-host (Mac ↔ OrbStack Linux VM, both directions) and relay-only (ticket stripped of direct
addresses, n0 relay, ~1.8 s to pair including relay setup) were exercised by hand with `un`.

## 5. Known gaps / follow-ups

- Key and mouse `InputPayload`s are rejected (`Blocked`): libghostty's key/mouse encoders are not
  wrapped yet. Paste is sent raw (no bracketed-paste wrapping).
- `bulk` history pages (scrollback older than READY) are not served yet.
- Grants are an allowlist placeholder (no signed grants, revocation UI, leases, presence).
- Snapshots are encoded in full then truncated at READY (libghostty has no READY-only encode).
  `size` test fails its "typical < 50 KB" assertion there: 148 KB for colored logs); zstd keeps
  the wire size small, but the cause (page layout) needs a look.
- `SetSizePolicy` is ignored (only `LastInput`). The ticket's relay URL is the one known at
  mint time; `endpoint.json` is refreshed as iroh's addresses change.
