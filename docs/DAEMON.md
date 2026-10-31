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
  session. Closing a tab's last pane closes the tab; a session outlives its last tab (clients
  attached to it get an empty layout, the host shows its New Terminal row, and Undo or ⇧⌘T can
  reopen into it); only `CloseSession` removes one. A pane whose process exits is closed like
  `ClosePane`. A client whose attached session disappears anyway (`CloseSession` from another
  device or the CLI, an older daemon) sees it missing from `Sessions`, drops its tabs and pending
  ops and attaches anew.
- Pane moves (offered as `DaemonFeatures::PANE_MOVES`; older daemons fail to decode them, so
  clients send them only to daemons that offer it): `BreakPane` moves a pane into a new tab
  right after its own (`TabCreated`; a tab's only pane is `Invalid`), `MovePane` puts a pane
  beside another of the same session on a side, `MergeTab` puts a whole tab's tree beside a pane
  of another tab and closes that tab. Processes keep running; a tab left empty closes.
- Projects (offered as `DaemonFeatures::PROJECTS`): named, coloured groups of tabs that a
  client merges across hosts by project id. Each session stores the definitions its tabs use
  (`Project { id, name, color 0–7, order, updated }`) and each tab's membership (`TabProject {
  tab_id, project, rank }`), persisted in `layout.json`. `PutProject` upserts a definition
  (last writer wins on `updated`; an older one is `Done` with no change), `SetTabProject` puts a
  tab in a project defined in its session (else `Invalid`), moves it by `rank` or ungroups it
  with `None`, `RemoveProject` ungroups every tab of it and drops it. A definition is dropped
  when its last tab leaves, closes or merges away; a broken-out pane's new tab is ungrouped.
  Owner-only (§6.3). Clients with `Caps::PROJECTS` and the owner role get `ServerCtl::Projects`
  (same revision) right after every `LayoutChanged`, cut down to the tabs their scope shows.
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
  and the pixels of the kitty images in view right after it (§7.10),
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
  `hostd pair` (another process) and the daemon (its startup ticket, every pairing attempt)
  both rewrite `pairing.json`, so each read-modify-write holds an exclusive `flock` on
  `pairing.lock`: unlocked, a ticket minted while the daemon wrote its own was lost and refused
  with `InvalidGrant`, and a secret consumed by one pairing could survive another's rewrite.
- A ticket (`proto::Ticket`, `unnamed://pair/<base32>`) carries the daemon id, direct
  addresses, home relay, owner principal, a 128-bit one-time secret and expiry. Dialing by key
  pins the daemon in the TLS handshake.
- `Hello.grant.v = PAIRING` presents the secret; success allowlists the device key (proven by the
  QUIC handshake). Later connections use `v = DEVICE`. `client-core` tries `DEVICE` first, then
  the ticket's secret. Principal ≠ device, input carries the principal and is rejected if it is
  not the connection's (`InputRejected{Role}`). Paired devices are `Owner` on the whole
  daemon; guests join with signed grants (`v = CHAIN`, §6).
- Pairing secrets are compared in constant time, consumed under the lock (one device per
  secret), and expire server-side; a wrong guess rewrites nothing. The daemon prints a
  startup ticket only to a terminal, never into a service log.
- `devices.json` changes go through `devices.lock` and start from the file as it is, so a
  pairing never brings back a device `hostd unpair` just removed. The daemon re-reads the
  file whenever it changed (inode, size, mtime), so `hostd unpair <key prefix>` (a lost phone)
  takes effect on the next check: the 500 ms tick closes the device's connections and those
  of guests whose invites it signed (§6.2). `hostd devices` lists the allowlist.
- A new pairing is announced to the other connected owner devices
  (`ServerCtl::DevicePaired`, `Caps::DEVICE_ALERTS`) once the new device says its name
  (`SetName`, kept in `devices.json`) or after 3 s, so a pairing from a phished ticket is
  seen and can be revoked.
- Removal is recorded with its time (`unpaired.json`, under the `devices.json` lock). A chain
  counts only if its root was signed after the removal of every device in it, so a removed
  device's invites stay void; a fresh ticket pairs the device again, without them.
- Before the `Hello`, a connection is counted against limits overall and per source address
  (IPv6: per /64; `Config::pre_auth`): 1024 / 32 in the QUIC handshake, then 128 / 16 for
  keys the daemon does not trust. Paired owner devices and guests bound to a live grant are
  recognised by their proven key (or the key a relay names) and not counted. Each connection
  has `hello_timeout` (10 s) for the handshake and again for its `Hello`. The daemon never reads 0-RTT data: it awaits the full handshake first. Device keys
  of small order (whose signatures anyone can forge) are refused. A refused peer's
  `DaemonInfo` carries no host name, OS name or build.

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

**Closed panes (recently closed tabs).** When a pane closes (a close op or its process exiting,
not a shutdown) the daemon keeps `{pane_id, cwd, agent{kind, session_id}}` (the agent only while
its session id is known and it had not exited), the last 64, in `layout.json`'s `closed` list
(absent in older files). `PaneLaunch::Reopen { pane_id, cwd }` in `NewTab` or `Split` starts the
closed pane's agent resuming that session (`claude --resume <id>`, `codex resume <id>`, as a
restored agent: idle until seen working), else a shell in its last directory, else in `cwd`; an
unknown pane is a shell in `cwd`. The record is used up, so one session never resumes in two
panes. Offered as `DaemonFeatures::REOPEN`; clients send `Shell { cwd }` to older daemons.
Only the owner may reopen. Tests: `tests/it/reopen.rs` (the last tab keeps its session and a
reopened tab comes back in its directory; an agent resumes its session, also after a restart,
and only once), `mp::policy` unit test.

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
- **Direct-only devices and restarts.** A device with relays off (`un --no-relay`, the app's
  local-only switch) dials only the direct addresses in the ticket it paired with. iroh binds
  random UDP ports, so a restart or upgrade used to move the daemon away from every such
  ticket (`un --no-relay forward` then timed out "waiting for layout"; with relays, address
  lookup hid it). The daemon now records the sockets it bound (`endpoint.json` `bound`) and
  binds the same ports on the next start (the default binds and `--bind` with port 0; a port
  taken in the meantime falls back to a fresh one, which a direct-only device only learns
  from a new ticket). `un` reports a daemon it never reached as such, with the last dial
  error, instead of "timed out waiting for layout", and `un forward` no longer attaches.
  Test: `a_direct_only_ticket_still_reaches_the_daemon_after_a_restart`.
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
as the link itself, while reads and writes follow it and check the target too. The daemon's
state dir (keys, tokens, grants, audit log) is refused even inside a root, and written files
never get setuid/setgid/sticky bits from a client. Optional
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
compress = true                  # brotli/gzip proxy in front of the editor server (§5.3)
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
after the client's `shutdown(Write)`), a reset maps to a stream reset. A failure midway (the
link died, either side reset) ends both directions at once and resets both ends: the local TCP
peer and the host's server see a reset (`SO_LINGER 0`), never an orderly close, so a browser's
websocket takes it for a lost link and reconnects. Forwards survive reconnects: a new connection
waits for the link, and one that met a connection already dead (closed before the client noticed)
gets one more try on the next live one within 20 s, before any byte flowed. The device's
listener is bound again on the same port when the client resumes from `suspend` (iOS defuncts a
suspended app's sockets) and whenever accepting fails. `stop_forward` closes the listener. 64
concurrent connections through one forward are tested;
`forwards_wait_out_a_reconnect_and_reset_on_a_broken_link` covers the wait and the resets.

`Client::network_changed` (the device's network changed) keeps a live connection, telling iroh
to look for paths again (it moves the connection onto one that works, relay or direct, without
closing it, so forwarded websockets survive); only a client without a live connection redials.

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

### 5.3 Editor (Microsoft's VS Code server over our forward by default; VS Code tunnel opt-in; VSCodium as automatic fallback; openvscode-server explicit only)

on the host — the server `code serve-web` runs, run directly (`ws/vscode_server.rs`) — reached
over our direct iroh port forward** (`EditorLaunch` below; apple-ffi
`DaemonClient::open_editor`). No Microsoft relay, no tunnel quota, and **never a GitHub or Microsoft
sign-in**. The app shows Microsoft's licence terms (VS Code licence, VS Code Server licence, Microsoft
Privacy Statement) once per host in a first-use sheet and passes `accept_vscode_license` only after the
user taps Accept there; Cancel starts and installs nothing.

- **Mac:** "Open in VS Code" opens the user's own **desktop VS Code with Remote-SSH over our
  forward** (`vscode://vscode-remote/ssh-remote+<hex-JSON authority>/<path>[:L[:C]]` to
  `127.0.0.1:<stable per-host port>` forwarded to the host's `127.0.0.1:22`; see "Desktop Remote-SSH"
  below). It needs no licence sheet from us (desktop VS Code and Remote-SSH have their own terms). When
  VS Code is not installed, or the host has no sshd answering, the app opens the in-app editor instead.
- **Fallback, opt-in: the VS Code Remote Tunnel** (`ws/tunnel.rs`, research
  palette). The daemon runs Microsoft's `code tunnel` on the host. The user signs in with their own
  GitHub or Microsoft account by device code, which the app shows (code, Copy, open the verification
  page in the user's browser) and never completes itself. The app opens
  `https://vscode.dev/tunnel/<name>/<folder>` top-level in a `WKWebView` (vscode.dev refuses framing)
  that opens popups (sign-in, Settings Sync) as sheets keeping `window.opener`; on the Mac the tunnel's
  `vscode://vscode-remote/tunnel+<name>/<path>:L:C` opens desktop VS Code.

The tunnel RPCs:

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

- **Why the server runs directly.** serve-web stops its server an hour after the last
  connection closed, sends new connections to a newer server as soon as Microsoft ships one, and
  keeps the server's default reconnection grace (3 h, 5 min once another client came). Each of
  these ends every open workbench's session ("Cannot reconnect", reload). Run directly, the server
  gets `--reconnection-grace-time 172800` (48 h: a sleeping iPad comes back to its session) and
  lives until `EditorStop`, daemon shutdown, or 48 h without any connection through its proxy
  (`EditorProxy::idle_for`; checked whenever editors are listed, launched or opened).
  - Download: `/api/update/server-<linux-x64|linux-arm64|linux-armhf|linux-alpine|alpine-arm64|
    darwin|darwin-arm64>-web/stable/latest` on Microsoft's update service gives `url` and
    `sha256hash`; curl, else wget; the SHA-256 is checked; unpacked to
    `<state>/vscode/server/<commit>/` (`latest` names the newest). The service is asked at most
    hourly, when a server starts; offline, the newest one here is used. The one before stays (it
    may still run); older ones are removed.
  - Launch: `bin/code-server --host 127.0.0.1 --port <free> --connection-token-file <file holding a random 128-bit token>
    --accept-server-license-terms --reconnection-grace-time 172800` in the folder. Server data in
    `~/.vscode-server`, as under serve-web (extensions and settings carry over).
  - Licence: the same acceptance serve-web needs (the Server licence, accepted in the app); the
    same Microsoft download serve-web makes. Nothing is fetched without it.
  - Fallback: when Microsoft publishes no server for the host or the download fails with none
    here, `code serve-web` as before. `editor.serve_web = true` forces serve-web (tests with a
    stand-in `code`).
  - Run for real on macOS arm64 (2026-10-22, VS Code 1.143.0: CLI and server download, launch and
    workbench through the forward in 34 s on first open, 1.5–2.2 s per warm load in WebKit); the
    Linux builds go through the same code but were not run yet.
- `EditorLaunch{folder, choice: Auto|Only(kind), accept_vscode_license}`. Auto runs
  VS Code (the server directly, else `code serve-web`; the user's CLI or the managed one must be
  there) only with the licence accepted. One server per folder, reused
  (the app's editor panes, several at once, are one server each, each behind its own compressing proxy sharing one
  asset cache; why not one server per host: APP-ARCHITECTURE §20 "Daemon"); bound to `127.0.0.1` on a
  free port with a random 128-bit token read from a 0600 file (`--connection-token-file`, never
  argv: other users can read the process list); own process group, killed on
  `EditorStop` and daemon shutdown; logs in `<state>/editors/`. Returns port, token and
  `url_path` (`/?tkn=…&folder=…`; the server answers with the token cookie and a redirect).
  The returned port is the **compressing proxy's** (below), not the server's; the app forwards
  whatever port it gets, so nothing changed there.
- **Compression (`ws/editor_proxy.rs`).** The VS Code server sends everything uncompressed
  HTTP/1.1 reverse proxy (hyper) on another loopback port; it is what `EditorInstance.port`
  names and what the forward reaches. Generic port forwards are untouched.
  - Honours `Accept-Encoding` with q-values, brotli preferred, then gzip. Compresses `text/*`,
    JavaScript, JSON (source maps), `+json`/`+xml`, SVG, wasm, ttf/otf and icons, status 200
    only. Streams: output goes out as the compressor produces it, and is flushed when the
    server pauses for 20 ms (flushing on every read costs brotli ~20 % of its gain).
  - Leaves alone: websocket upgrades (spliced both ways), `Range` requests and `206`s, bodies
    already encoded, bodies under 1 KiB, images and woff/woff2, `Cache-Control: no-transform`.
    `HEAD` answers with the headers `GET` would have (encoding, no length).
  - A strong `ETag` on a transformed body becomes weak and marked (`"x"` → `W/"x;unz"`); the
    mark comes off again in `If-None-Match`, so the server's own comparison still answers 304
    (the 304 carries the weak tag). The server's weak tags pass unchanged. `Vary:
    Accept-Encoding` on everything compressible.
  - **Asset cache.** Versioned static assets (`/<quality>-<40 hex commit>/static/…` with a
    `max-age` of at least a day and no `Set-Cookie`, i.e. VS Code's one-year assets) are kept
    per server version in `<state>/editors/cache/<quality>-<commit>/<sha256 of path>.{br,gz}`
    (3 versions; older ones are removed when a new one appears). The first load streams
    brotli at level 5 (≈50 MB/s on one core) and stores it; a background job then rewrites
    it once at level 11 (workbench.js: 4.6 → 3.9 MB, ~20 s of one core per server version,
    one job at a time, stopped at shutdown and resumed on the next hit). Later loads are
    served from the file with a `Content-Length`. The server is still asked every time — it
    checks the connection token and says what the asset is — only its body is not read.
  - `editor.compress = false` hands out the server's own port instead.
  - Measured 2026-10-21 (pinned VSCodium Web Host — the same server code as serve-web, which
    is not installed on the Mac — over iroh, `--no-relay`, Playwright 1.64.1, release build,

    | Chromium, cold load to editor | bytes | workbench | editor |
    |---|---|---|---|
    | loopback, off | 23.3 MB | 1.5–2.0 s | 3.1–3.9 s |
    | loopback, on (cached) | 4.4 MB | 1.7 s | 3.1 s |
    | same, on, first load ever (q5 streamed) | 6.1 MB | 1.6 s | 3.9 s |
    | same, on, cached (q11) | 4.3 MB | 1.5–1.7 s | 3.3–4.2 s |
    | 2 MB/s + 80 ms (cellular-like), off | 22.6 MB | 13.0 s | 21.0–22.8 s |
    | same, on, cached | 4.3 MB | 3.3 s | 11.1 s |

    **WebKit offers only `gzip, deflate` to an `http://` origin** (checked: Playwright WebKit
    on `127.0.0.1` and `localhost`; Chromium offers `br, zstd` too), and WKWebView loads the
    editor from `http://localhost:<port>`, so the app gets gzip: 23.3 → 5.8 MB (loopback
    WebKit, editor 2.1–2.5 s vs 2.2–3.2 s off). Getting brotli into WKWebView would need the
    client side of the forward to ask for it and decode locally (not built).
  - Tests: unit tests (negotiation, what is compressed, immutability, ETag round trip, cache
    keys, rewrite, pruning, shutdown) and HTTP tests over sockets in
    `ws/editor_proxy/http_tests.rs` (chunked bodies, bytes arriving before the server
    finishes, cache hits with the server still asked, ranges/encoded/tiny/binary untouched,
    HEAD, ETag → 304, websocket passthrough, keep-alive); end to end through the iroh forward
    with a fake server: `editor_traffic_is_compressed_through_the_forward` (token still
    enforced, cache, websocket, `compress = false`).
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
- `bin/codium-server --host 127.0.0.1 --port <free> --connection-token-file <file holding a random 128-bit token>
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
    consulted): the user runs Microsoft's server on their own machine for their own use, with
    the terms accepted by the user in the app. The tunnel (Microsoft's own client and relay)
    stays available as the opt-in fallback, and on the Mac desktop VS Code with Remote-SSH is
    Microsoft's own client end to end.
  - The Remote FAQ's "cannot build a public or commercial service on top of … VS Code Server"
  - openvscode-server (MIT, Open VSX extensions only; the Microsoft Marketplace terms forbid
    non-Microsoft products from using it) is an explicit fallback only.

### 5.4 Git, diffs, agent turns, review notes

- Git CLI only, `LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`, `core.quotePath=false`. Status from
  `status --porcelain=v2 --branch -z` (branch, oid, upstream, ahead/behind, staged/unstaged per
  path, renames with their old path, unmerged, untracked).
- A `.git` can come from anywhere (an unpacked archive), so its own config never runs a program
  when the daemon looks: every call gets `core.fsmonitor=false`, `gc.auto=0`,
  `maintenance.auto=false`, a pager and editor that do nothing, hooks off (`core.hooksPath=
  /dev/null`, except `push`, which the person asked for), and the clean/smudge/process filters
  the repository's local config defines emptied (Git LFS's own excepted); porcelain diffs pass
  `--no-ext-diff --no-textconv`. `gh` gets fsmonitor and hooks off through `GIT_CONFIG_*`. The
  throwaway index lives in a fresh 0700 temporary directory.
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

The `Repos` push (§5.12) does not carry the port: `WorktreeState` is frozen on the wire. The app
reads ports with `WorktreeList` whenever a repository's set of worktrees changes
(`DaemonWorkspace.worktreePorts`, matched by path, else by branch) and takes the port that
`TaskCreate`, `WorktreeRestore` and `PrCheckout` return at once. Only worktrees the daemon made or
registered have one; the main checkout has none.

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
to owner connections that watch: `WorkspaceRequest::UsageWatch` answers with the
report at once, then `ServerCtl::AgentUsage` pushes changes (clients with `Caps::AGENT_USAGE`);
`UsageUnwatch` stops. Offered as `DaemonFeatures::AGENT_USAGE`.

Sources, preferred first: Codex's `token_count` rate limits in its rollouts; Claude's status-line
input (Claude panes launched by the daemon run `un-hook claude StatusLine` as their status line,
which forwards the JSON as hook event `StatusLine` and then runs the user's own status line);
when those are missing or older than 10 min, `claude -p /usage --output-format stream-json`
(+ `claude auth status --json` for the plan) and `codex app-server` → `account/rateLimits/read`,
in the background, at most every 5 min per agent. The daemon never reads the tools' sign-ins or
calls the providers' undocumented usage endpoints: that is closest to what Anthropic's and
OpenAI's terms forbid. `UsageWatch::api_fallback` and `UsageSource::Api` stay on the wire for
compatibility; clients send `false`, the daemon ignores the flag and never reports `Api`. The
report refreshes at most once a minute and only
while a connection watches; the last status-line snapshot survives restarts
(`<state>/usage/claude-status-line.json`). Tools are found through the panes' `PATH` (plus
`~/.local/bin`), `CODEX_HOME` and `CLAUDE_CONFIG_DIR`. Tests: `cargo test -p daemon --test it usage`
(fixture rollouts, status-line hook, fake `claude` / `codex`; a client that still sends
`api_fallback` gets no sign-in-based answer).
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
- **Trust** (`ws/trust.rs`, `DaemonFeatures::REPO_TRUST`): setup and teardown run only when
  the owner trusts exactly them, kept per repository (main worktree) and SHA-256 of both in
  `<state>/repo-trust.json`; otherwise the task, archive, delete or auto-delete goes ahead
  without them (`TaskCreated.setup` is `None`). `RepoHooks(NewTask{repo, base} |
  Worktree{path})` → `RepoHooks{repo, hooks, hash, trusted}` reads what would run (a new task:
  the file committed at `base`, else the main worktree's); `RepoTrust{repo, hash}` (owner
  devices only, never a guest's grant) trusts it. The app asks "Run Setup Commands for repo?"
  before a task and "Run Teardown Commands…" before archive or delete.
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

### 5.13 Workflows (`proto::workflow`)

format). Code: `crates/daemon/src/ws/workflows.rs`; wire types and the template functions in
`crates/proto/src/workflow.rs`.

- **Where**: `~/.config/unnamed/workflows/*.yaml|*.yml` (`$XDG_CONFIG_HOME/unnamed/workflows` when
  set; global, every pane) and `<repository>/.unnamed/workflows/` (the repository a pane's
  directory is in: the nearest ancestor with `.git`; a linked worktree without its own directory
  falls back to the main worktree's, found through `.git` → `gitdir` → `commondir`). Hidden
  files are skipped; symlinked files are followed.
  `{{arg}}`), `description`, `tags`, `arguments: [{name, description, default_value}]`,
  `shells`, `author`, `source_url` (`author_url` and any other field are ignored). Ours on top:
  `shell` (one shell) and `raw: true` on an argument. A file holds one workflow or a list
  (`id` is the path, `#n` for list entries). A missing `name` takes the file's stem; scalars may
  be numbers (`default_value: 8080`); placeholders the file does not list become arguments.
  Names are `[A-Za-z_][A-Za-z0-9_-]*`; anything else between braces (`{{.State.Status}}`) stays
  literal.
- **Safety**: only parsed, never run (serde-saphyr: no tags, `reject_unsupported_tags`). Limits:
  256 files per directory, 64 KiB per file, a YAML budget (64 aliases and anchors, depth 16,
  20 000 nodes, 4 documents), 32 arguments, 16 KiB commands, 200-character names. A bad file is
  reported in `problems` with a one-line message and no source snippet (a symlink to some other
  file does not leak it).
- **Offered** as `DaemonFeatures::WORKFLOWS`; clients ask only daemons that offer it.
- **Requests** (`WorkspaceRequest`, `Caps::WORKFLOWS`): `WorkflowList{pane_id?}` →
  `Workflows(WorkflowList{rev, repo?, repo_name?, workflows, problems})`: the repository's (by
  name), then the global ones (by name); without a pane only the global ones. Drive on the pane
  (Drive on the host without one). `WorkflowSave{scope, pane_id?, workflow: WorkflowDraft}` →
  `WorkflowSaved(Workflow)`: writes `<slug>.yaml` (`-2`… if taken, `O_EXCL`, never replacing a
  file) in the global directory or the pane's repository's (created if missing; `NotFound` when
  the pane is not in one), validated by reading it back. Drive on the host.
- **Freshness and pushes**: a directory is re-read when its files' names, sizes or mtimes
  changed, so a list is never stale. Every directory listed is watched (non-recursive `notify`;
  while it does not exist, its parent or grandparent, re-armed as directories appear; at most 64,
  least recently listed dropped), debounced 150 ms; a change in it or on the way to it bumps
  `rev` and pushes `ServerCtl::WorkflowsChanged{rev}` to clients with `Caps::WORKFLOWS` (the
  client core always announces it), which list again. A save pushes at once.
- **Filling in** (`proto::render`, exported to Swift as `workflowRender`): each placeholder
  takes the typed value, else the default, else empty, shell-quoted for where it sits in the
  command: unquoted → one POSIX word (`'…'` with `'\''`, safe words as is, empty `''`); inside
  `'…'` → `'\''` for each quote; inside `"…"` → `\`, `"`, `$` and `` ` `` escaped. `raw`
  arguments go in as typed. The app types the result into the pane as a bracketed paste and
  never presses Return unless asked (⌘↩).
- **Tests**: `cargo test -p proto` (placeholders, quoting in each context, defaults, raw);
  billion-laughs file refused with short messages, YAML round trip of drafts with quotes,
  control characters and multi-line commands, slugs, repository and linked-worktree discovery,
  directory limits, XDG); `cargo test -p daemon --test it workflows` (a pane in a repository vs
  outside, an edited file and a new global file pushing `WorkflowsChanged`, the workflow
  directory created after the first list, saving twice → `-2`, global save, refusals). Goldens:
  `crates/proto/tests/golden_workflow.rs`. App: `apple/scripts/workflows-ui-test.sh`.

### 5.14 Agent install checks

- `WorkspaceRequest::AgentInstalls` → `AgentInstalls([AgentInstall{agent, program, state}])`,
  offered as `DaemonFeatures::AGENT_INSTALLS` (clients ask only daemons that offer it). Drive on
  the host.
- Each agent's command is looked up on the `PATH` of the user's login shell (`$SHELL -l -c`,
  with the panes' environment), which every agent pane is launched through: `Installed{path}`.
  Else in the vendors' installer directories (`~/.local/bin`, `~/.claude/local`): `NotOnPath{path}`
  (launching would fail with "command not found"). Else `Missing`. A shell that does not answer
  within 10 s falls back to the daemon's own `PATH`. Asked fresh on every request.
- The app (New Agent) shows a missing agent with its vendor's official installer for the host's
  `DaemonInfo.os`, to copy or run in a new tab (`ScriptRun`), and the vendor's guide; Start is
  off until it is installed. Code: `crates/daemon/src/ws/installs.rs`,
  `apple/App/Sources/Git/AgentInstallGuide.swift`.
- `WorkspaceRequest::AgentMcpCommands{register}` → `AgentMcpCommands([AgentMcpCommand{agent,
  argv}])`, offered as `DaemonFeatures::AGENT_MCP`. Owner only. One command per installed agent
  (named by path when off the login `PATH`): `claude mcp add --scope user unnamed_drawings --
  <un-hook> mcp --state <state>` and `codex mcp add unnamed_drawings -- …`, or with `register`
  false `claude mcp remove --scope user …` / `codex mcp remove …`. Nothing runs on the daemon:
  the app (Settings ▸ Agents ▸ Agent Tools, off by default) shows them and runs them in a new tab
  (`ScriptRun`), so agents the user starts by hand get the §7.12 server; its pane comes from
  the pane's `UN_PANE_ID`. Goldens: `crates/proto/tests/golden_agent_mcp.rs`.
- Tests: `cargo test -p daemon --lib installs`, `cargo test -p daemon --test it installs`,
  goldens in `crates/proto/tests/golden_installs.rs`; app: `AgentInstallGuideTests`,
  `W3UITests.testAgentNotInstalledOffersTheOfficialInstaller` (`apple/scripts/w3-ui-test.sh`).


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
- State: `<state>/grants.json` (registered chains with their bound devices, revoked grants,
  guest removal times, guest devices). `RegisterGrant` (owner, or the grant's own issuer) records a chain
  before first use so it can be listed and revoked.

### 6.2 Live checks and revocation

- Every inbound ctl message and every input frame first re-checks the connection's grant
  against the live table: expiry, any link revoked, device revoked, any signer revoked, and
  the chain's root still trusted (the daemon or a paired owner device); for an owner device,
  that it is still paired (`Mp::still_valid`). Failure sends `ServerCtl::Revoked` and closes
  the connection 150 ms later. A 500 ms tick also disconnects connections that stopped
  passing without traffic, so revoking or unpairing an owner device also closes the guests
  it invited.
- `grants.json` that cannot be read is moved aside (`grants.json.unreadable-<ms>`), and the
  daemon starts with every chain signed until then void (`void_before`): owner devices keep
  working, guests' old invites are refused, new invites work. Owner devices are told with
  `ServerCtl::HostAlert` (`Caps::HOST_ALERTS`) on every connection, plus the log and audit.
- Signatures (grants, approvals) are verified strictly (`ed25519-dalek` `verify_strict`):
  small-order keys and non-canonical points are refused.
- `Revoke(Grant | Device | Principal)` (owner, daemon scope) records the revocation, unpairs a
  revoked owner device, closes every affected connection at once (descendant grants are
  covered because every link id is checked), and answers with what it hit. A device cannot
  revoke itself. Re-dials are refused (`RefuseReason::Revoked`) until an owner device pairs
  again with a fresh ticket, or a guest joins with an invite whose root is newer than the
  revocation.
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
| `Op`: `Split`, `BreakPane`, `MovePane`, `MergeTab` | driver | the (target) pane's whole session in scope |
| `Op`: `NewTab`, `RenameSession` | driver | session in scope |
| `Op`: `ClosePane`, `CloseTab`, `CloseSession` | **owner** | in scope |
| `Op`: `SetTabProject` | **owner** | tab in scope |
| `Op`: `PutProject`, `RemoveProject` | **owner** | session in scope |
| `Op`: `CreateSession`; `Attach` that would create a session | **owner** | daemon |
| `Workspace`: `ListPorts`, `AttentionList`, `AttentionSeen` | any role | answers filtered to scope |
| `Workspace`: `ListTurns`, `TurnDiff` | prompter, driver or approver | pane in scope |
| `Workspace`: `SendReview` | prompter, driver or approver (non-drivers: agent panes only) | pane in scope |
| `Workspace`: git, `Fs*` (read, write, watch), worktrees, `EditorStatus`, `EditorOpen`, `VsCodeTunnelStatus`, `VsCodeTunnelOpen` | driver | host |
| `Workspace`: `WorktreeLaunch` | driver | the pane's session |
| `Workspace`: `EditorLaunch`, `EditorStop`, `VsCodeCliInstall`, `VsCodeTunnelStart`, `VsCodeTunnelStop` | **owner** | daemon |
| Streams: `PortForward`, `Forward`, `Upload`, `Download` | driver | host |
| `RegisterGrant` | owner, or the chain's leaf issuer | — |
| `ListGrants`, `InviteLink`, `ListDevices`, `Revoke`, `Audit` | **owner** | daemon |
| `Artifact`: `List`, `Get`, `Export`; blob download | any role | artifact visible (below) |
| `Artifact`: `Create`, `Apply`, `Delete`, `SetAnchor`, `SetPreview`; `InkLive`; blob upload | **prompter or driver** | artifact visible; anchor pane / session in scope |
| `Artifact`: `Send` (to agent) | **prompter or driver**; **agent pane only** | pane in scope |
| `Op` `Split`/`NewTab` with `PaneLaunch::Canvas` | driver (as any split) | session of the pane |
| `Op` `Split`/`NewTab` with `PaneLaunch::Reopen` | **owner** (it can resume the owner's agent session) | session / session of the pane |
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

Clients that announce it send `ClientCtl::Peer(PeerUpdate)`: device class, `State` (away in
the background), `Viewport` (rows from the bottom of the focused pane), `Draft` (the line
editor's or composer's text and caret, `None` once sent or discarded), `Follow(principal)` and
a `Heartbeat` every 10 s. The daemon answers with `ServerCtl::Peers`: `PeerPush::All` (every
connection, the recipient's own id) on joining and whenever someone joins, leaves, renames or
changes focus, then `PeerPush::Changed(peer)` per change. Rules:

- *Ephemeral.* Drafts and viewports live in the connection's state only: never in scrollback,
  history, search or the audit log; gone when the connection is.
- *Roles and scope.* A draft needs the prompter, driver or approver role on its pane (else
  `Forbidden{what: "Draft"}`); a viewport must be in scope. Focus, viewport, typing and draft
  in panes outside the recipient's grant are withheld.
- *Typing.* Raw input to a pane and draft changes mark the sender typing there for
  `PresenceTimes::typing` (3 s); only transitions are broadcast. Clients without the cap hear
  draft typing as the old `Presence.typing`.
- *Ordering.* Every change takes the next daemon-wide revision; clients keep the newest per
  peer (last write wins). Each connection's `ctl` writer keeps only the newest state per peer
  while a write is pending (`mp::Mailbox`), so a slow guest catches up instead of replaying.
  Clients send the first change at once and then at most every 33 ms.
- *Liveness.* Idle after 2 min without input, focus, viewport or draft; away when the client
  says so or a presence client is silent for 25 s; dropped after 60 s of silence (no ghosts).
  A reconnecting client gets `All` again and re-sends its own state, draft included.
- *Following* is by principal: the follower tracks that person's most recently active device
  (its focus and viewport); the leader sees `following` on the follower.

`un draft <text> [--cps N] [--then-focus PANE]` types a live draft (UI tests use it).

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


Clients and daemons find each other through `Caps::KNOCK`, `Caps::APPROVAL_POLICY` and
`DaemonFeatures::MP2`. Code: `crates/daemon/src/mp/approvals.rs`, `mp/mod.rs` (knocks, terms),
`pane.rs` (views), `crates/client-core/src/knock.rs`, `crates/apple-ffi/src/mp2.rs`. Tests:
`cargo test -p daemon --test it multiplayer_mp2`, `proto --test golden_mp2`, the decision
table in `mp/approvals.rs`, `ghostty-vt --test it forget`.

**Invite terms.** `MpRequest::RegisterInvite{chain, terms}` records `InviteTerms{knock,
history}` with the grant in `grants.json`. They are not in the signed grant: the daemon looks
them up for every link of a presented chain and applies the strictest, so a delegated child
can add terms but never drop its parent's, and a guest cannot strip them from a link. A copy
rides after the invite's bytes (`Invite::to_string_with_terms`, marker `0xE9`; old parsers
ignore it) only so the join card can say "asks first" and "earlier output hidden". `un invite
--knock --history since-join`.

**Knock to join.** A chain whose terms say `knock` does not join. With `Caps::KNOCK` the
connection waits in a lobby: no `Welcome`, nothing visible; it hears
`ServerCtl::KnockAnswer(Waiting{knock_id})` and may only `Ping`, `SetName` and `Bye` (it pings
every 10 s; 45 s of silence ends it). Without the cap the grant is refused as invalid, so old
apps never get in. Knocks bind and use up nothing; at most 8 wait per invite; the same device
knocking again replaces its knock. Owner devices with the cap get `ServerCtl::Knock(Added |
Gone)` (and every pending knock right after `Joined`). `MpRequest::AnswerKnock{knock_id,
admit}` (owner, daemon scope): `Admit{roles, history, expires}` mints a new root grant signed
by the daemon key, on the invite's scope, bound to the knocking device, single use, expiring
`KnockAnswer::Admitted(chain)` and reconnects with it (`knock::knock` returns the invite to
join with). `None` sends `Denied`. Revoking or expiring the knock invite turns its waiting
knockers away. Audited: `Knock`, `KnockAnswered` (admitted as …, turned away, stopped
waiting). `un knocks [--watch]`, `un admit N --role driver`, `un deny N`, `un join` knocks.

(`MpRequest::SetApprovalPolicy`, `un policy --mode two-person --max-risk edits`), everyone in
the session hears `ServerCtl::ApprovalPolicy` on attach and on change. Enforced where
decisions are signed, before the agent is answered: `Decide`, push actions and on-screen
dialog answers (`AnswerBlocked`).

| Mode | Rule |
|---|---|
| `AnyApprover` (default) | first valid decision wins |
| `OwnerOnly` | only paired owner devices decide |
| `TwoPerson` | allowing a `Risk::Any` call needs two different principals; the first approval is held (audited with its signature, "1 of 2"), one "no" ends it |
| `Claim` | `MpRequest::Claim{request_id}` reserves a request: only the claimer (or an owner) answers it; claiming withdraws its attention item (notifications) |

`max_risk` caps what non-owners may allow (`Risk::of_tool`: reads, edits, anything else);
denying is never capped. On-screen answers carry no request id or tool, so non-owners may use
them only under `AnyApprover`/`Claim` without a risk cap. `ServerCtl::ApprovalStatus` (risk,
mode, held approvals, claim) goes to clients in scope when a request opens and on every vote or
claim. Refusals name the rule and are audited as `Denied`; claims and policy changes as
`Claim` and `Policy`.

that existed when its device first redeemed the grant, only what was written afterwards: the
daemon keeps a *view* per guest principal and pane, a copy of the terminal made from the
snapshot's READY section with all history erased (`Terminal::forget_history`, both screens),
fed the same output and resizes under the pane's lock. Its snapshots, history pages, search,
links and command list (commands that started later, rows shifted) are served instead of the
pane's; a resume point before the view's start falls back to a snapshot, so the ring never
replays earlier bytes. The screen at the moment of joining stays visible: it is the live
session they join. Views open at join, or on first use after a daemon restart (which only
hides more), and are dropped once the principal's access ends. Panes created later are shown
whole. Not covered: inline images anchored in earlier rows and agent turn transcripts.

### 6.10 Approval extras: edited approvals and auto-approve rules (`proto::approve`)

Clients that announce `Caps::APPROVALS` get `ServerCtl::Approval` pushes and may send
`ClientCtl::Approval` (answered by `ServerCtl::ApprovalResult`). Every request needs Approver on
the pane; pushes go to connections whose scope covers the pane.

- **What may be done with a request.** When a hook holds a `PermissionRequest` open, the daemon
  pushes `ApprovalPush::Request`: the wire request id, the tool, `input` (the command, only when
  the agent takes edited input: Claude Code's `Bash`) and `like` (the rule "approve all like
  this" would add). The client keeps the latest per pane; it is current only while the pane's
  `AgentState::Blocked` names the same request id.
- **Edited approval.** `ApproveEdited { decide, input }`: a signed `Decide` for the allow option
  plus the new command. The hook answers `{"behavior":"allow","updatedInput":{…, "command":
  input}}` (the rest of the tool input kept). Refused with `NotEditable` for other tools and
  agents, `Invalid` for another option or an empty command. The audit record keeps both commands.
- **Auto-approve rules** (`AddRule`, `RevokeRule`; `crates/grants` `auto_approve`). A rule is
  signed by its device over `auto_approve_signing_bytes` (bound to the daemon) and names one pane,
  one tool and, for shell tools, a command prefix: the program, plus the subcommand for programs
  that have one (`cargo test`, `git status`). A shell rule never matches a command that chains,
  pipes, redirects, backgrounds, substitutes or expands (`; & | > < \` $ ( ) { } \\`, newline),
  never covers `sudo`/`env`/shells, and never has an empty prefix. Limits: expiry ≤ 8 h, 1–50
  agent turns (the turn it was added in counts). It ends when it expires, when its turns are used
  (counted on `TurnStarted`), when the agent session ends, starts again or changes id (including
  `/clear` and compaction: the user approves again), when the pane closes, when it is revoked,
  and on a daemon restart (rules are memory only). While a rule lives, a hook-held request it
  covers is answered at once with "allow once", as the rule's author; the audit record names the
  rule and carries its signature. `AddRule` with `request_id` also answers that open request.
  The rules in force are pushed whole per pane (`ApprovalPush::Rules`: uses, turns used, who
  granted it) after every change and to every new connection.
- **Tests:** `crates/grants` unit + property tests (matching, scope, signature, caps);
  `tests/it/approvals.rs` (edited approval and its audit, `NotEditable`; a rule answers the open
  request and the next one like it, not another command or a compound one, audited with the
  rule's signature, then revoked; turn limit, session end, expiry, too-wide and too-long rules;
  a viewer can neither add nor revoke); goldens in `proto/tests/golden_approve.rs`.


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
an edit, a dropped `.excalidraw` file and photo imported and placed,
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

### 7.10 Inline placements ("never leave the terminal") and kitty graphics

A **placement** shows an artifact inside a terminal pane: a `cols × rows` cell box at column
`col` of an anchored row, drawn by clients over the cells in the "above text" layer, scrolling
with the output (the anchor is a tracked pin, §7.3). The daemon owns placement state:
placements are sent on every `Attach` (resume, reattach, a new device) and as
`ArtifactEvent::Placed` / `Unplaced`, and persisted in `index.bin` (detached after a restart).
Two ways in:

- **Place** (`PlaceRequest{pane, artifact, version, anchor | cursor row, col, cols, rows,
  png, replace}`): the overlay's "done". `png` is the device's render, else the image, the
  preview or the daemon's render; sizes default from the image (pane cell pixels if known,
  else 2× renders of 9 × 18 pt cells) clamped to the pane's width; `replace` swaps the
  placement the overlay was re-opened from.
- **Import** (`ImportRequest{pane, name, data | blob}`): a pasted or dropped image or
  `.excalidraw` file becomes an artifact placed at the cursor row.

**Kitty graphics** (`kitten icat`, yazi and ranger previews, chafa/timg, matplotlib's kitty
backend, `un draw show`, agents printing screenshots) are not placements: Ghostty implements
the protocol. The daemon's VT and every client's VT keep the images (64 MiB per pane and
screen by default, `[terminal] image_storage_mb`; clients keep the same default, so a host
set higher may see a client evict an image it still shows). Everything the protocol has
works: direct and chunked transmission, PNG (decoded with the `png` crate on the daemon,
ImageIO on Apple) and raw RGB/RGBA/gray, transmit then place, placement ids, source rects,
cell offsets, `c`/`r` scaling, z layers, relative placements, Unicode placeholders,
animation and deletion. Query replies (`a=q`, and the `OK`/errors of transmissions without
`q=2`) come from the daemon's VT through its reply sink like other VT replies; a client's
mirror never answers (`Terminal.answersQueries`), or the program would read each reply
twice. The file, temporary-file and shared-memory mediums stay off (Ghostty's default):
clients mirror the byte stream and cannot read the host's files, so programs fall back to
sending pixels inline, as `icat` does after its probe fails.

Every VT of a pane must lay images out alike, or an image moves the cursor by a different
number of rows on one of them. So all use the pane's cell size from its `PaneSize`
(`width_px / cols`, `height_px / rows`): a client that sends no pixel size gets 10 × 20 px
cells, which the daemon writes into the size it records, reports to the program
(`TIOCSWINSZ`) and sends in `Resized`. The app's VT uses that cell size and the renderer
scales placements to its own cells.

Snapshots carry the images: the bytes sent to a client are the READY prefix plus the pixel
records of the images in view, which the encoder writes right after READY
(`ghostty_vt::screen_len`), so a resumed or new client shows them at once. Images further
back arrive with the history pages they were placed on, and the rest after the last page; a
restored image is drawn only once its pixels are there (the render state leaves pending
images out), at its final size.

The app draws placements from the render state's image list (`RenderState.imagePlacements`)
in Ghostty's three layers, lowest z first, clipped to the grid, with a texture per image and
generation, kept only for images on screen and scaled down beyond 4096 px. Animations tick
with each frame and wake the renderer when the next frame is due, so nothing runs while none
plays.

Tests: `tests/it/kitty.rs` (a query answered once; a PNG with `a=T` sized from the default
cells; `a=t` then `a=p` twice with raw RGBA; a chunked transfer; `a=d,d=I`; a second client
and a reconnecting one restoring the images with their pixels from the snapshot),
`ghostty_vt` `history::tests::image_pixels_arrive_after_ready`; TerminalKit
`KittyGraphicsTests` (placement position, offsets, source rect, layer; a negative row after
scrolling; deletion; pending pixels after a restore; replies left to the host) and
`KittyImageTests` (pixels on screen, layers against cell backgrounds, host cells scaled to
the renderer's, a restored image appearing with its pixels, animation frames); the Mac
`MacSnapshotTests.testKittyImageInAPane` fixture.

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

The server finds the socket in `<state>/hook.endpoint` (re-read per call). Its token is the
pane's own `UN_TOKEN` (from its environment, or the agent's when Codex trimmed it) when that
environment's `UN_PANE_ID` is the pane asked for; only otherwise `<state>/hook.token`; never
argv. Without `--state` it uses `UN_ENDPOINT_FILE`/`UN_SOCK` and `UN_TOKEN`, else the default
state dir; without `--pane`, `UN_PANE_ID`.

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
- **Who sees it.** Owner devices that announced `Caps::ASKPASS` (the app; `client-core` with
  `ConnectOptions::askpass`) and are attached to the pane's session. Guests never get the
  prompt, whatever their role (a host that is not theirs must not ask for their passwords), and
  their `Answer`/`Cancel` are `Denied`; `client-core` never announces the capability on a guest
  connection. While a guest holds the pane's lease, clients with `Caps::ASKPASS_DRIVER` get
  `PromptWhileGuestDrives{prompt, guest}` instead of `Prompt`, and the app says "Asked while
  bob is driving". Open prompts are sent again on attach (same ids), so a reconnecting app keeps its
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
retry flag, cancel, control characters refused, yes/no questions; viewer and driver guests are
never told (even offering the capability) and are `Denied`, and the owner's prompt names a
driving guest; timeout, abandoned (helper hangs up), bad token;
no app → `"terminal"` and `--available` false, the app leaving mid-prompt → `"terminal"`
after the grace; a program that turns echo off and prints `Password:` gets `Detected`,
`TypeSecret` reaches it without echo, `NotHidden` at a shell prompt, a client attaching late is
told. `crates/hostd/tests/askpass.rs` runs the real `un-hook`: sudo- and ssh-like scripts that
call `$SUDO_ASKPASS`/`$SSH_ASKPASS` get the app's answer (or fail on Cancel), the terminal
fallback reads with echo off, and interactive zsh's `sudo` becomes `sudo -A` only while an app
can answer (`-S` left alone). Goldens: `proto/tests/golden_askpass.rs`.

### 9.1 The app's browser (`proto::browser`)

Panes get `BROWSER=<state>/browser/un-open`, a script running `un-hook open-url "$@"`. The shim
sends a `BrowserCall` (`{"browser":{"open":{"url":…}}}`) on the hook socket; the daemon pushes
`ServerCtl::Browser(Open)` to one of the owner's connections with `Caps::BROWSER` that shows the
pane's session (the one that last sized the pane, else the newest; never a guest's, whose
browser holds the guest's own sign-ins) and answers `"opened"` (exit 0), or `"no_app"`: the
shim then runs `open` / `xdg-open` (with `BROWSER` cleared) when there is a display, else exits
1 so the program prints its URL. Only `http(s)` URLs pass, in the app and to the system opener
(which would also launch apps and run `file://` scripts).

This is how `claude /login` works from a phone: Claude Code hands `BROWSER` the URL whose
`redirect_uri` is its callback server on the host's `127.0.0.1:<random>`. The app sees that
redirect, serves this device's `localhost:<port>` through a forward to the host's for the
sign-in's length (`LoopbackRouter.claim`), and opens the URL in the system sign-in sheet
(`ASWebAuthenticationSession`, ephemeral: Google refuses embedded web views). The sheet closes
once the callback passed, or once the program stops listening (probed through the forward).
`codex login` prints a URL of the same kind (port 1455); tapping it does the same. Claude's
printed URL (`redirect_uri=https://platform.claude.com/oauth/code/callback`) opens in the in-app
browser, which types `code#state` into the pane when the provider's page is reached.

Agent CLIs' own listeners (`claude`, `codex` by name) are left out of port detection: their
`/` is an empty 404 and they are not dev servers.

Browser tools: `{"browser":{"tool":{"name":…,"args":{…}}}}` is pushed as
`ServerCtl::Browser(Call)` to the same connection and held until `ClientCtl::BrowserResult`,
120 s, the caller hanging up (`CallClosed` pushed) or the connection leaving. Daemons offering
this say `DaemonFeatures::BROWSER`.

The callers are `un-hook mcp` (tools `browser_navigate`, `browser_snapshot`, `browser_find`,
`browser_get_text`, `browser_click`, `browser_double_click`, `browser_hover`, `browser_type`,
`browser_fill`, `browser_press`, `browser_scroll`, `browser_scroll_to`, `browser_wait`,
`browser_screenshot`, `browser_zoom`, `browser_tabs`, `browser_dialog`, `browser_upload`,
`browser_console`, `browser_network`; read-only ones carry `readOnlyHint`) and `un-hook browser <verb> [json | key=value …]` for
shells (Codex, scripts). Semantics follow Anthropic's browser toolset: `role "name" [ref_N]`
snapshots, targets `{"type":"ref","ref":…}` or `{"type":"coordinate","x","y"}` in screenshot
pixels, a stale ref is an error asking for a new snapshot, actions answer with what changed.
The app answers JSON `{"text", "image"?: {"data", "mimeType"}}`; `save_to_file` writes a long
snapshot to a file on the host. `browser_upload` reads its `paths` on the host and sends
`files: [{name, mime_type, data}]` (base64), at most 3 MB in all so the call fits one frame
(hook lines may be `MAX_FRAME_LEN` long). The app runs them on the browser leaf beside the agent's pane
(opened by the first navigate): the user sees each step (cursor and highlight), can take over,
and approves purchases and form submits on sign-in or payment pages, or types passwords
themselves; the call waits meanwhile. `crates/agents/skills/browser/SKILL.md` teaches agents
the tools.

### Terminal tools (`daemon::term`)

Agents drive the terminal they run in through `un-hook mcp`: one `TermCall {v, token, pane, term:
{tool, args}}` line per call on the hook socket, answered by `TermReply::Ok(value)` or
`TermReply::Error({code, message, retryable, hint})`. Design and the competitors it is measured

- **Identity.** `UN_TOKEN` in a pane is that pane's own token (an HMAC of its id under
  `hook.token`), so a pane's programs cannot act as another pane. `hook.token` itself, which only
  the state directory holds, speaks for any pane. Every hook-socket caller is checked this way,
  and the socket (0600, in the 0700 state dir or a fresh 0700 temporary dir) refuses peers of
  another uid, or of unknown uid, before reading a byte.
- **Limits.** One agent, with every worker it started, may have 32 panes open at once; a wait
  holds at most 1 MiB of output.
- **Tools.** `whoami`, `pane_list`, `pane_split`, `tab_new`, `pane_close`, `cmd_run`, `pane_read`,
  `pane_wait`, `pane_send`, `status_set`, `agent_spawn`, `agent_prompt`, `agent_wait`, `agent_result`. Ids are `p12`, `t3`; `self` (or no pane) is the caller.
- **Rules.** Read any pane of the caller's session; type into, run in and close only the panes it
  created (or that those created), never its own; nothing it opens takes the user's focus;
  input is refused while the program asks for a password (echo off, canonical).
- **Output.** Bytes are rendered by a scratch terminal of the pane's width, so carriage returns,
  erases and colors come out as seen. Results cap at 16 KiB by default (256 KiB at most), keeping
  the first third and last two thirds. A cursor (`c<seq>`, the pane's output offset) reads on
  from where a result ended; it expires once the 1 MiB ring drops it.
- **Commands.** `cmd_run` waits for the shell's prompt, pastes the command, and follows its
  OSC 133 mark to the exit code and the command's own output. Shells without integration report
  `status: unknown` after the output settles. Waits default to 30 s and stop at 240 s with
  `status: timeout`, never an error.
- **Status.** Any program's last OSC 7501 report about itself (no `id=`) is the pane's
  `status`, whatever the program; panes without one show their agent integration's state.
  `pane_wait {status: [...]}` waits for it, and `status_set` reports it for agents that cannot
  print the sequence. Clients announcing `Caps::PROGRAM_STATUS` (daemons with
  `DaemonFeatures::PROGRAM_STATUS`) get it as `ServerCtl::ProgramStatus{pane_id, status}`
  (`proto::program`): on every change, for the panes they would get `PaneMeta` for; for every
  pane in their scope that has one on joining; and for every pane of the session on attaching
  (`None` included, so a report cleared while they looked elsewhere goes). A blocked report is a
  status, never an approval request: approvals stay in `PaneMeta.agent`.
- **Workers.** `agent_spawn` starts Claude or Codex in a pane beside the caller (owned, no
  focus) and gives it its first prompt once it is idle and its screen has settled; a worker on
  a dialog (folder trust, an approval) is reported blocked instead. `agent_prompt` refuses a
  working or blocked worker and can wait for that turn's end; `agent_wait` waits for states
  across workers; `agent_result` returns the last turn's outcome and final message (from the
  agent's hooks, up to 16k characters) with its transcript path.
- **MCP.** Every tool has an `outputSchema` and returns `structuredContent` (typed values for
  code-mode harnesses) plus text that leads with a summary and then the output verbatim.
  Annotations mark the read-only tools; `agents::ACTING_TOOLS` are the ones Claude's permission
  prompt asks about. The server is `unnamed` (`agents::mcp_server_name`); registering with
  an agent removes a registration under the old `unnamed_drawings` first. Other harnesses add
  it by hand, e.g. pi: `pi mcp add unnamed -- un-hook mcp` from a pane.

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
  `.excalidraw` export (import works); kitty images cannot be dragged out of a pane (they
  are not placements, §7.10);
  Excalidraw scenes keep no history (only the current revision exports); live ink is relayed without per-connection
  rate limiting; a session's artifacts are deleted with it; anchors detach on daemon restart;
  the daemon's raster render draws text and images as outlines only.
- Native password prompts (§9): gpg's pinentry is not wired (it is configured in
  `gpg-agent.conf`, not the environment; `pinentry-tty` and `--pinentry-mode loopback` prompts
  are caught as detected prompts, curses pinentry is not); raw-mode password readers are not
  detected; a prompt in a pane of another session than the one attached waits until the app
  attaches there (or times out); the app does not yet badge a tab whose pane has an open prompt.
  ignored (they are free text); no per-shell quoting (fish reads the POSIX quoting the same way
  except inside `"…"`, where it does not treat `` ` `` specially); a watched directory that is
  deleted and recreated is re-armed only on the next event or list.
- `SetSizePolicy` is ignored (`LastInput`, restricted to the lease holder when a pane is
  leased). The ticket's relay URL is the one known at
  mint time; `endpoint.json` is refreshed as iroh's addresses change.
