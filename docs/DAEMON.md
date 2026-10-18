# Host daemon (`unnamed-hostd`) and client core

Status: MVP path working end to end on macOS and Linux (2026-10-18), plus terminal completeness
(key/mouse/paste encoding, history paging, shell integration, search, links, Codex resume), plus
attention feed).
Crates: `daemon` (library),
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
  `ghostty_vt::Terminal`, scans OSC 0/2/7/9/7501, records shell-integration marks (OSC 133,
  parsed by libghostty-vt itself, with the cursor pinned at each), and notes alt-screen
  changes. Terminal query replies (DA, DSR, …) go through a reply sink back to the PTY. Lock
  order: ring → VT; nothing calls into the ring while holding the VT lock.
- **tokio**: everything else. One task per pane (metadata, echo hints, command marks, agent
  arbiter ticks, exit), one accept loop, and per connection: `ctl` reader, `ctl` writer
  (coalesces queued messages into one write), an event forwarder (subscribed to the daemon's
  broadcast bus), the `input` reader, one streamer task per subscribed pane, and the `bulk`
  writer. Snapshot encoding (≤ a few ms), history pages, search, links, command output and the
  Codex session lookup run on `spawn_blocking`.
- No `std::sync::Mutex` guard is held across an `.await`.


| Stream | Opened by | Priority | Content |
|---|---|---|---|
| `ctl` bidi | client, first | 100 | `Hello`/`Welcome`, attach, ops, layout, meta, echo hints, agent events, acks |
| `input` uni | client | 90 | `Input{pane, input_seq, principal, payload}` (bytes, key, mouse, paste), one write per frame |
| `pane/<id>` uni | daemon per subscription | 80 focused / 50 visible / 10 other | `Bytes`, `SnapshotZstd`, `Resized`, `InputAck` |
| `bulk` uni | daemon, on first history request | 1 | `HistoryPage` / `HistoryGone` |
| forward bidi | client | 40 | `StreamHeader::PortForward{port}` or `Forward{Tcp\|Unix}` → `ForwardReply` → raw bytes |
| transfer bidi | client | 1 (bulk) | `StreamHeader::Upload` / `Download` → `TransferReply` and raw bytes (§5.7) |

### Input encoding

The daemon's VT is the only one guaranteed to know the program's current modes (a client's VT
lags by the bytes in flight), so semantic input is encoded there, per pane, with libghostty-vt's
encoders (`ghostty_vt::{KeyEncoder, MouseEncoder}`):

- **Keys** (`InputPayload::KeyFull`; the older `Key` is still accepted): legacy sequences,
  application cursor/keypad modes, modifyOtherKeys, or the kitty keyboard protocol flags the
  program pushed (release events and base-layout keys included). Text with control characters
  is ignored in favour of the key and modifiers, as the encoder requires.
- **Mouse** (`InputPayload::Mouse`, cell coordinates): X10/normal/button/any-event tracking in
  X10, UTF-8, SGR, urxvt or SGR-pixels format (pixels from the client's `width_px/cols`). The
  encoder remembers held buttons (drag reporting) and deduplicates motion within a cell. Nothing
  is sent when the program does not track the mouse.
- **Paste** (`InputPayload::Paste`): Ghostty's rules. Control bytes that could end a paste or
  signal the tty (ESC, NUL, DEL, ^C, ^Z, …) become spaces, so an embedded `ESC[201~` cannot
  close the bracket early; wrapped in `ESC[200~ … ESC[201~` when the program enabled mode 2004,
  else newlines become carriage returns. Asking before a multi-line unbracketed paste is the
  app's job (`ghostty_vt::paste_is_safe`).

Input that encodes to nothing is still acknowledged (`InputAck`).

### Scrollback history paging (`bulk`)

A snapshot's READY section holds the screen and the rows sharing its pages; older scrollback is
fetched on demand, newest first. The daemon keeps the complete encoding of the last two
snapshots it sent per pane. `FetchHistory{pane, snapshot_seq, offset, max_bytes}` names the
snapshot (its `seq`) and a byte cursor (initially the READY length the client decoded); the
answer on `bulk` is `HistoryPage{…, next_offset, pages, done, data}` with whole snapshot
records (zstd) cut after a page record or at FINISH, which is what a streaming decoder needs
(`ghostty_vt::StreamingRestore::push`). `HistoryGone` means the snapshot was replaced; history
of the newer one can be fetched instead. `client-core` drives the cursor
(`Client::fetch_history`), prepends the pages to its VT mirror, and hands the raw records to the
app (`ClientEvent::PaneHistory`) for its own decoder.


- **Injection**, as Ghostty does it, without touching dotfiles: Ghostty's scripts
  (`vendor/ghostty/src/shell-integration`) are written to `<state>/shell-integration/` on
  start. zsh gets `ZDOTDIR` pointing there (its `.zshenv` restores the user's `ZDOTDIR`, kept
  in `GHOSTTY_ZSH_ZDOTDIR`); bash (4.4+; not macOS's `/bin/bash` 3.2) runs with `--posix` and
  `ENV=…/ghostty.bash`, which leaves POSIX mode and sources the normal startup files; fish
  finds `fish/vendor_conf.d` through `XDG_DATA_DIRS` and removes it again. Features:
  `cursor:blink,title`. Applies to shell panes and to the shell an agent pane drops to.
  `Config::shell_integration` turns it off. The zsh and bash scripts are GPL-3.0 (derived from
  kitty's); they are shipped unmodified as separate files run by the shell, as Ghostty does.
- **Marks**: libghostty-vt parses OSC 133 (`A`/`P` prompt, `B` input, `C` output, `D;status`)
  and calls back during `write`; the daemon pins the cursor cell at each event (tracked grid
  references follow the cell through scrolling, reflow and pruning). A command is
  `{id, command, cwd, started_at, exit, duration}`; the command line is the shell's
  `cmdline=` if sent, else the text between the `B` and `C` pins. `ServerCtl::CommandMark` is
  sent at start and end. OSC 7 accepts both `file://` and `kitty-shell-cwd://`.
- **Finished while unseen**: a command running at least `Config::long_command` (10 s) that ends
  while no connected client has the pane focused or visible is pushed to every client as
  `CommandFinishedUnseen` (for a local notification now, push later).
- **Echo prediction**: `133;A`/`B` set "at prompt", `C` clears it; that is the S6 rule's second
  signal for raw-mode shells.
- **Requests**: `Commands` (every remembered command with its prompt/output/end rows),
  `CommandOutput{id | last}` (the `C`..`D` text, soft wraps joined, at most 2 MiB keeping the
  end). The last 1000 commands per pane are remembered.

### Search and links

- `Search{pattern, Plain|Regex, Sensitive|Insensitive|Smart, cursor, limit}` runs over the
  whole screen (scrollback included) of the pane's active screen: the text is extracted once per
  output position (soft wraps joined, so matches span wrapped rows) and cached for paging;
  matches are laid out again with libghostty-vt's character widths to give
  `{row, col, end_row, end_col, line}` in screen rows (row 0 = oldest retained row) at
  `at_seq`, newest first, at most 100 000. Rust `regex` syntax.
- `Links{commands: N}` returns OSC 8 hyperlinks (from the VT encoding of the region), URLs and
  file paths (`path[:line[:col]]`, `~`, `./`, `../`, bare `name.ext`) from the visible screen
  and the output of the last N finished commands. Paths resolve against the pane's OSC 7
  directory and are kept if they exist, or if they are explicit (`/`, `~/`, `./`) multi-part
  paths (flagged `exists: false`). Deduplicated, screen first, bottom up.


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
shell prompt (after 133;A/B, before 133;C; shell integration is injected, see below).

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
  `claude --resume <id>`.
- Codex cannot be given an id and does not report one without hooks, so the daemon learns it
  1. **open file** (exact): a process in the pane's tree holds
     `…/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` open (`/proc/<pid>/fd` on Linux,
     `proc_pidfdinfo` on macOS);
  2. **rollout scan** (fallback): the newest rollout under `$CODEX_HOME/sessions` (pane
     environment, else `~/.codex`) modified since the pane started whose `session_meta.cwd`
     is the pane's directory and that no other pane claimed.
  The id is persisted like Claude's and the pane resumes with `codex resume <id>` after a
  restart. Agents started by hand in a shell pane are detected but not persisted.

### Persistence

`<state>/layout.json`: layout plus per-pane `{launch, cwd, agent{kind, session_id}}`, written
atomically (tmp, fsync, rename, fsync dir) 500 ms after the last change and on shutdown. On
start the layout is restored with the same ids; shells restart in their last directory
(OSC 7), agents resume, one-off commands come back as shells. An unreadable file is moved
aside, never overwritten.

### Port forwarding

See §5.1. `Client::forward_port(local, remote)` (the original API) still works;
`Client::forward(local, ForwardTarget)` adds Unix-socket targets and `stop_forward`.

## 3. Running it

```sh
cargo build --release -p hostd -p un

# Host
unnamed-hostd run                 # prints a pairing QR + ticket if nothing is paired yet
unnamed-hostd pair                # new one-time ticket (QR + text), valid 10 min
unnamed-hostd pair --json --wait 30   # the same as one JSON object, once a running daemon has
                                  # recorded its endpoint and relay (used by ssh::bootstrap)
unnamed-hostd status
unnamed-hostd service install     # systemd --user (Linux) / LaunchAgent (macOS); (re)starts it
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
un search <pattern> [-e] [--case sensitive|insensitive|smart] [--limit N] [--pane P]
un links [--commands N]           # hyperlinks, URLs, paths (screen + last N commands' output)
un marks                          # shell-integration commands: exit, duration, cwd
un output [--command N]           # a command's output (default: the last one)
un forward 3000 | --unix ~/x.sock [--local N]
un ports [--watch]                un inbox [--seen] [--watch]
un editor status | launch [folder] [--kind vscode|openvscode] [--accept-license] | stop <folder>
          | open <path[:line[:col]]>
un editor tunnel status | install --accept-license | start --accept-license [--microsoft]
          [--name N] | stop | open <path[:line[:col]]>      # real VS Code via vscode.dev
un ssh-proxy [--port 22]          # ProxyCommand for VS Code Remote-SSH over the daemon link
un git status [path] | diff [--staged|--index|--rev R|--merge-base B] [--stat] [-U n] [files…]
un turns [--diff N] [--stat]      un review --pane P --note 'path:L[-L]:text' [--submit]
un worktree create [--repo R] [--branch B] [--base B] | list | remove <path> [--force]
            [--delete-branch] | launch <path> [--agent claude|codex]
un fs ls <dir> [-a] | stat | cat | put <local> <remote> [--if-match V] [--new] | get <remote>
      <local> | mkdir [-p] | mv <a> <b> [--force] | rm <path> [--permanent] [-r] | watch <dir>
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
40 MB flood. Terminal completeness (`terminal.rs`, `shell.rs`, `codex.rs`): key, mouse and
paste encoding checked byte for byte by a raw-mode probe under application cursor keys, SGR
mouse, bracketed paste and the kitty protocol; 20 000 rows of history paged newest first into a
fresh client's mirror; search (plain/regex, case modes, paging) and links (OSC 8, URL,
`path:line:col`) over 3000 rows of scrollback; with real zsh, bash and fish (bash 4.4+/fish
tests skip where not installed; all three run in the Linux VM): injected integration, marks
with command text, exit status and cwd, command output, links from output, the at-prompt echo
hint, and "finished while unseen" only when no client shows the pane; a fake `codex` script's
session id persisted and resumed after a daemon restart. `client-core`'s tests cover refusal,
one-device tickets and mirror-less clients.

Loopback, release build, M5 Max, 3 runs each (Linux: OrbStack Ubuntu 24.04 arm64 VM):

| | macOS 26 | Linux |
|---|---|---|
| first attach: client endpoint bind, two handshakes (device refused, then pairing), attach, first snapshot | 22–26 ms | 3.3–3.5 ms |
| resume from ring (reconnect → missed output on screen) | 2.1–2.5 ms | 2.2–3.3 ms |
| resume after eviction (reconnect → snapshot on screen) | 3.2–3.3 ms | 4.4–4.8 ms |
| worst keystroke → echo during a 40 MB flood in a visible pane | 3.3–6.6 ms | 2.9–6.8 ms |

Cross-host (Mac ↔ OrbStack Linux VM, both directions) and relay-only (ticket stripped of direct
addresses, n0 relay, ~1.8 s to pair including relay setup) were exercised by hand with `un`.


All requests are one ctl message pair: `ClientCtl::Workspace{req_id, WorkspaceRequest}` →
`ServerCtl::WorkspaceResult{req_id, Result<WorkspaceResponse, WsError>}` (types in
`proto::workspace`; goldens added, nothing existing changed). Pushes: `PortsChanged`,
`FsChanged` (only to the watching connection) and `Attention` (every client). In client-core
the requests are `async` methods on `Client` (`git_status`, `fs_list`, `editor_launch`, …,
awaitable from any executor; the work runs on the client's runtime, a dropped connection
answers `WsError::Disconnected`) and pushes go to a separate `WorkspaceListener`
(`Client::set_workspace_listener`), so `ClientEvent` and the existing listener are untouched.
Code: `crates/daemon/src/ws/`, `crates/client-core/src/workspace.rs`, `crates/un/src/ws.rs`.

### 5.0 Path policy and configuration

Every path in a request (files, git, worktrees, editor folders, Unix forward targets) must be
absolute or `~/…`, contain no `..`, and resolve inside an allowed root: `$HOME` plus
`files.allow`. The existing ancestors are checked through their real paths, so a symlink out of
the root is refused (`~/link-to-/etc/passwd` → `Denied`); a final symlink is listed and deleted
as the link itself, while reads and writes follow it and check the target too. Optional
`<state_dir>/config.toml`:

```toml
[files]
allow = ["/srv/projects"]        # besides $HOME
[worktrees]
root = "/home/me/worktrees"      # default ~/.unnamed/worktrees
port_base = 4100                 # first PORT handed to a worktree
[editor]
code = "/usr/local/bin/code"     # default: PATH + usual app bundle locations
openvscode = "/opt/openvscode-server"   # instead of the pinned download
```


### 5.1 Port forwarding

The device listens on `127.0.0.1:local` (0 picks; the bound port is returned) and opens one
bidirectional QUIC stream per accepted TCP connection (priority 40: under a focused pane, over
bulk) with `StreamHeader::Forward{Tcp{port} | Unix{path}}`. The daemon connects to
`localhost:port` (IPv4, then IPv6) or the Unix socket (path policy applies) and answers
`ForwardReply`. Each direction copies through a 64 KiB buffer and only reads again after the
previous write finished, so a stalled reader stops the writer via the TCP window / QUIC flow
control (test: a server that does not read holds a 256 MiB writer back, then receives every
byte). EOF on one side finishes only that direction (half-close; test: a server that answers
after the client's `shutdown(Write)`), a reset maps to a stream reset. Forwards survive
reconnects (new connections wait for the link); `stop_forward` closes the listener. 64
concurrent connections through one forward are tested.

Loopback, one connection, 128 MiB, release build (`forward_throughput_and_latency`):

| | macOS 26 (M5 Max) | Linux (OrbStack VM) |
|---|---|---|
| throughput | 80–110 MB/s | 690–780 MB/s |
| 1-byte RTT direct / forwarded, p50 | 0.08 / 0.23 ms | 0.004 / 0.057 ms |
| p99 | 0.17 / 0.31 ms | 0.014 / 0.097 ms |

macOS is bounded by iroh's UDP path there (no GSO/GRO on loopback; the same gap shows in §4's
attach times), not by the forward. Debug builds run several times slower.

### 5.2 Port detection

Listening sockets are attributed exactly, by process tree: Linux reads `/proc/net/tcp{,6}`
(state `0A`) and maps socket inodes through `/proc/<pid>/fd`; macOS walks
`proc_pidinfo(PROC_PIDLISTFDS)` and `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` (no `lsof`; struct
offsets checked against the SDK). A port belongs to the pane whose shell is its ancestor. The
kind is `Http`/`Https` from a printed URL, else one `HEAD /` probe per (pid, port) (`HTTP/` →
HTTP, a TLS record → HTTPS; well-known database/mail ports are never probed). Printed URLs are
found in the pane's screen text at each 500 ms tick (loopback, `0.0.0.0` → `localhost`,
`*.localhost`, private and Tailscale ranges; the first URL per port wins, a loopback one
replaces a LAN one). Scans run every 2 s while any client is connected, at once when a pane
prints a new URL or a command starts/ends, never with no client; the whole list is pushed when
it changes. Gap: a URL that scrolls off within one tick is missed (the listener still is).

### 5.3 Editor (VS Code tunnel; `code serve-web`; openvscode-server as explicit fallback)

**Main path since 2026-10-18: the VS Code Remote Tunnel** (`ws/tunnel.rs`, research
their own GitHub or Microsoft account by device code. The app opens
`https://vscode.dev/tunnel/<name>/<folder>` top-level in a WKWebView (vscode.dev refuses framing), and
on the Mac it opens `vscode://vscode-remote/tunnel+<name>/<path>:L:C`.

- **`VsCodeCliInstall{accept_license}`.**
  - Refused unless the user accepted <https://code.visualstudio.com/license> in the app.
  - Downloads the CLI from Microsoft's update service: `/api/update/<cli-linux-x64|arm64|armhf,
    cli-alpine-*, cli-darwin-*>/stable/latest` gives `url` and `sha256hash`. curl, else wget.
  - Checks the SHA-256, unpacks, and checks that `code --version` runs.
  - Installs to `<state>/vscode/cli/<version>-<commit>/code` and records `install.json` (version, commit,
    sha256, url, platform).
  - The user's own `code` (`editor.code`, `PATH`, the app bundle) is always preferred.
  - `Config::vscode_update_url` points tests at a `file://` tree.
- **`VsCodeTunnelStart{accept_server_license, provider, name}`.**
  - Refused unless the user accepted <https://aka.ms/vscode-server-license> and the Microsoft Privacy
    Statement in the app.
  - The flow:
    1. If `code tunnel status` shows a running tunnel, it is **adopted** (the user's own, or its service).
    2. Else, if `code tunnel user show` fails, it runs `code tunnel user login --provider github|microsoft`.
       The device-code line is pushed as `TunnelState::NeedsLogin{verification_url, user_code}`.
    3. It runs `code tunnel --accept-server-license-terms --name <name>` in its own process group. The
       `vscode.dev/tunnel/<name>` line gives `Running{name, web_url}`.
  - One tunnel per host.
  - On exit it reports `Failed{retrying: true}` and restarts with back-off from 1 s doubling to 60 s,
    reset after 60 s up.
  - `<state>/vscode/tunnel.json` keeps `enabled`, `name`, `provider` and the time the licence was
    accepted.
  - At daemon start it restarts, but never opens a sign-in unattended: if signed out, it reports
    `Failed{retrying: false}`.
  - Daemon shutdown kills it. `VsCodeTunnelStop` kills it and disables it.
  - Every state change is pushed as `ServerCtl::VsCodeTunnel`.
  - Logs: `<state>/editors/vscode-{tunnel,login}.log`.
  - The name defaults to the host name: lowercase, `[a-z0-9-]`, at most 20 characters.
- **`VsCodeTunnelOpen{folder?, path, line?, column?}`.**
  - The folder defaults to the enclosing git work tree.
  - It returns `web_url`, `desktop_uri`, and `in_window` (the file was opened at the line through the
    server's remote CLI in a window already connected, the same mechanism as `EditorOpen` below).
- **Tests.**
  - `tests/it/vscode.rs` uses a fake `code`: device code, sign-in, running, crash restart, daemon-restart
    autostart, stop, adopt, Microsoft code, CLI install with hash mismatch, and `forward_io`.
  - Real host (Hetzner, 2026-10-18): the managed install from Microsoft took 0.57 s with the hash verified.
- **Desktop Remote-SSH to iroh-only hosts.**
  - `Client::forward(<stable port>, Tcp{22})` plus `client_core::vscode::remote_ssh_uri(
    SshHost::local_forward(user, port), …)`. This uses Remote-SSH's hex-JSON authority.
  - Or `un ssh-proxy` as `ProxyCommand` (`Client::forward_io`).

The per-folder servers below remain. **`Auto` no longer falls back to openvscode-server**: it means
`code serve-web` and fails with `Unavailable` (no CLI) or `Denied` (licence not accepted).
openvscode-server must be asked for with `Only(OpenVsCode)`.

- `EditorLaunch{folder, choice: Auto|Only(kind), accept_vscode_license}`. Auto runs
  `code serve-web` (the user's CLI, else the managed one) only with the licence accepted. One server per folder, reused; bound to `127.0.0.1` on a
  free port with a random 128-bit `--connection-token`; own process group, killed on
  `EditorStop` and daemon shutdown; logs in `<state>/editors/`. Returns port, token and
  `url_path` (`/?tkn=…&folder=…`; the server answers with the token cookie and a redirect).
- openvscode-server **v1.109.5** is downloaded on first use (curl, else wget) from the GitHub
  release, checked against pinned SHA-256s (linux-x64 `b433bf4f…`, linux-arm64 `36d9c140…`),
  unpacked to `<state>/editors/`. Verified end to end in the Linux VM (download + verify +
  start 8.9 s, token redirect, workbench page via a forward: ignored test
  `real_openvscode_server_downloads_and_serves`). **Gitpod publishes no macOS build**, so on a
  Mac host the editor is `code serve-web` (VS Code installed) or a configured `editor.openvscode`.
- `EditorOpen{path, line, col}`: first through the editor's own CLI channel — the extension
  host of a connected window exports `VSCODE_IPC_HOOK_CLI`; the daemon reads it from the
  server's process tree (Linux `/proc/<pid>/environ`, macOS `KERN_PROCARGS2`) and runs the
  server's bundled `bin/remote-cli/*  --goto path:line:col` (`in_window: true`). Otherwise it
  returns a `url_path` with `payload=[["openFile","vscode-remote://localhost:<port>/path:L:C"],
  ["gotoLineMode","true"]]` for the app to load (the authority assumes the in-app proxy keeps
  in tests); this is S-ED1 territory.
- Licences (ARCHITECTURE §9): Microsoft's VS Code Server licence
  (<https://code.visualstudio.com/license/server>, read 2026-10-18) allows use "with Microsoft
  Visual Studio Code" on the user's devices and internal network, and forbids hosting,
  sharing, publishing, redistributing, or "provide the software as a stand-alone offering or
  combine it with any of your applications for others to use" (§5.4–5.5). So:
  - We never ship, mirror or host it.
  - The `code` CLI comes from Microsoft's update service only, on the user's request after the
    VS Code licence is shown.
  - We never run it on our infrastructure.
  - We launch it only after the user accepted the Server licence in the app, and only for that
    user's own use.
  - The tunnel is the main path because Microsoft's own client (vscode.dev or desktop) is then
    the client. serve-web through our forward makes our app the client, which is greyer; it
    stays opt-in.
  - The Remote FAQ's "cannot build a public or commercial service on top of … VS Code Server"
  - openvscode-server (MIT, Open VSX extensions only; the Microsoft Marketplace terms forbid
    non-Microsoft products from using it) is an explicit fallback only.

### 5.4 Git, diffs, agent turns, review notes

- Git CLI only, `LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`, `core.quotePath=false`. Status from
  `status --porcelain=v2 --branch -z` (branch, oid, upstream, ahead/behind, staged/unstaged per
  path, renames with their old path, unmerged, untracked).
- Every diff is between two **trees**. The worktree is turned into a tree with a throwaway copy
  of the index (`GIT_INDEX_FILE=tmp git add -A && git write-tree`): untracked, non-ignored
  files are included and the user's index and stash are never touched (tested). Bases: `Head`
  (HEAD vs worktree, staged + unstaged + new), `Index`, `Staged`, `Rev(r)`, `MergeBase(branch)`.
  Files from `diff-tree -r -M -z --raw` and `--numstat` (renames, binary = `-`), hunks from
  `diff-tree -p` matched in order; caps: 1 MiB patch per file (counts kept,
  `hunks_omitted`), 8 MiB per diff (later files lose hunks, `truncated`); `hunks: false` gives
  the file list with counts. Revisions starting with `-` are refused.
- **What this turn changed**: on an agent `TurnStarted` (hooks, OSC, or screen) the daemon
  snapshots the worktree tree of the agent's directory (hook `cwd`, else the pane's); on
  `TurnEnded`/`Interrupted`/`Error`/`SessionEnded` it snapshots again. Snapshots run on one
  worker in order. `ListTurns{pane}`, `TurnDiff{pane, turn?}` (a running turn diffs against
  now). The last 50 turns per pane, in memory (lost on daemon restart); snapshots write blobs
  into the repo's object store (`git gc` prunes them).
- **Review notes → prompt**: `SendReview{pane, notes[{path, lines, old_side, quote?, note}],
  submit}` formats a numbered prompt (`1. path:L-L`, quoted lines as `> …`, the note) and
  writes it to the pane as a bracketed paste, then Enter if `submit`.

### 5.5 Worktrees and `PORT`

`WorktreeCreate{repo, branch?, base?, path?}` runs `git worktree add -b` into
`<root>/<repo>/<branch with / → ->`; a missing branch name becomes `unnamed/<word>-<hex>`
the main worktree and, unless `force`, any worktree with changes or untracked files (`Conflict`
with the count), and can `branch -d` the branch. Each worktree gets a stable `PORT` from
`port_base` up (skipping ports held by other worktrees or bound now), kept in
`<state>/worktrees.json` across restarts. Every pane whose directory is inside a registered
worktree is started with `PORT` and `UN_WORKTREE`, recorded in `layout.json`
(`worktree: {path, port}`). `WorktreeLaunch{path, split_from, axis, agent?}` splits a pane into
run yet.

### 5.6 Files

`FsList` (lstat, directories and links to directories first, hidden flag, link target and its
kind, at most 10 000 entries), `FsStat`, `FsRead{offset, len ≤ 1 MiB}`, `FsWrite` (≤ 1 MiB),
`FsMkdir`, `FsRename` (no replace unless `overwrite`: `renameat2(RENAME_NOREPLACE)` /
`renamex_np(RENAME_EXCL)`), `FsDelete{Trash|Permanent, recursive}` (trash: `~/.Trash` on macOS,
the XDG trash with `.trashinfo` on Linux; `$HOME` itself is refused), `FsWatch`/`FsUnwatch`
(`notify`: FSEvents/inotify, not recursive, 100 ms debounce, paths reported under the
requested spelling, many changes → `rescan`; watches end with the connection). Versions are
`inode-size-mtime_ns`; writes take `if_match` and `create_new`.

### 5.7 Upload and download streams

One bidirectional stream per transfer at bulk priority, so QUIC flow control is the
backpressure and transfers never delay ctl or keystrokes. Upload: `StreamHeader::Upload{target,
size}` → `TransferReply::Ready` (preconditions checked first) → exactly `size` bytes, FIN →
`Done(stat)` or `Failed`. The daemon writes from a blocking thread fed through a 4-chunk
channel (a slow disk slows the stream), into `.<name>.unnamed-upload-<hex>` next to the
target, fsyncs, re-checks `if_match`, renames (or hard-links for `create_new`), fsyncs the
directory; an interrupted upload leaves nothing behind. Download: `Download{path, offset, len?}`
→ `Ready{stat, len}` → bytes → FIN (reset on a read error); client-core writes to a temporary
file and renames. 20 MiB, release, loopback: macOS 28 MB/s up / 39 MB/s down (with other tests
running), Linux 705 / 393 MB/s.

### 5.8 Attention feed

One feed per daemon for local notifications and the inbox: `AgentBlocked{agent, request_id}`,
`AgentDone`, `AgentFailed` (from the arbiter's own notification decisions, which the daemon
previously dropped) and `CommandFinished(mark)` (the long command finished unseen; also still
sent as `CommandFinishedUnseen`). Items carry pane, session, title, body (last assistant
message, blocker summary), `seen` and `while_viewed` (a client showed the pane: no
notification needed; such items start seen). `seen` is shared by all devices: set by
`AttentionSeen{ids, up_to, pane_id}`, by any client focusing the pane, and for blocked items
when the agent leaves the blocked state. Every change is pushed as `Attention(Added{item,
unseen} | Seen{ids, unseen})`, so `unseen` is the per-host badge; the app sums hosts. The last
500 items are kept in memory (not across daemon restarts). Gap (agents crate): a turn that goes
straight from blocked to idle (approval answered in the terminal, no tool hook in between)
produces no `Done`.

### 5.9 Tests

`cargo test -p daemon --test it workspace` (macOS and Linux): forwards (64 concurrent
connections, half-close, backpressure, Unix socket, policy refusal, stop) and the throughput /
latency numbers above; ports (python `http.server` with and without a printed URL, loopback vs
all interfaces, kind probe, removal when the pane closes); git (status, HEAD diff with rename,
delete, untracked, binary and the 1 MiB cap, staged diff, index untouched, turn snapshots
driven by real hook requests, a later edit outside the turn, review prompt typed into the pane,
bad revisions); worktrees (two ports, conflicting branch, list, `PORT` in a launched shell and
in `layout.json`, dirty refusal, forced removal with branch delete, main refused, port stable
across a daemon restart); files (listing order and symlinks, `~`, ranged read, traversal /
outside / symlink escapes, versions and conflicts, mode kept, 20 MiB upload and download and a
range, no temp files left, watch, rename without overwrite, trash, recursive delete, `$HOME`
refused); editor (fake `code` and openvscode scripts: licence refusal, Auto fallback, args,
reuse, token check through a forward, open-file URL, switch to serve-web, stop on shutdown);
attention (blocked → seen when work resumes, done with the last message, unseen counts, seen
on focus, mark all). Unit tests cover the porcelain/worktree/hunk parsers, path policy,
atomic writes, URL detection, the review formatter, trash dates and the attention store.

## 6. Known gaps / follow-ups

- **Live upgrade**: replacing the daemon binary ends its PTYs. Shells come back in their last
  directory and Claude/Codex resume their sessions, but running commands and unsaved terminal
  state are lost. Handing PTY masters and VT snapshots to the new process (fd passing over a
  Unix socket, then `exec`) is the design for a seamless upgrade; not built.
- History paging serves the last two snapshots sent per pane; a client that resumed from the
  ring holds an older snapshot and gets `HistoryGone` until its next snapshot. Those snapshots
  are kept whole and uncompressed (each up to about the scrollback size); compressing the
  history part, or encoding it lazily from a frozen copy, would cut that memory.
- Search covers the screen the pane shows (the alternate screen while a full-screen program
  runs). Its positions are screen rows at `at_seq`; a client maps them by distance from the
  bottom. Extracting a large scrollback holds the pane's VT lock for a few tens of ms.
- Mark `at_seq` is the end of the output chunk that carried the OSC 133 sequence, not its exact
  offset (libghostty-vt reports the event, not the byte).
- fish 3 sends no `133;B`, so its command lines are unknown (fish 4 marks prompts itself);
  macOS's `/bin/bash` 3.2 gets no automatic integration (as in Ghostty).
- A Codex started by hand in a shell pane is detected for status but its session id is not
  captured (only launched agents are restored).
- Grants are an allowlist placeholder (no signed grants, revocation UI, leases, presence).
- Snapshots are encoded in full then truncated at READY (libghostty has no READY-only encode).
  `size` test fails its "typical < 50 KB" assertion there: 148 KB for colored logs); zstd keeps
  the wire size small, but the cause (page layout) needs a look.
  and editor servers live in memory and end with the daemon; worktree setup scripts are not
  run; editors are not idle-stopped; the in-window "open file" path and the URL payload are
  untested against a real browser; no transfer resume by offset for uploads (downloads take an
  offset); `fs.find`/`fs.resolve`, git stage/discard/commit and `log` are not built.
- `SetSizePolicy` is ignored (only `LastInput`). The ticket's relay URL is the one known at
  mint time; `endpoint.json` is refreshed as iroh's addresses change.
