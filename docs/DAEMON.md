# Host daemon (`unnamed-hostd`) and client core

Status: MVP path working end to end on macOS and Linux (2026-10-18), plus terminal completeness
(key/mouse/paste encoding, history paging, shell integration, search, links, Codex resume), plus
roles enforced on every request, control lease, presence, signed approvals, audit log,
anchors, send to agent) and input assistance for the mobile line editor (§8: foreground
program, prompt state and input line, atomic submit, history, completion, file search,
blocked-agent options), and native password prompts (§9: askpass helper, detected
hidden-input prompts).
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
  `CommandFinishedUnseen` (for a local notification now, push later). Its attention item reads
  "cargo build failed (101)" / "after 1 min 12 s · error: could not compile `x`": the body ends
  with the last non-empty line of the command's output (at most 120 characters).
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
  not the connection's (`InputRejected{Role}`). Paired devices are `Owner` on the whole
  daemon; guests join with signed grants (`v = CHAIN`, §6).

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

### Version, host name and updating the daemon (`proto::info`)

- **What the daemon is.** A client announcing `Caps::DAEMON_INFO` gets `ServerCtl::DaemonInfo`
  as the first frame on `ctl`, before `Welcome` or `Refused`: version, build (the commit,
  `-dirty`, or `dev`), `built_unix` (commit time of a clean release build, build time of a
  dirty one, 0 for `dev`), protocol level (`proto::PROTOCOL_LEVEL`, bumped when clients start
  relying on a daemon feature) and the oldest client level it serves, features
  (`SELF_UPGRADE`), and the machine: `gethostname` (empty when refusing), OS, `os-release`
  `PRETTY_NAME`, CPU. Older daemons ignore the bit and answer `Welcome` directly, so clients
  treat "no info" as level 0. `unnamed-hostd build-info [--json]` prints the same for a binary
  without running it as a daemon. Release stamps come from `cargo xtask build-hostd-linux`
  (`UN_BUILD_ID`, `UN_BUILD_UNIX`), which also writes `apple/build/hostd/hostd-manifest.json`
  (file, OS, CPU, build, time, level per bundled build) for the app.
- **Incompatible clients.** A client with `DAEMON_INFO` whose snapshot format differs, presenting
  the owner's device grant, gets `Welcome` (with the daemon's format) but a connection that
  serves only upgrade streams; client-core reports `ClientEvent::Incompatible` and keeps it open.
  Unpaired devices still get `Refused{SnapshotFormat}`. Daemons from before this refuse every
  mismatching client, so only SSH can update them.
- **Self upgrade** (owner only: a paired device, not a guest's chain whatever its roles;
  `run` enables it when its executable's directory is writable, `Config::self_exe`): the client
  opens a bidi stream with `StreamHeader::Upgrade{size, encoding raw|gzip, sha256, build}` →
  `Ready` → exactly `size` bytes → the daemon decodes into `.<exe>.upgrade-<pid>` next to the
  executable (streamed, flow controlled, ≤ 256 MiB), checks the SHA-256 of the decoded
  executable, runs `<new> build-info --json` (15 s; must start and report this OS and CPU), keeps
  the old file as `<exe>.prev` (hard link), renames the new one over the executable, fsyncs the
  directory, answers `Installed(DaemonInfo of the new build)`, then `run` saves the layout, stops
  the panes and `exec`s the new build with the same arguments: same PID, so systemd `--user`,
  launchd or a detached start keep supervising it (if the exec fails it renames `.prev` back
  and execs that). One upgrade at a time (`Busy`); any failure (`Forbidden`, `Unsupported`,
  `Corrupt`, `Rejected`, `Io`) leaves the running daemon and its file untouched. There is no
  release signing key yet: the bytes are vouched for by the owner device authenticated in the
  QUIC handshake and checked by hash and by running them.
- **What survives an update**: everything a restart keeps. The layout (sessions, tabs, splits,
  ids), pane directories, paired devices, grants, history, drawings and Claude/Codex sessions
  (`--resume`) come back; clients redial by themselves (backoff ≤ 5 s) and get snapshots.
  **Lost**: the shell processes and whatever ran in them (they restart in their last directory),
  (attention items, turn snapshots, editor servers; §9), and Codex sessions started by hand.
- `un daemon info` / `un daemon upgrade <file> [--build ID]` drive it from a terminal.

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
unnamed-hostd build-info --json   # version, build, protocol level, OS, CPU, host name
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
un draw list | show <id> [--mode kitty|ascii] | export <id> --format png|svg|ascii [-o F]
        | send <id> | --file img.png [--pane P] [--version V]
        | place <id> [--pane P] | import <file.png|.excalidraw> [--pane P]
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
vscodium = "/opt/vscodium-reh-web"      # instead of the pinned VSCodium download
default = "vscode"               # what `Auto` launches: "vscode" (default) | "vscodium"
```

driver with a daemon- or session-wide grant; editor and tunnel launches need the owner.

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

### 5.3 Editor (VS Code tunnel; `code serve-web`; VSCodium as automatic fallback; openvscode-server explicit only)

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

no editor picker; VS Code is the editor and must just work).

- **Fallback rule** (`DaemonClient::open_editor`, apple-ffi): with the VS Code licence accepted,
  the host's default editor (VS Code) is tried first, installing the `code` CLI from Microsoft
  if missing. If the CLI **cannot be obtained** (`VsCodeCliInstall` fails: download blocked,
  offline or mirrored network, no Microsoft build for the OS/arch/libc) or **cannot run**
  (`serve-web` exits before listening, e.g. a wrong libc), the same call launches
  `Only(Vscodium)` with no prompt and returns `EditorSession.fallback_reason` (the VS Code
  error) so the app can show a quiet note. It never falls back when the licence was not
  accepted (`Unavailable`/`Denied` are returned as before), when the grant is not the owner's,
  or when a kind was asked for explicitly. Both failing → `Failed` with both messages.
- The explicit kind is internal: `open_editor_with(folder, accept, Some(kind))` (Rust only,
  `#[doc(hidden)]`, for tests), `un ws editor launch --kind vscodium`, and the host's
  `[editor] default = "vscodium"` (then `Auto` means VSCodium; for hosts where Microsoft's CLI
  is known not to work). Proto: `EditorKind::Vscodium` appended (goldens added).
- **What runs:** VSCodium's Web Host `vscodium-reh-web-<platform>-1.140.06880.tar.gz` from
  <https://github.com/VSCodium/vscodium/releases> (pinned in `ws/editor.rs`, SHA-256 from the
  release's `.sha256` files): linux-x64 `f16388ea…`, linux-arm64 `d21cccd1…`, darwin-arm64
  `171645ce…`, darwin-x64 `76062c1a…`. curl, else wget; hash checked; the tarball has no
  top-level directory, so it unpacks into `<state>/editors/vscodium-reh-web-<platform>-<version>/`
  (atomic rename). `editor.vscodium` points at an existing one instead.
- `bin/codium-server --host 127.0.0.1 --port <free> --connection-token <random 128-bit>
  --telemetry-level off` in the folder. Same flags and token semantics as openvscode-server
  (`?tkn=` → `vscode-tkn` cookie + 302; no token → 403; `--without-connection-token` exists and
  is never used). Its `product.json` has an empty `serverLicense` and `serverLicensePrompt`, so
  there is no licence flag, prompt or sign-in. Extensions come from Open VSX
  (`extensionsGallery.serviceUrl = https://open-vsx.org/vscode/gallery`); server data in
  `~/.vscodium-server`. One server per folder, own process group, killed on `EditorStop` and
  daemon shutdown; `EditorOpen`'s remote-CLI path works the same (`bin/remote-cli/codium`).
- **Verified live (2026-10-19)**, ignored test `real_vscodium_downloads_and_serves`
  (download + verify + unpack + start + token redirect + workbench through an iroh forward):
  macOS 26 arm64 (M5 Max) 14.6 s; Linux arm64 OrbStack VM (Ubuntu 24.04) 11.9 s. Both ~95–100 MB at ~9 MB/s from GitHub. The
  workbench HTML has no `<title>` (the workbench sets it from script);
  `apple-mobile-web-app-title` is `Code` and the served web manifest's `name` is `VSCodium`.
  Without the token `/` is refused. Fake-binary e2e: `vscodium_launches_without_a_licence_and_as_the_default`
  (daemon), `open_editor_falls_back_to_vscodium_when_vscode_cannot_be_had` (apple-ffi: blocked
  CLI download, and a `code` that exits on start).

| | VS Code (`code serve-web`, the editor) | VSCodium Web Host (fallback) |
|---|---|---|
| Licence | Microsoft VS Code + Server licence, accepted once in the app | MIT (<https://github.com/VSCodium/vscodium/blob/master/LICENSE>); no prompt |
| Sign-in | none | none |
| Extensions | Microsoft Marketplace | Open VSX only (Marketplace terms forbid non-Microsoft products) |
| Not available | — | Pylance, C# Dev Kit, Remote-* (SSH, Containers, WSL), Live Share, GitHub Copilot (not on Open VSX; checked 2026-10-19, 404). Python, rust-analyzer, etc. are there |
| Platforms | wherever Microsoft ships the CLI | Linux x64/arm64, macOS arm64/x64 (pinned) |
| Who downloads | Microsoft's update service | VSCodium's GitHub releases, SHA-256 pinned |

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
a shell or Claude/Codex in the worktree. Setup and teardown commands come from
`.unnamed.json` (§5.12).

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


Attention items that stay unseen for `push.delay` (3 s) are sealed to each registered device
that wants that kind and is not looking at this host, and posted to the push relay with the
daemon's signature; approvals carry a daemon-signed action token that the app returns with
`PushAction` from the lock screen. Registrations (`PushRegister` / `PushUnregister` /
`PushStatus`, per device) live in `<state>/push.json`. Details, formats and the Worker:
`docs/PUSH.md`. Relay modes (`[relay]` in `config.toml`: default, self-hosted `iroh-relay`
URLs with token and private CA, local-only) and how pairing tickets carry them:
`docs/RELAYS.md`. Tests: `cargo test -p daemon --test it notify relays`.


`crates/daemon/src/usage/` reports Claude Code's and Codex's plan windows (5h, weekly, per-model)
to owner connections that watch: `WorkspaceRequest::UsageWatch { api_fallback }` answers with the
report at once, then `ServerCtl::AgentUsage` pushes changes (clients with `Caps::AGENT_USAGE`);
`UsageUnwatch` stops. Offered as `DaemonFeatures::AGENT_USAGE`.

Sources, preferred first: Codex's `token_count` rate limits in its rollouts; Claude's status-line
input (Claude panes launched by the daemon run `un-hook claude StatusLine` as their status line,
which forwards the JSON as hook event `StatusLine` and then runs the user's own status line);
when those are missing or older than 10 min, `claude -p /usage --output-format stream-json`
(+ `claude auth status --json` for the plan) and `codex app-server` → `account/rateLimits/read`,
in the background, at most every 5 min per agent; only for a watcher that opted in, the
providers' undocumented usage endpoints with the host's sign-in (`~/.claude/.credentials.json`,
`~/.codex/auth.json`), at most every 5 min. The report refreshes at most once a minute and only
while a connection watches; the last status-line snapshot survives restarts
(`<state>/usage/claude-status-line.json`). Tools are found through the panes' `PATH` (plus
`~/.local/bin`), `CODEX_HOME` and `CLAUDE_CONFIG_DIR`. Tests: `cargo test -p daemon --test it usage`
(fixture rollouts, status-line hook, fake `claude` / `codex`, a local HTTP endpoint).
### 5.12 Git-native workspace (`proto::repo`)

The sidebar's picture of the host's repositories, pushed whole as `ServerCtl::Repos(RepoSnapshot)`
to clients that announce `Caps::REPO_STATUS` (the app does; the CLI and tests opt in with
`ClientConfig::repo_status`), right after they connect and on every change. Code:
`crates/daemon/src/ws/repo.rs` (tracker), `repo_ops.rs` (requests), `gh.rs` (GitHub CLI).

- **What**: each pane in a git worktree → that worktree (`panes`); every worktree of every
  repository a pane is in (`worktrees`, main first): repository (main worktree path) and name,
  worktree name, main or not, branch (or detached `HEAD`), upstream with ahead/behind,
  `+added −removed` against `HEAD` with untracked files counted (≤ 500 files of ≤ 1 MiB,
  binary skipped), changed paths, dirty; the branch's pull request; the repository's scripts and
  setup/teardown; managed (made by the daemon) and when its PR was first seen merged; and `gh`'s
  state (`Ready{account}`, `Missing`, `NotAuthenticated{message}`).
- **Only while watched**: one task owns it. With no `REPO_STATUS` client connected it drops its
  file watches and reads nothing (the auto-delete sweep still runs, below).
- **Cheap refreshes**: a pane's directory (OSC 7, else its launch directory) maps to a worktree
  with `rev-parse --show-toplevel`, cached 20 s; repositories are listed with `worktree list`
  every 30 s or when worktrees change. A worktree is read with `status --porcelain=v2`,
  `diff --numstat HEAD` and `ls-files --others`, all with `GIT_OPTIONAL_LOCKS=0` (reading never
  writes the index, so it never triggers its own events). Triggers, debounced 300 ms and at most
  one read per debounce period: file events (FSEvents on the whole worktree on macOS; the top
  level, the git directory and `refs/heads` elsewhere, where recursive inotify would need a watch
  per directory; inside `.git` only `HEAD`, `index` and refs count), a finished command (shell
  integration) or agent event in a pane of the worktree, and a poll as the safety net (10 s with
  panes, 60 s without). Snapshots go out only when something changed.
- **Pull requests via the host's `gh`** (no token in the app): `gh pr view <branch> --json
  number,title,state,isDraft,headRefName,additions,deletions,mergeStateStatus,statusCheckRollup,url`
  per worktree branch, in the worktree, with `GH_PROMPT_DISABLED` and a 30 s timeout. Cached and
  re-asked on a schedule: 30 s while checks run, 2 min otherwise, 5 min with no PR, 15 min once
  merged or closed, soon after a commit or push; errors back off 1 → 32 min; a repository with no
  GitHub remote is not asked again; nothing while `gh auth status` says missing or signed out
  (re-checked every 5 min). `gh` is found on `PATH`, then Homebrew, Linuxbrew and `~/.local/bin`
  run is pending; `SUCCESS` succeeds; `NEUTRAL`, `SKIPPED`, `CANCELLED` are their own; every other
  conclusion fails; status contexts `ERROR`/`FAILURE` fail. Failures sort first.
- **Requests** (`WorkspaceRequest`; Drive on the host, like the git and worktree requests):
  `RepoRefresh{path?}` (read everything now, and that PR or all → `Repos`); `PrMerge{path,
  number, strategy}` (re-reads the PR, refuses with `Conflict` if the number changed or
  `mergeStateStatus` is not CLEAN/UNSTABLE/HAS_HOOKS, then `gh pr merge N
  --merge|--squash|--rebase`); `PrRerunFailed{path}` (`gh run rerun <id> --failed` for each
  failed check's Actions run); `PrCreate{path, draft, base?}` (push `-u` to the upstream's
  remote or `origin`, then `gh pr create --fill`); `PrCheckout{repo, number}` (a detached
  worktree `pr-N`, then `gh pr checkout N`, with `--branch pr-N` if the head branch is checked
  out elsewhere); `TaskCreate{repo, session, name, branch?, base?, agent?}` (branch from the
  name, `-2`… if taken; a worktree under the worktree root; the setup command queued; a new tab
  with a shell or the agent); `ScriptRun{cwd, session, name, command}` (a new tab that runs the
  command, then stays a shell with shell integration; an empty command is a plain shell tab);
  `WorktreeArchive{path, force}`; `WorktreeArchived{repo?}`; `WorktreeRestore{id}`;
  `WorktreeSettings(Option<…>)` (changing it needs the owner).
- **Setup, teardown and scripts**: `.unnamed.json` at the worktree's top level (else the main
  worktree's): `{"setup": "...", "teardown": "...", "scripts": [{"name", "command", "icon",
  "tint", "default"}]}`. Setup runs first in the new task's pane, echoed dimmed (`› pnpm i`),
  before the shell or the agent. Teardown runs (`sh -c`, ≤ 5 min) before archive or delete; a
  failing teardown stops them unless forced.
- **Archive keeps refs**: refused with `Conflict` when the worktree has changes unless `force`.
  The commit goes to `refs/unnamed/archived/<id>/head` and, with changes, a commit of the whole
  working tree (untracked files included, the user's index untouched) to `…/changes`; then the
  worktree is removed; the branch stays. Restore re-adds the worktree where it was, on its branch
  (recreated from the ref if it was deleted), checks the saved changes out and resets the index
  so they are uncommitted again, and deletes the refs. Records live in `<state>/worktrees.json`.
- **Auto-delete**: worktrees the daemon made (TaskCreate, PrCheckout, WorktreeCreate, restore)
  are removed `auto_delete_merged_days` (default 7; 0 never; set from the app's Settings) after
  their PR was first seen merged, by an hourly sweep that asks `gh` itself for managed worktrees
  no pane follows. Never one with uncommitted changes: it stays, shown as merged and dirty, and
  the app asks. Teardown runs first; the branch stays.
- **Tests**: `cargo test -p daemon --test it repos` on real temporary repositories with a fake
  `gh` answering from fixture JSON: the snapshot (pane → worktree, ahead/behind against a real
  `origin`, `+4 −1` with untracked files, a commit seen through the git directory, PR and
  checks), New Task with setup, a script tab, re-run, merge refused for a changed number and for
  a blocked PR, the merged clock; archive refused when dirty, a forced archive keeping both refs,
  restore with the changes uncommitted again; auto-delete of a clean merged worktree after "2
  days" of 100 ms with teardown, never the dirty or the open one; no snapshot for clients
  without the capability. Unit tests: `gh` JSON and errors, line counting, event filtering, the
  config file, branch names. Goldens: `crates/proto/tests/golden_repo.rs`.


Amp's multiplayer (a thread toggle that lets every workspace member prompt the agent) rests on
hosted threads and one workspace-wide role. Ours runs on the daemon over iroh, end to end
encrypted, with no account: an invite is a link or QR code, roles are per person, a pane has
Code: `crates/grants` (signing and verification), `proto::mp` (wire types),
`crates/daemon/src/mp/` (grant table, policy, leases, presence, audit),
`crates/client-core/src/mp.rs`, `crates/un/src/mp.rs`. Tests: `crates/grants/tests/props.rs`,
`crates/daemon/tests/it/multiplayer.rs`.

### 6.1 Grants and invites

- A **grant** (`proto::Grant`) names the daemon, its `issuer` device key, `roles`
  (Viewer / Prompter / Driver / Approver / Owner, a bitset; Owner implies all), a `scope`
  (`Daemon`, `Session(id)`, `Tab(id)`, `Pane(id)`), `expires`, `max_uses`, an optional `bind`
  (guest device key), `delegate` and a `label` (the guest's display name). The issuer signs
  `"grant-v1\0" ‖ postcard(grant)` with Ed25519 (ring). Device keys are the iroh keys, so
  `bind` names the key the QUIC handshake proves.
- A **chain** is a root grant followed by attenuated children. The root must be signed by a
  paired owner device (or the daemon key). Each child is signed by the device holding its
  parent (the parent's `bind`, or a device the daemon bound it to on first use), requires
  `delegate` on the parent, and may only narrow: roles ⊆ parent's, scope inside the parent's
  (checked against the live layout), expiry ≤ parent's, uses ≤ parent's, same daemon. Depth
  ≤ 8. Delegation is offline: a guest signs a child with its own key, no daemon round trip
  (`Client::create_invite` caps expiry and uses at the parent's; wider roles or scope are an
  error).
- **Redemption.** `Hello.grant = SignedGrant{v: CHAIN, grant_id: leaf, token: postcard(chain)}`
  and `Hello.principal_id = grants::guest_principal(device)` (SHA-256 of the key, so guests
  never share a principal and need no round trip). The daemon verifies every link (signature,
  version, daemon, expiry, revocation of the grant and of every issuer/bound device, holder,
  narrowing); an unbound leaf is bound to the device on first use, refused once `max_uses`
  distinct devices hold it; the same device may reconnect any time. Refusals are
  `RefuseReason::InvalidGrant` or `Revoked`, and audited.
- **Invite** = iroh dial info + chain: `proto::Invite{daemon_id, addrs, relay_url, inviter,
  chain}`, text `<scheme>://join/<base32>` (`brand::URL_SCHEME`; `#` in place of the last `/`
  also parses, for a URL fragment). `un invite` prints a QR code (upper-cased, alphanumeric
  mode) and the link; an invite with one link is about 380 characters.
- Paired owner devices (pairing ticket, `devices.json`) keep working unchanged as `Owner` on
  `Daemon` scope; every connection (owner or guest) is told who it is with
  `ServerCtl::Joined(JoinInfo)` right after `Welcome`, whose `roles` now reflect the grant and
  whose `panes` are filtered by scope.
- State: `<state>/grants.json` (registered chains with their bound devices, revoked grants and
  devices, guest devices). `RegisterGrant` (owner, or the grant's own issuer) records a chain
  before first use so it can be listed and revoked.

### 6.2 Live checks and revocation

- Every inbound ctl message and every input frame first re-checks the connection's grant
  against the live table: expiry, any link revoked, device revoked (`Mp::still_valid`, a few
  hash lookups). Failure sends `ServerCtl::Revoked` and closes the connection 150 ms later.
  A 500 ms tick also disconnects expired grants without traffic.
- `Revoke(Grant | Device | Principal)` (owner, daemon scope) records the revocation, unpairs a
  revoked owner device, closes every affected connection at once (descendant grants are
  covered because every link id is checked), and answers with what it hit. A device cannot
  revoke itself. Re-dials are refused (`RefuseReason::Revoked`).
- Not undone by revocation (as Amp's docs warn): processes a guest started and files it
  changed.

### 6.3 Enforcement table

Checked in the daemon on every request (`crates/daemon/src/mp/policy.rs`). "In scope" means
the pane, tab or session lies inside the grant's scope; "host" means a daemon- or
session-wide grant (a pane- or tab-scoped guest never touches the host beyond its pane).
Refused ctl messages get `ServerCtl::Forbidden{what, reason}` naming the missing role; requests
with an id get the error in their answer (`OpError::Forbidden`, `WsError::Denied`,
`MpError::Forbidden`, `InputRejected{Role|NoLease|UnknownPane}`).

| Request | Needs | Target |
|---|---|---|
| `Subscribe`, `FetchHistory`, `Search`, `Links`, `Commands`, `CommandOutput`, `Focus`, `Visible`, `Ack` | any role | pane in scope |
| `Attach`, `ListSessions`, `Ping`, `Bye`, `Presence`, `WhoAmI`, `Participants`, `Leases`, `SetName` | any role | sessions/panes filtered to scope |
| `Resize` | any role (stored); **driver** and lease (or no lease) to size the PTY | pane in scope |
| Input `Bytes`, `Key`, `KeyFull`, `Paste`, `Mouse` | **driver** + holding the pane's lease | pane in scope |
| `MpRequest::Prompt` (composer path) | prompter, driver or approver; **agent pane only**; sanitizer | pane in scope |
| `Decide` | **approver**; valid Ed25519 signature by the deciding device | the request's pane in scope |
| `LeaseRequest{Ask}`, `TakeControl` | driver | pane in scope |
| `LeaseRequest{Force}`, `TakeControl{force}` | **owner** | pane in scope |
| `AnswerControl`, `ReleaseControl` | the lease holder | — |
| `GiveControl` | the holder, or owner; the recipient must be a connected driver | pane in scope |
| `Op`: `Focus`, `Resize` (divider), `ToggleZoom` | driver | pane in scope |
| `Op`: `FocusDirection`, `SelectTab`, `MoveTab`, `RenameTab` | driver | tab in scope |
| `Op`: `Split` | driver | the pane's whole session in scope |
| `Op`: `NewTab`, `RenameSession` | driver | session in scope |
| `Op`: `ClosePane`, `CloseTab`, `CloseSession` | **owner** | in scope |
| `Op`: `CreateSession`; `Attach` that would create a session | **owner** | daemon |
| `Workspace`: `ListPorts`, `AttentionList`, `AttentionSeen` | any role | answers filtered to scope |
| `Workspace`: `ListTurns`, `TurnDiff` | prompter, driver or approver | pane in scope |
| `Workspace`: `SendReview` | prompter, driver or approver (non-drivers: agent panes only) | pane in scope |
| `Workspace`: git, `Fs*` (read, write, watch), worktrees, `EditorStatus`, `EditorOpen`, `VsCodeTunnelStatus`, `VsCodeTunnelOpen` | driver | host |
| `Workspace`: `WorktreeLaunch` | driver | the pane's session |
| `Workspace`: `EditorLaunch`, `EditorStop`, `VsCodeCliInstall`, `VsCodeTunnelStart`, `VsCodeTunnelStop` | **owner** | daemon |
| Streams: `PortForward`, `Forward`, `Upload`, `Download` | driver | host |
| `RegisterGrant` | owner, or the chain's leaf issuer | — |
| `ListGrants`, `ListDevices`, `Revoke`, `Audit` | **owner** | daemon |
| `Artifact`: `List`, `Get`, `Export`; blob download | any role | artifact visible (below) |
| `Artifact`: `Create`, `Apply`, `Delete`, `SetAnchor`, `SetPreview`; `InkLive`; blob upload | **prompter or driver** | artifact visible; anchor pane / session in scope |
| `Artifact`: `Send` (to agent) | **prompter or driver**; **agent pane only** | pane in scope |
| `Op` `Split`/`NewTab` with `PaneLaunch::Canvas` | driver (as any split) | session of the pane |
| `Assist`: `Watch`, `State`, `BlockedOptions` / `SubmitLine` / `History`, `Complete`, `FileSearch` / `AnswerBlocked` | any role / **driver** + lease / **driver** / **approver** (§7.8) | pane in scope / pane / host / pane |

An artifact is visible to daemon- and session-wide grants in its session; tab- and
pane-scoped guests see only ink anchored to, or canvases shown in, panes inside their scope.

Pushes are filtered the same way: layout (a tab-scoped guest sees only its tab, a pane-scoped
guest a one-pane layout), pane meta, agent events, echo hints, command marks, decisions,
leases, presence focus/cursor, ports and attention items outside the scope are not sent; the
VS Code tunnel status goes to host-level drivers only.

The **prompter sanitizer** (`mp/prompt.rs`): text only (newline and tab allowed, every other
control character refused, so no ESC, `^C`, CR or bracketed-paste terminator), at most
16 KiB, no leading `!` (Claude's bash mode), `#` (memory) or `/` command outside
`/help /cost /context /status`. The prompt is written as the pane's paste (bracketed when the
agent enabled it), then Enter after 80 ms. Prompts are not leased (they interleave per
message, never per keystroke); the audit log keeps length and SHA-256 prefix, not the text.

### 6.4 Control lease

- One lease per pane, held by a principal (all its devices may type). Raw input from a driver
  takes a free lease (or one whose holder left) implicitly; input from anyone else while a
  connected holder has it is refused `InputRejected{NoLease}` plus the current
  `ServerCtl::Lease`, so the client can say who is driving. Every change is broadcast as
  `ServerCtl::Lease{pane, holder, since, mode: Leased|Free}` to everyone who can see the pane
  and sent on `Attach`; `MpRequest::Leases` lists them.
- `TakeControl{pane}`: granted at once if the lease is free, ours, its holder left, or the
  holder has not typed for `lease_idle` (default 5 s; `[multiplayer] lease_idle_secs`).
  Otherwise the holder gets `ServerCtl::LeaseRequested{pane, by, name}` and the answer is
  `Pending{holder}`; the holder answers `AnswerControl{give}` (`Kept` is sent to the asker),
  and if the holder stays idle for `lease_idle` the lease moves anyway (500 ms tick). An owner
  may `force`. `GiveControl{to}` (holder or owner), `ReleaseControl`. A holder's last device
  leaving frees the lease.
- Sizing follows the lease: only the holder (or anyone while it is free) sizes the PTY.
- Every move is audited (`Lease`).

### 6.5 Presence

`ServerCtl::Participants{participants}` (one entry per connected device: actor, name, roles,
scope, grant, since, state, focused pane, typing, cursor) is pushed whole on join, leave,
rename and focus change. Clients send `ClientCtl::Presence` (typing, cursor, viewport; at most
10 Hz per connection, typing changes always pass); the daemon stamps the actor and the focus it
knows and fans `ServerCtl::Presence` out to the others, hiding panes outside each recipient's
scope. `Client::set_typing(pane, bool)` is the composer's typing indicator.

### 6.6 Signed approvals and the audit log

- `Client::decide` signs `"approval-v1\0" ‖ postcard(daemon_id, request_id, option_id, actor)`
  with the device key (`Decide.sig`). The daemon requires the approver role on the request's
  pane and a valid signature by `actor.device` (= the connection's key), then the first valid
  decision wins (`Decided` to everyone in scope, `AlreadyDecided{by}` to the late one).
- `<state>/audit/audit.jsonl` (mode 0600), append-only, one JSON object per line, hex ids:
  `{seq, at, kind, actor{principal, device}, grant, pane, detail, approval?, prev_hash,
  hash}`, `hash = SHA-256("audit-v1\0" ‖ prev_hash ‖ postcard(record without hash))`.
  Kinds: `Join`, `Leave`, `Paired`, `GrantRegistered`, `GrantRedeemed`, `Revoked`, `Lease`,
  `Prompt`, `Approval`, `Denied` (refused joins, bad decision signatures). An approval record
  carries the request id, the agent's own request id for the tool call (the arbiter's id,
  e.g. the hook's tool-use id), option id and label, tool, summary, the signed bytes and the
  approver's signature; approvals are fsynced, and written before the agent's hook is
  answered or anyone is told. Raw keystrokes are never logged.
- `MpRequest::Audit{after, limit}` (owner) returns records oldest first plus `chain_ok`: the
  file on disk re-verified (every hash and every approval signature). An edited line breaks
  it (tested).

### 6.7 CLI

```sh
un invite --role driver+approver --scope session --ttl 24h --uses 1 --name bob [--delegate]
un join 'unnamed://join/…'        # saves the invite (used when no pairing ticket is saved)
un who [--watch]                  # participants, roles, scope, focus, typing
un take-control [--pane P] [--force] [--wait]     un release-control
un prompt 'fix the failing test' [--pane P] [--no-submit]
un grants [--devices]             un revoke <grant-id-prefix> | --device KEY | --principal ID
un audit [--limit N] [--after SEQ]
```

`un invite` from a guest signs a narrower child of its own grant (needs `--delegate` on the
parent). Separate identities on one machine: separate `XDG_CONFIG_HOME`.

### 6.8 Tests

- `cargo test -p grants`: property tests (64 cases each) — narrowing chains of up to 6 links
  verify with roles never above the root's; any flipped signature byte or edited field is
  refused; wider roles, later or missing expiry, more uses or a wider scope are refused both by
  `attenuate` and, hand-signed, by `verify`; expiry, revocation of any link or issuer, a wrong
  presenter, a wrong daemon, an untrusted root, a non-holder signer and a non-delegable parent
  are refused; approvals verify only for their daemon and option; ring and iroh derive the
  same public key.
- `cargo test -p daemon --test it multiplayer` (macOS and the Linux VM): owner + driver +
  viewer on one daemon (viewer's keys refused and never written; owner takes the free lease;
  driver refused without it; take control asked, given; owner refused; owner forces; handoff
  after idle; release; typing indicator; viewer cannot split, take control, list files or
  grants; driver can list files); prompter (raw keys refused; composer prompt arrives; shell
  panes, `!`, `/permissions`, ESC, `^C`, `#` refused; viewer cannot prompt; audit keeps length
  only); approvals (viewer's decision refused and the hook stays pending; approver's signed
  decision answers the hook; late decision loses; audit record's signature verifies and its
  signed bytes match); revocation (delegated viewer link, wider delegation refused, revoking
  the parent kicks both guests at once and re-dials are refused; device revocation; no
  self-revocation); bad grants (expired, foreign root, tampered, hand-escalated child, pane →
  daemon widening, second device on a single-use grant refused while the first reconnects;
  all audited as denials); a pane-scoped guest sees a one-pane layout and cannot subscribe to,
  or type into, another pane or reach host files.
- Unit tests: prompt sanitizer, audit chain (reopen, edit detection).
- `proto` goldens for every new message and variant; invite text round trip.


`proto::artifact` (wire), `crates/drawing` (model shared with client-core and `un`: packed
ink points, scene from the op log, SVG writer, rasteriser, PNG), `crates/daemon/src/art/`
(store, send, blob streams), `crates/daemon/src/anchor.rs` (row anchors),
`crates/client-core/src/artifacts.rs`, `crates/un/src/draw.rs`.

### 7.1 Model

- An **artifact** belongs to a session: a **drawing** (elements: strokes with packed points,
  rect/ellipse/line/arrow shapes, text, placed images; canvas units or terminal cells), an
  **Excalidraw scene** (§7.9) or an **image** (one blob). `ArtifactInfo` carries kind, title, coordinate space, creator, times,
  `version`, element count, the image, a `preview` PNG (a client's render of one version), the
  `anchor` and the canvas panes showing it.
- **Op log**: every `Apply` is one `OpBatch{version, actor, at, ops}` (add/replace, move,
  restyle, z, delete, clear, title). The daemon orders batches; `Scene::apply` takes exactly
  `version + 1`, so all clients converge. Elements are add-wins (an existing id is replaced),
  fields last-writer-wins.
- **Blobs**: SHA-256 content addressed, PNG or JPEG only (sniffed from the header), shared by
  all sessions, garbage-collected when no image artifact, preview or image element refers to
  them (after a grace period, so an upload waiting for its `Create` survives).

### 7.2 Protocol

`ClientCtl::Artifact{req_id, ArtifactRequest}` → `ServerCtl::ArtifactResult{req_id,
Result<ArtifactResponse, ArtifactError>}`: `List{session}`, `Create`, `Get{id, since}` (the
batches after `since`, else every element), `Apply{id, base, ops}`, `Delete`, `SetAnchor`,
`SetPreview{id, version, png}`, `Export{id, version, Png|Svg}`, `Send`. Pushes to the clients
attached to the session (`ServerCtl::Artifact`): `Created`, `Changed{info, batch}`,
`Info` (anchor detached, preview, canvas panes), `Deleted`, `Ink` (others' live strokes) and
`Canvases{session, [pane → artifact]}` (also sent on `Attach`). `ClientCtl::InkLive` streams
live points; the daemon stamps the actor and relays it to everyone else in the session.
Blobs move on bidirectional streams at bulk priority, `StreamHeader::Blob(Put{session, size,
media} | Get{hash})` → `BlobReply::{Ready, Stored, Found, Failed}`; QUIC flow control is the
backpressure. `Caps::ARTIFACTS` marks clients that understand all this. Goldens for every new
message in `crates/proto/tests/golden.rs`.

**Canvas panes** are ordinary `LayoutNode::Leaf`s created by `Split`/`NewTab` with
`PaneLaunch::Canvas{artifact: None}` (the daemon creates an Excalidraw scene) or `Some(id)`
(a drawing or scene). They run
no process; `Canvases` says which leaves they are. Not a new `LayoutNode` variant on purpose:
an old client would fail to decode the whole layout; this way it shows an empty pane.
Closing the pane keeps the drawing; deleting the drawing closes its canvas panes.

### 7.3 Ink anchors

`Create`/`SetAnchor` with `AnchorRequest{pane, at_seq, from_bottom}`: the daemon pins the row
on its VT (accounting for rows scrolled since `at_seq`), answers `RowAnchor{screen, at_seq,
from_bottom, command_id, state}` and clients track the row in their own VT. Anchors detach
(`RowGone` after eviction or `clear`, `AltScreenExited`, `PaneClosed`, `DaemonRestart`) and a

### 7.4 Send to agent

`Send{pane, artifact?, version?, png: Inline | Blob | Artifact}`: the pane must run an agent
(launched, detected or reporting hooks) or the answer is `NotAgentPane`. The PNG is the
client's render (inline ≤ 1 MiB, else an uploaded blob), or for `Artifact` the image, the
preview of that version, or the daemon's own rasterisation. It is written to
`<state>/artifacts/<session>/send/<artifact>@<version>.png` (atomically) and the path is pasted
character outside `[A-Za-z0-9_./@:-]`, e.g. `Application\ Support`), never followed by Enter.
The answer (`Sent{path, pasted, bracketed}`) comes 120 ms after the paste so the client's next
keystroke cannot overtake Claude's asynchronous attach. A bare image (no artifact) is kept as
an image artifact. Each send is audited (`Prompt` kind, path only).

### 7.5 Export

`Ascii`: `drawing::to_ascii` — box glyphs (`┌─┐`, `├`, `┼`) with junctions where lines
meet, arrows as orthogonal elbows ending in `▶◀▲▼`, ellipses `╭╮╰╯`, text in place, ink as
dots; Excalidraw scenes map 10 × 20 scene px to a character. `Png`: passthrough of the image blob or of the preview at the asked version; with no preview
the daemon rasterises (`drawing::rasterize`: anti-aliased pressure strokes, shapes; text and
images as outlines) and keeps that as the preview. `Svg`: `drawing::to_svg`, deterministic
(golden-tested), images inlined as data URIs up to 8 MiB each. Results over 1 MiB come back as
a blob hash to download.

### 7.6 Storage and caps

`<state>/artifacts/`: `index.bin` (next id, canvas panes), `<session>/<id>/info.bin`,
`<session>/<id>/ops.log` (length-prefixed postcard batches, appended and `fdatasync`ed per
batch; a torn last frame is dropped on load), `blobs/<sha256>`, `<session>/send/`. Closing a
session deletes its artifacts. Caps (`Config::artifacts`): blob 32 MiB, whole store 1 GiB,
one drawing's log 8 MiB, one batch 1 MiB, 1000 artifacts per session, 20 000 elements per
drawing, 16 KiB per text and per ink chunk; over a cap → `TooLarge`.

### 7.7 Client core and CLI

`Client::artifacts / artifact_create / artifact_get / artifact_apply / artifact_delete /
artifact_set_anchor / artifact_set_preview / artifact_export / send_to_agent / blob_upload /
blob_download / ink_live` (blob transfers also as `*_with_progress`, reporting every
64 KiB); pushes go to an `ArtifactListener` (`ArtifactUpdate::Event` or `Synced`). The client caches a `drawing::Scene` per artifact it has seen: pushed batches apply
in order, a gap or a reconnect fetches `Get{since}` (resync), `artifact_scene(id)` reads it.
`un draw list | show | export | send` (show: kitty graphics when the terminal supports it,
from the environment or an `a=q` query; else a braille render and a summary).

### 7.8 Tests

`cargo test -p daemon --test it artifacts` (macOS and Linux): Excalidraw scenes (a canvas pane
creates one; concurrent puts reconcile with the version / nonce rule on both clients and the
daemon, stale offers come back as winners, deletions, resync after a reconnect, ASCII/SVG/PNG
export, a viewer reads but cannot put or import); a canvas pane with peers
(`canvas_pane_with_peers_syncs_inks_resyncs_and_closes`: owner, second device, driver guest
and viewer on one `Split` canvas — `Canvases` on attach and reconnect, realistic rectangle /
freedraw / text elements pushed live with put→push latency printed, edits of each other's
elements, a concurrent tie settled by `versionNonce` on every client and the daemon, live ink
stamped and not echoed, tombstones, resync after suspend, viewer refused, closing a `NewTab`
canvas keeps the scene, deleting the scene closes its pane everywhere); inline placements
(placed at the cursor row, followed through 40 lines of output, sent to a client attaching later, replaced after
an edit, a kitty PNG printed by a program in the pane captured as an image artifact and
placement with its `c`/`r` size, a dropped `.excalidraw` file and photo imported and placed,
detached by `clear`, removed, kept detached after a restart with the scene intact); two
clients — live ink fan-out
(200 chunks, latency printed, no echo to the sender), batches from both converge, the second
client suspended while the first draws resyncs to the same scene on reconnect, an anchor
detaches after `clear`; a viewer lists, reads and exports but cannot create, apply, delete,
send, upload or ink (and its ink never reaches the owner); send-to-agent into a fake agent
(`cat -v` behind bracketed paste) from a state dir containing a space: escaped bracketed path,
no Enter, file bytes, `NotAgentPane` for a shell, bare images and daemon renders; canvas pane,
image blob, preview, PNG/SVG export, blob download, then a daemon restart keeps artifacts,
versions, scenes, blobs and the canvas pane; caps. Unit/golden: `crates/drawing` (packing,
simplification, scene convergence, SVG golden, rasteriser, PNG), anchors
(`daemon::anchor`, `ghostty-vt` `anchors`), paste escaping, proto goldens.

### 7.9 Excalidraw scenes

The non-Pencil editor (finger, mouse, trackpad) is Excalidraw (MIT), bundled offline in a
WKWebView; the daemon is its sync and persistence backend. Elements stay Excalidraw's JSON
(`ExElement{id, version, version_nonce, deleted, json}`; the daemon checks the fields
against the JSON). `ExcalidrawPut` reconciles each element with Excalidraw's own rule —
higher `version` wins, a tie goes to the lower `versionNonce`, deletions are tombstones — and
answers `ExcalidrawApplied{version, rejected}` (the stored winners for offers that lost); the
winners go to everyone else as `ArtifactEvent::Excalidraw`. `ExcalidrawGet{since}` returns the
elements changed after a revision (every element at 0), app state and files. Images are blobs
(`ExFile{file_id, image}`), so a scene never carries data URLs over the wire. Scenes are
written to `excalidraw.bin` once a second when changed and on shutdown; the whole scene is
capped by `log_max`, an element by 512 KiB. client-core caches every scene it has seen
(`excalidraw_scene`), applies pushes with the same rule and catches up after a reconnect.
Export (SVG, PNG, ASCII) converts elements to vectors (rectangles, ellipses, diamonds, arrows
and lines, freedraw with pressure, text, images); the hand-drawn look is the app's (its PNG
render, uploaded as preview or with `Place`/`Send`).

### 7.10 Inline placements ("never leave the terminal")

A **placement** shows an artifact inside a terminal pane: a `cols × rows` cell box at column
`col` of an anchored row, drawn by clients over the cells like kitty graphics, scrolling with
the output (the anchor is a tracked pin, §7.3). The daemon owns image and placement state
because Ghostty snapshots carry no images: placements are sent on every `Attach` (resume,
reattach, a new device) and as `ArtifactEvent::Placed` / `Unplaced`, and persisted in
`index.bin` (detached after a restart). Three ways in:

- **Place** (`PlaceRequest{pane, artifact, version, anchor | cursor row, col, cols, rows,
  png, replace}`): the overlay's "done". `png` is the device's render, else the image, the
  preview or the daemon's render; sizes default from the image (pane cell pixels if known,
  else 2× renders of 9 × 18 pt cells) clamped to the pane's width; `replace` swaps the
  placement the overlay was re-opened from.
- **Import** (`ImportRequest{pane, name, data | blob}`): a pasted or dropped image or
  `.excalidraw` file becomes an artifact placed at the cursor row.
- **kitty graphics in the output**: the output scanner (`kitty.rs`) recognises PNG images a
  program displays with the kitty protocol (`a=T,f=100`, direct, chunked or not; `c`/`r`
  sizes), pins the cursor row at the exact byte where the sequence ends (the VT write is split
  there), and keeps the PNG as an image artifact plus a `Kitty` placement. So `un draw show`,
  `kitten icat` or an agent printing an image inside our pane shows inline on every client
  and survives snapshots. Not handled: transmit-then-place (`a=t` + `a=p`), raw RGB data,
  file/shm transmission, animation, deletes. The daemon's and clients' VTs keep kitty storage
  off, so both ignore the sequence identically.

Roles: `Place`, `Unplace`, `Import` need the draw role on the pane; `Placements` any role.

### 7.11 App-side contract (for the Swift app)

**Draw mode on a terminal pane (the primary UX).**
1. Enter with a Pencil touch on the pane (iPad, `drawingPolicy = .pencilOnly`), a
   two-finger long press, or a key (key bar button / ⌃⌘D in the app: ⇧⌘D is Ghostty's Split
   Down). Built: `apple/App/Sources/Drawing`, apple/README.md "Drawing". Fingers keep scrolling and
   selecting while Pencil inks.
2. The overlay is a transparent layer over the pane, anchored to the row under the first
   touch: `AnchorRequest{pane, at_seq: the VT's applied seq, from_bottom}`. It scrolls with
   the output (pin that row in the app's own VT once it has applied `at_seq`).
3. The overlay holds one **Excalidraw scene** (`artifact_create(kind: Excalidraw, anchor)`):
   shapes, connected arrows and text from the embedded editor in transparent mode, and Pencil
   strokes converted from `PKStroke` to Excalidraw `freedraw` elements (points + pressures).
   Overlay scene units: **10 scene px = one column, 20 = one row**, origin at the anchor
   row's left edge — the app maps to points with its own cell size, so ink stays on the text
   across fonts and devices, and the ASCII export lines up with cells. While the pen moves,
   stream `ink_live` every ~16 ms (peers draw it in the author's presence colour); commit
   with `excalidraw_put`.
4. **Done**: render the overlay (Excalidraw `exportToBlob` + ink) to PNG and
   `place_png(PlaceRequest{anchor: same row, col, cols/rows: the covered cells,
   replace: the placement it was re-opened from})`. The diagram is now part of the pane's
   output for every client and device.
5. **Tap a placement** for its menu (send, copy, share, Edit, Delete); Edit reopens the overlay in place: `excalidraw_get(placement.artifact_id)`
   at `placement.anchor`, then Done again with `replace`.
6. **Send to agent** from the overlay or a placement's menu:
   `send_to_agent(pane, Some(id), Some(version), Some(png))`.

**Rendering placements.** `Client::placements(pane)` (pushed on attach and on change). For
each `Live` placement: once the VT has applied `anchor.at_seq`, pin the row `from_bottom`
above the bottom; draw `image` (fetch with `blob_download`, cache by hash) as a quad over
`cols × rows` cells from column `col`, in the "above text" layer (the same pass as kitty
images and ink). `Detached` placements leave the grid and go to the pane's loose tray.

**Canvas pane (secondary).** A `Canvas` leaf (`ArtifactEvent::Canvases`) hosts the same
Excalidraw editor full-size, free scene units.

**Paste / drop onto a pane.** Images and `.excalidraw` files → `import_to_pane(pane, name,
bytes)`; with the "send" modifier onto an agent pane → `send_to_agent(pane, None, None,
Some(png))`.

**Excalidraw in WKWebView: the JS bridge.** The bundle (`@excalidraw/excalidraw`, MIT,
fonts included) loads from app resources over a custom scheme (`<brand>-canvas://`), no
network. Swift → JS calls `window.canvas.<fn>(json)` through `evaluateJavaScript`; JS → Swift
posts to `window.webkit.messageHandlers.canvas.postMessage(msg)`:

| Direction | Message | Meaning |
|---|---|---|
| JS → Swift | `{type: "ready", version}` | editor mounted |
| Swift → JS | `load({elements, appState, files, mode: "overlay"\|"canvas", readOnly, theme, cell: {w, h}})` | initial scene from `excalidraw_get(id, 0)`; `files` are `{id, mimeType, dataURL}` built from blobs; `readOnly` for viewers (`viewModeEnabled`); overlay mode = transparent background, no grid, no menu |
| JS → Swift | `{type: "change", elements: [changed], appState: {viewBackgroundColor, gridSize}}` | from `onChange`, only elements whose `version` grew since the last post, throttled to 50 ms (Excalidraw's collab cadence); Swift → `excalidraw_put` |
| Swift → JS | `applyRemote({elements, files})` | pushes and `rejected` winners; JS runs `reconcileElements(local, remote, appState)` and `updateScene({elements, captureUpdate: NEVER})` so remote edits never enter the local undo stack |
| JS → Swift | `{type: "files", files: [{id, mimeType, dataURL}]}` | images added in the editor; Swift decodes, `blob_upload`s, and sends `ExFile{file_id, image}` with the next put |
| Swift → JS | `exportImage({requestId, format: "png"\|"svg", scale, exportPadding})` | JS answers `{type: "export", requestId, data: base64}` (`exportToBlob` / `exportToSvg`) for Done, `Send`, previews |
| JS → Swift | `{type: "pointer", x, y, tool}` | optional, ≤ 10 Hz, for presence cursors |
| JS → Swift | `{type: "done"}` / `{type: "cancel"}` | overlay toolbar buttons |

Viewers get `readOnly`; the daemon refuses their puts anyway (`Forbidden`).

**Moving and exporting a placed drawing (app).** A placement's menu has Copy Image (PNG plus
the `.excalidraw` scene on the same pasteboard item, so Universal Clipboard carries both), Copy
as Text (`Export{Ascii}`), Share…, and an Export submenu: PNG (the device's render), SVG
(`Export{Svg}`), Excalidraw (`Client::excalidraw_file`: the scene's elements, app state and
blobs as `data:` URLs; an image becomes a one-element scene) and ASCII. Dragging a placement
out (iPad `UIDragInteraction`, Mac `NSDraggingSource` with a promised PNG file) offers PNG and
`.excalidraw` to other apps and a `DrawingDragRef{host, pane, placement, artifact, image}` to
the app's own panes: dropped on another pane of the same host it is placed there with the same
render (`place_png`, same artifact); on another host it is imported (`.excalidraw`, else the
PNG) and placed with the render; on an agent pane it is sent (`send_to_agent`). Type
`com.excalidraw.json` is declared as imported (`apple/project.yml`).

### 7.12 MCP pull channel

Agents read the session's drawings themselves (push is §7.4). `un-hook mcp [--state <dir>]
[--pane <id>]` is a stdio MCP server (`crates/hostd/src/mcp.rs`): JSON-RPC 2.0, one message per
line; `initialize` echoes the client's `protocolVersion` if it is 2024-11-05, 2025-03-26 or
2025-06-18 (else 2025-06-18), capabilities `{tools: {}}`, `serverInfo.name`
`<product>-drawings`; `ping`, `tools/list`, `tools/call`; notifications get no answer; unknown
method −32601, unknown tool −32602, unparsable line −32700. Tools (both read-only):

| Tool | Arguments | Result |
|---|---|---|
| `list_drawings` | — | text: one line per artifact, newest first; then the same as JSON |
| `get_drawing` | `id?` (default: newest non-image), `format?` `png`\|`svg`\|`ascii`\|`excalidraw` (default `png`), `version?` | caption + PNG as `image` content, SVG/ASCII/the `.excalidraw` scene as `text` |

Failures (daemon down, bad id, too large) are `isError: true` results, never JSON-RPC errors.

Each tool call is one line on the hook socket (shared with hooks and askpass, told apart by
the `pull` field; `crates/daemon/src/art/pull.rs`):

```text
→ {"v":1,"token":"…","pane":"12","pull":{"op":"list"}}
← {"list":{"session":1,"artifacts":[{"id":3,"kind":"drawing","title":"arch","version":2,
   "updated_at":1761000000000,"elements":5,"placed_in":[12],"canvas_in":[],"ink_over":12,
   "width":640,"height":320}]}}
→ {"v":1,"token":"…","pane":"12","pull":{"op":"get","id":3,"format":"png","version":2}}
← {"export":{"id":3,"title":"arch","version":2,"format":"png","mime":"image/png",
   "data":"<base64>","base64":true}}
← {"error":"no artifact 9 in this session"}
```

The pane picks the session; artifacts of other sessions read as unknown. A bad token, a pane
in no session, an unknown format or an export over 8 MiB is an `error`. Exports are §7.5's
(`art::export`), run off the async workers; `kind` is `drawing`, `excalidraw` or `image`;
`width`/`height` are the image's or the last preview's. Formats are the `PULL_FORMATS` table
(name, `ExportFormat`, MIME, binary); a row there is all a new format needs.

The server finds the socket in `<state>/hook.endpoint` (re-read per call) and the token in
`<state>/hook.token`, never in argv. Without `--state` it uses `UN_ENDPOINT_FILE`/`UN_SOCK` and
`UN_TOKEN`, else the default state dir; without `--pane`, `UN_PANE_ID`.

**Agents the daemon launches** get it with no change to the user's config. The server name is
`<product>_drawings` (`agents::mcp_server_name`, valid for both). Claude: `--mcp-config
<state>/claude/mcp/<pane>.json` (`{"mcpServers":{"unnamed_drawings":{"type":"stdio","command":
"<hook_bin>","args":["mcp","--state","<state>","--pane","<pane>"]}}}`, added to the user's
servers; no `--strict-mcp-config`), and the `--settings` file (v3) allows
`mcp__unnamed_drawings`. Codex: `-c mcp_servers.unnamed_drawings.command="<hook_bin>"` and
`-c mcp_servers.unnamed_drawings.args=["mcp","--state","<state>","--pane","<pane>"]` (TOML
strings, escaped).

**By hand** (an agent we did not launch, started in one of our panes, whose environment
carries `UN_PANE_ID`, `UN_TOKEN` and the endpoint):

```sh
claude mcp add unnamed_drawings -- /path/to/un-hook mcp
# ~/.codex/config.toml
[mcp_servers.unnamed_drawings]
command = "/path/to/un-hook"
args = ["mcp", "--pane", "12"]
```

Codex starts MCP servers with a reduced environment, so give it `--pane` (and `--state` when
the state dir is not the default). Tests: `mcp::tests` (protocol over a fake backend),
`tests/it/pull.rs` (socket: list, png/svg/ascii/excalidraw, other session, bad token, stray pane),
`hostd/tests/mcp.rs` (the built `un-hook mcp` against a daemon).

### 7.13 Version history

A drawing's **finished versions** are kept per artifact (`art/history.rs`,
`<session>/<artifact>/history.bin`): one when it is placed from the overlay (`Place` at the
current version, with that render), when a client sets a preview of the current version, and
for drawings shown in a canvas pane once nobody changed them for 30 s. An Excalidraw scene
keeps only its latest elements, so its entry holds a copy of the live elements, app state and
files; an op-log drawing replays its log. At most 100 entries and four times the per-drawing
cap; their blobs are kept from garbage collection.

`History{artifact}` → `History([ArtifactVersion{version, at, by, image, elements,
restored_from}])`, newest first (any role). `Restore{artifact, version}` (draw role) writes the
old content as a **new version on top**: each old element at a version above both its own and
the current one, a tombstone for every element added since; the change goes out as an
ordinary `Excalidraw` (or `Changed`) push, so open editors and caches converge without a
reload. The artifact's preview and every placement of it switch to the old render (`Placed`,
same placement id; the height follows the image), and the restore is itself recorded
(`restored_from`). Both requests are gated by `DaemonFeatures::ARTIFACT_HISTORY` (older daemons
drop a connection that sends them; client-core refuses locally). CLI: `un draw history <id>`,
`un draw restore <id> <version>`, `un draw export <id> --format excalidraw`. App: Version
History in a placement's menu (each version with its render, the shown one checked; picking

D9). Wire types: `proto::assist` (append-only; goldens in `crates/proto/tests/golden_assist.rs`).
Requests are `ClientCtl::Assist{req_id, AssistRequest}` → `ServerCtl::AssistResult{req_id,
Result<AssistResponse, AssistError>}`; pushes are `ServerCtl::Assist(AssistPush)`. A daemon
without them never sends them, so an older daemon leaves the app in direct-typing mode.
Code: `crates/daemon/src/assist/` (one module per need), `crates/client-core/src/assist.rs`
(`Client::watch_prompt`, `pane_assist`, `submit_line`, `history`, `complete`, `file_search`,
`blocked_options`, `answer_blocked`; pushes to an `AssistListener`, the latest foreground and
prompt state per pane kept for `Client::foreground` / `Client::prompt_state`). Text positions
(`cursor`, completion ranges, match positions) count Unicode scalar values.

### 8.1 Foreground program (D1)

One task samples every pane's foreground process group every 100 ms (`tcgetpgrp` on the PTY
master; name from `argv[0]`, else the kernel's name; on macOS setuid programs such as `top` are
named through `PROC_PIDT_SHORTBSDINFO`). A program is reported once it has stayed in front
for 150 ms (so about 200 ms after it starts): `ls` or a prompt's `git` call never produce an
event. `AssistPush::Foreground{pane_id, pid, name, argv, profile, since}` goes to every client
whose attached session holds the pane; `AssistRequest::State` answers it too.
`ProgramProfile::classify` (in `proto`, usable by the app): `Shell` (bash, zsh, fish, sh, dash,
ksh, tcsh, nu, …), `Vim` (vi, vim, nvim, view, hx, kak), `Pager` (less, more, man, most),
`Monitor` (top, htop, btop, btm, glances, atop, nvtop), `Tmux` (tmux, screen, zellij), `Repl`
(python, node, irb, ghci, iex, lua, psql, sqlite3, redis-cli, … when started without a
script), `Claude`, `Codex` (also as `node …/claude`), `Other`.

### 8.2 Prompt state and the input line (D2)

- **Prompt id**: changes whenever a command starts (`133;C`), so it names one prompt instance;
  redraws of the same prompt (resize, Ctrl-L, `reset-prompt`) keep it. Phases: `AtPrompt`,
  `Running{command_id}`, `Unknown` (no integration yet, alternate screen).
- **Input line**: from the `133;B` pin to the end of the logical line the cursor is on (rows
  up to the cursor joined: soft wraps with nothing, hard breaks with `\n`; then the cursor's row
  and the rows it soft-wraps into). Cells libghostty-vt marked as prompt (`133;P` continuation
  prompts) are dropped. Typed trailing spaces before the cursor are kept. The read happens
  under the pane's VT lock (`Terminal::row`, new in `ghostty-vt`: text, width, style and OSC 133
  role per cell), the parsing after it.
- **Autosuggestions** (zsh-autosuggestions `POSTDISPLAY`, fish): text from the cursor to the end
  drawn faint, in palette color 8, in the grey ramp 232–250, or in a dim grey RGB, when the text
  before the cursor is not, is cut and reported as `suggestion`. Another single non-default
  style after the cursor that the typed text does not use is kept but flagged
  `PossibleGhostText`. Syntax highlighting (zsh-syntax-highlighting colours words before and
  after the cursor alike) is not mistaken for it.
- **Right prompt**: while the cursor still waits at the input start after the prompt is drawn
  (it may arrive in several reads), text after a gap on that row is remembered as the right
  prompt and cut from later readings while it is still there; zsh leaves `RPROMPT` on the line
  when it runs it, so it is also cut from the command text of the mark (and history). Unknown
  trailing text at the right edge after a gap of 3+ cells is cut as a guess
  (`RightPromptGuess`).
- **Multi-line prompts** are fine (their `133;P;k=s` comes before `133;B`). A continuation prompt
  (PS2) after the input start flags `Continuation`; non-blank rows below the line (a completion
  listing, the tail of a multi-line buffer) flag `ContentBelow`.
- **fish 3** sends no `133;B`: the input start is inferred from where the cursor is once the
  prompt is drawn (output within 25 ms of `133;A` still counts as prompt) and flagged
  `NoInputMark`. The same inferred start gives fish's command marks their text.
- **Confidence**: `confident` is true only when there is no doubt; the client prefills its
  editor only then. Each state carries `shell` (from the foreground program), whether bracketed
  paste is on, and `keymap` (always `Unknown` until the D2b hook exists).
- **Pushes**: `AssistRequest::Watch{pane, true}` answers the state now and from then on the
  connection gets `AssistPush::Prompt` whenever the state changes; watched panes are re-read
  every 40 ms when output arrived since the last read (debounce), unwatched panes cost nothing.

### 8.3 Atomic submit (D3)

`SubmitLine{pane, prompt_id, text, run}`: the daemon re-reads the prompt and refuses with
`AssistError::NotAtPrompt(state now)`, writing nothing, unless the pane is `AtPrompt` with the
same id, no continuation prompt is up, no alternate screen, and the foreground group is a
shell right now (sampled, not the debounced report). Text with control characters other than
newline and tab is refused, and newlines without bracketed paste. Then, as **one** PTY write:
`^E ^U` (end of line, kill to line start: `unix-line-discard` in readline, `kill-whole-line`
in zsh's emacs keymap, `backward-kill-line` in fish), the text as the pane's paste (bracketed
when mode 2004 is on), and `\r` when `run`. Same lease rule as raw input (a pane leased to
someone else is refused). Answer: `Submitted{prompt_id, at_seq}`.

### 8.4 History (D4)

- Every finished command with text is appended to `<state>/history/commands.jsonl` (0600,
  directory 0700): `{"c", "d": cwd, "x": exit, "ms": duration, "t": unix ms, "n": count}`. In
  memory: one entry per distinct command (count, last run's cwd/exit/duration, up to 8
  directories with their counts). Past twice `max_entries` lines the file is rewritten from
  the entries (one line per command and directory) keeping the `max_entries` most recently
  used, so duplicates fold away.
- **Import, once** (marker `imported.json` lists sources and counts): `$ZDOTDIR/.zsh_history`,
  `~/.zsh_history` or `~/.histfile` (plain or extended `: start:elapsed;cmd`, backslash-continued
  multi-line commands, zsh metafication undone), `~/.bash_history` (`#epoch` lines honoured), and
  fish's `fish_history` (`- cmd:` / `when:`, `\n` and `\\` escapes). Lines without a time get
  the file's mtime, a second apart in file order.
- **Privacy**: a command typed with leading whitespace is never recorded (bash `ignorespace`,
  zsh `HIST_IGNORE_SPACE`), nor imported. `config.toml`:
  `[history] enabled = true, ignore_space = true, max_entries = 50000, import = true`.
- `History{cwd?, prefix?, contains?, since?, limit ≤ 1000}` → distinct commands ranked by
  frecency: recency bucket (4 / 2 / 1 / 0.5 / 0.25 for < 1 h / day / week / month / older) ×
  (1 + ln(1 + count)) × place (3 + ln(1 + n) when used in `cwd`, 1.5 in a parent or child
  directory) × 0.7 when the last run failed.

### 8.5 Completion (D5)

`Complete{pane, line, cursor, limit ≤ 200}` → `Completions{cwd, items: [{text, display, kind,
detail, start, end}]}` (replace `line[start..end]` with `text`). The line is split into shell
words (quotes, backslashes, `; | & ( ) < >`; `sudo`, `env`, `time`, … and `VAR=x` keep the
command position). Sources, in order: whole-line **history** (with the cursor at the end, top 4
by frecency in the pane's directory), **git** (subcommands after `git`; branches, tags, remote
branches after `checkout`/`switch`/`merge`/`rebase`/`log`/`diff`/…; changed and untracked
files, relative to the pane's directory, after `add`/`restore`/`rm`/`diff`/…; refs and status
cached 3 s per work tree), **commands** on the pane shell's initial `PATH` in command position
(cached 30 s), **paths** relative to the pane's OSC 7 directory (`~` expanded, dot files only
for a word starting with `.`, directories first with a trailing `/`, case-insensitive fallback,
quoted for an open `'`/`"` or with backslashes).

Measured (`completion_sources_and_latency_with_10k_history`, a 10 000-entry history, a git
repo, 300 requests over the client, loopback; Linux: the OrbStack Ubuntu 24.04 arm64 VM).
are warm; the cold costs are the first ref and `$PATH` lookups after their 3 s / 30 s expiry.

| | macOS 26, M5 Max (release) | Linux VM (release) |
|---|---|---|
| warm, 300 mixed requests | p50 0.2 ms, p95 0.2 ms, max 0.4 ms | p50 0.3 ms, p95 0.7 ms, max 1.9 ms |
| cold: first ref lookup (`for-each-ref` + `status`) | 30 ms | 2.7 ms |
| cold: first `$PATH` scan | 8 ms | 4.2 ms |
| `History` query over 10 000 entries | 0.3 ms | 0.3 ms |

### 8.6 File search for `@` mentions (D7)

`FileSearch{root, query, limit ≤ 200}` → `FileMatches{root, matches: [{path, kind, positions}],
scanned, truncated}`. The root goes through the path policy (§5.0). The tree is walked in
parallel with the `ignore` crate (ripgrep's walker: `.gitignore` even outside a repository,
`.ignore`, global excludes, hidden files skipped), at most 200 000 entries, cached 10 s per root.
The query is a smart-case ordered subsequence of the relative path, scored fzf-style (segment
and word starts, consecutive runs, matches inside the file name; gaps and long paths cost).

### 8.7 Blocked agent options (D9)

What already existed: `PaneMeta.agent` = `Blocked{request_id, summary, options: [{id, label}]}`
and the `AgentEvent` JSON (`blocked.options`, `answer_paths`), filled only from hook payloads,
with no way to answer a dialog the hook does not hold. Added: `BlockedOptions{pane}` →
`BlockedPrompt{request_id, summary, options: [{label, choice: AllowOnce | AllowSession | Deny |
Other, option_id, keys, selected}], source: Hook | Screen}`. The numbered menu on screen
(Claude's boxed `❯ 1. Yes` dialog, Codex's `› 1. Yes, proceed (y)`, wrapped labels joined) gives
every option its keys (the digit, or the `(y)`/`(esc)` hint) and the selected row. With a hook
holding the request open the hook's options come first, with `option_id` for the signed
`Decide` path and keys matched from the screen; otherwise the screen's menu alone.
`AnswerBlocked{pane, index, label}` re-reads the menu, refuses if that index no longer shows
that label, then types the keys; it is audited as an `Approval`.

### 8.8 Roles

All requests go through `mp/policy.rs` (`policy::assist`), and pane-addressed ones must be in
the grant's scope:

| Request | Needs | Target |
|---|---|---|
| `Watch`, `State` (prompt state, foreground), `BlockedOptions` | any role | pane in scope |
| `SubmitLine` | **driver** (+ the lease rule of raw input) | pane in scope |
| `History`, `Complete`, `FileSearch` | **driver** | host (other panes' commands, the file system) |
| `AnswerBlocked` | **approver** | pane in scope |

Prompt pushes go only to connections watching the pane (and with it in scope); foreground pushes
to connections whose attached session holds it.

### 8.9 Tests

- `cargo test -p daemon --lib assist`: line reading (cursor, trailing spaces, soft wraps and wide
  characters, autosuggestions in colour 8 and faint, syntax highlighting, doubtful styled tails,
  right prompts remembered and guessed, multi-line prompts, listings below, continuation
  prompts, fish without `133;B`, prompt ids, leading-space privacy, right prompt kept out of
  command marks), history (persistence, dedupe, directory ranking, compaction, the privacy
  switch), the three history formats and a one-time import, the shell word splitter and
  quoting, path/`$PATH`/history completion, fuzzy scoring and the ignore-aware walk, menu
  parsing (Claude box, Codex hints), the foreground debounce, submit bytes.
- `cargo test -p daemon --test it assist` (macOS: zsh; the Linux VM: zsh, bash 5.2, fish 3.7):
  per shell, watch → typed line, cursor movement, (zsh) a fake zsh-autosuggestions suggestion and
  `RPROMPT` cut with the reading still confident, atomic submit replacing a half-typed line,
  stale prompt id and running command refused with nothing written, history with cwd and exit
  and without the leading-space command, path and history completion; foreground profiles for
  `less`, `top`, `vi` with `/bin/echo` never reported; git ref/path, `$PATH` and path
  completion plus the latency benchmark above; file search honouring `.gitignore` and the path
  policy; a fake Claude dialog answered by keys after a stale label is refused, and the hook's
  options carrying decision ids and screen keys; a viewer reading state but refused submit,
  history, completion, file search and answers.

### 8.10 Limits

- Keymaps are not known (D2b, the OSC 7702 buffer hook, is not built): submit assumes the emacs
  keymap. In zsh's vi insert mode `^U` only kills back to where insert started, and `^E` is not
  bound, so a line typed before entering vi command mode may survive.
- Multi-line buffers: only the cursor's logical line is read when rows follow it, and `^U`
  clears one line, so submit is refused at a continuation prompt; a multi-line zsh buffer
  edited with the cursor on an earlier line reads as not confident.
- Ghost text in an unusual colour (not faint, not grey) is reported as doubt, not removed;
  ghost text in the same style as typed text cannot be told apart.
- The right prompt is learnt when the prompt appears; one that changes while typing (a clock)
  falls back to the guess rule.
- Completion's `PATH` is the shell's environment at start (`/proc/<pid>/environ`, macOS
  `KERN_PROCARGS2`): `PATH` changes made in rc files after that, aliases, functions and builtins
  are not offered; flags and command-specific arguments are not completed (D5a). Git commands
  are not interrupted at the 150 ms deadline; the first lookup in a large repository can exceed
  it.
- History records commands only from panes with shell integration; commands run while no
  daemon ran come only from the one-time import.
- fish 3 (no `133;B`): if its prompt reaches the PTY in reads more than 25 ms apart (a heavily
  loaded host), the inferred input start lands inside the prompt, so the line and the command
  text carry a prompt tail (fish 3 readings are never marked confident), and a leading-space
  command may then not be recognised as private. fish 4 marks its input itself.
- Foreground changes shorter than ~200 ms are never reported (by design); the app should not
  rely on them for programs that exit at once.
- D2b, D5a, D6 and D8 (Phase 2) are not built.

## 9. Native password prompts (`proto::askpass`)

When a program in a pane asks for a secret, the app shows a secure prompt anchored to the pane
instead of the user typing blind into the terminal. Two sources, one wire (`Caps::ASKPASS`,
`ClientCtl::Askpass` → `ServerCtl::AskpassResult`, pushes `ServerCtl::Askpass`).

### 9.1 Askpass

- **Environment.** Every pane gets `SUDO_ASKPASS`, `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=prefer`
  (OpenSSH ≥ 8.4 then uses it even with a terminal) and `GIT_ASKPASS`, all naming
  `<state>/askpass/un-askpass`: a two-line script, rewritten on start, that runs
  `un-hook askpass "$@"` (also `unnamed-hostd askpass`). `UN_ASKPASS` names it too, and the
  pane gets the hook socket's coordinates (`UN_SOCK`, `UN_TOKEN`, `UN_ENDPOINT_FILE`).
  The user's dotfiles run after and can override any of them. `[askpass] enabled = false`
  in `config.toml` turns all of this off.
- **Helper.** `un-hook askpass <prompt>` sends one JSON line on the hook socket
  (`AskpassCall{v, token, pane, askpass: {prompt, program, confirm, probe}}`; `program` is its
  parent's command line, `confirm` is `SSH_ASKPASS_PROMPT=confirm`) and reads one line back:
  `{"answer": "…"}` (printed with a newline, exit 0), `"cancelled"` (exit 1) or `"terminal"`.
  On `"terminal"`, or when the daemon cannot be reached, it asks on `/dev/tty` itself with echo
  off, so nothing is worse than without it. `SSH_ASKPASS_PROMPT=none` (a FIDO touch notice) is
  printed on the terminal. `--available` only asks whether an app could answer (exit 0/1).
- **Daemon.** Checks the hook token and the peer's uid (same user), cleans the prompt and
  program text (control and bidi characters removed, ≤ 512 characters), classifies the program
  (`Sudo`, `Ssh`, `Git`, `Gpg`, `Other`; a script's name, not its interpreter's), marks yes/no
  questions `echo` (ssh's host key question, git's username) and a question repeated within
  60 s of an answer as `retry`. With nobody able to answer it replies `"terminal"` at once.
  Otherwise it pushes `AskpassPush::Prompt` and waits for the first of: an answer
  (`Closed{Answered{by}}`), a cancel (`Cancelled{by}`), the timeout (`[askpass] timeout_secs`,
  default 300: `TimedOut`, the program gets no answer), the helper's connection closing
  (Ctrl-C: `Abandoned`), or nobody able to answer for 10 s (`MovedToTerminal`, the helper asks
  on the terminal). Every connection's sheet closes with that `Closed`.
- **Who sees it.** Connections that announced `Caps::ASKPASS` (the app; `client-core` with
  `ConnectOptions::askpass`), are attached to the pane's session and hold Driver or Owner on the
  pane. Guests who only watch never get the prompt text, and their `Answer`/`Cancel` are
  `Denied`. Open prompts are sent again on attach (same ids), so a reconnecting app keeps its
  sheet. The first `Answer` wins; later ones get `Gone`.
- **Secrets.** `proto::Secret` redacts its `Debug` output and zeroes its bytes on drop; the
  helper's reply buffer, the JSON line and the helper's stdout buffer are zeroed after use. The
  daemon logs prompt ids, panes, sources and close reasons, never the answer. Answers with
  control characters (a newline would end sudo's read early) are refused.

### 9.2 `sudo` without `-A`

sudo only uses `SUDO_ASKPASS` with `-A`. With shell integration (`[askpass] sudo = true`, the
default), interactive bash, zsh and fish get a `sudo` function: zsh through our own `ZDOTDIR`
whose `.zshenv` sources Ghostty's, bash through our `ENV` file that sources `ghostty.bash`,
fish through `vendor_conf.d/un-askpass.fish` next to Ghostty's. It runs `sudo -A` only when
`un-askpass --available` says an app could answer now; otherwise, and whenever the arguments
before the command already include `-A`, `-S`/`--stdin` or `-n`, it is plain `sudo`.

Trade-offs: the probe costs a few ms per `sudo`; aliases such as `sudo='sudo -E'` still reach
the function, but one naming sudo by path, or a `sudo` function defined later in the user's
dotfiles, replaces it; scripts,
`env sudo …` and `command sudo` get plain sudo (asked on the terminal, where the detected prompt
below still helps); sudo's credential cache works as usual (no prompt, no helper); `sudo -A`
reads `SUDO_ASKPASS` from the caller's environment, so `env_reset` does not get in the way.
Shells without integration (macOS `/bin/bash`, `sh`) only get the variables.

### 9.3 Detected terminal prompts

Whenever a pane's termios is `-echo icanon` (the S6 hidden-input shape) the daemon checks the
cursor row on each output and termios change: a line ending in `:` that names a password,
passphrase, passcode or PIN (`proto::looks_like_password_prompt`) is pushed as
`AskpassPush::Detected{pane, prompt, at_seq}` and `DetectedGone` when echo comes back or the
line changes (also sent on attach). The app offers "Enter Password Securely"; the answer is
`AskpassRequest::TypeSecret{pane, secret}`, which needs Driver and the pane's lease, and is
written with a Return only if echo is still off at that moment (`NotHidden` otherwise, nothing
written): the secret can never be echoed, land in the shell's history, or run as a command.
Programs that read passwords in raw mode (most TUIs, `pinentry-curses`) are not detected.

### 9.4 Tests

`tests/it/askpass.rs` (fake helper on the hook socket): the prompt reaches two askpass clients
and not a plain one, first answer wins and the other sees `Answered`, a late answer is `Gone`,
retry flag, cancel, control characters refused, yes/no questions; a viewer guest is never told
and is `Denied` while a driver guest answers; timeout, abandoned (helper hangs up), bad token;
no app → `"terminal"` and `--available` false, the app leaving mid-prompt → `"terminal"`
after the grace; a program that turns echo off and prints `Password:` gets `Detected`,
`TypeSecret` reaches it without echo, `NotHidden` at a shell prompt, a client attaching late is
told. `crates/hostd/tests/askpass.rs` runs the real `un-hook`: sudo- and ssh-like scripts that
call `$SUDO_ASKPASS`/`$SSH_ASKPASS` get the app's answer (or fail on Cancel), the terminal
fallback reads with echo off, and interactive zsh's `sudo` becomes `sudo -A` only while an app
can answer (`-S` left alone). Goldens: `proto/tests/golden_askpass.rs`.

## 10. Known gaps / follow-ups

- **Live upgrade**: replacing the daemon binary (over SSH, or the owner's self upgrade, §2 "Version, host name and updating the daemon") ends its PTYs. Shells come back in their last
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
- Multiplayer (§6), not built yet: knock-to-join (owner approves a redemption), approval
  policies (`owner_only`, `two_person`, `claim`), `approve_max_risk`, `history: since_join`
  snapshot trimming, short PAKE codes, guest push registration, per-pane redaction, the
  structured lane for prompters (today prompts are sanitized keystrokes into the TUI), the
  App Clip; the app UI (share sheet, avatars, take-control button, revoke sheet) is the Swift
  side's. Presence `Away` grace periods are not tracked (a leaving device just disappears).
  Grants are checked against the live layout, so a pane-scoped grant dies with its pane.
  Audit records stay in memory up to 10 000 for queries; older ones only on disk.
- Snapshots are encoded in full then truncated at READY (libghostty has no READY-only encode).
  `size` test fails its "typical < 50 KB" assertion there: 148 KB for colored logs); zstd keeps
  the wire size small, but the cause (page layout) needs a look.
  and editor servers live in memory and end with the daemon; worktree setup scripts are not
  run; editors are not idle-stopped; the in-window "open file" path and the URL payload are
  untested against a real browser; no transfer resume by offset for uploads (downloads take an
  offset); `fs.find`/`fs.resolve`, git stage/discard/commit and `log` are not built.
  `.excalidraw` export (import works); kitty capture covers displayed PNGs only (§7.10);
  Excalidraw scenes keep no history (only the current revision exports); live ink is relayed without per-connection
  rate limiting; a session's artifacts are deleted with it; anchors detach on daemon restart;
  the daemon's raster render draws text and images as outlines only.
- Native password prompts (§9): gpg's pinentry is not wired (it is configured in
  `gpg-agent.conf`, not the environment; `pinentry-tty` and `--pinentry-mode loopback` prompts
  are caught as detected prompts, curses pinentry is not); raw-mode password readers are not
  detected; a prompt in a pane of another session than the one attached waits until the app
  attaches there (or times out); the app does not yet badge a tab whose pane has an open prompt.
- `SetSizePolicy` is ignored (`LastInput`, restricted to the lease holder when a pane is
  leased). The ticket's relay URL is the one known at
  mint time; `endpoint.json` is refreshed as iroh's addresses change.
