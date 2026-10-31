# Stress and chaos testing

What the daemon and app do under heavy load and hostile conditions: what we ran, the peak
numbers, what broke and how it was fixed, and what is still untested. The goal is that nothing
programs, peers or the network do can crash or hang the daemon, grow it without bound, or stall
input to the focused pane. Limits are fine if they are bounded, documented, and shown calmly.

## Daemon and protocol

### How to run

Build release binaries, then run scenarios. Each one starts its own daemon in a temp state
directory with `--no-relay`, under `ulimit` caps and an RSS watchdog (`MAXRSS_MB`, default
4000), drives it over the real protocol, prints peak RSS/CPU/fds/threads and the state after the
load stops, and cleans up.

```sh
cargo build --release -p hostd -p un -p stress     # unnamed-hostd, un, un-hook, un-stress
B=target/release
scripts/stress/scenarios.sh $B panes churn floods slow clients control lifecycle soak
```

| Script | What it does |
|---|---|
| `scenarios.sh <bin> <case>...` | The scenario matrix below, one case at a time |
| `with-daemon.sh <bin> <name> <cmd>...` | Starts a daemon, pairs `un`, samples it every second while `<cmd>` runs, reports peak and recovery |
| `panes.sh`, `deep-restart.sh`, `lifecycle.sh`, `diskfull.sh` | Pane count and fd limits; nested splits across a restart; SIGHUP, zombies, SIGSTOP, restart under load, read-only state; a full disk (hdiutil image) |
| `s-flood.sh <kind> <n> <secs>` | `n` panes running an output generator, one client following, echo latency of a quiet pane |
| `s-slow.sh`, `s-clients.sh`, `s-control.sh`, `s-soak.sh` | Stuck clients; many clients (paired or `GUESTS=1`); input and control storms; mixed soak |
| `gen.py <kind> [rate]` | Output generators: titles, OSC 7/133/9/777/7501/52, OSC 8 links, Unicode storm, alt-screen storm, kitty images, long lines |
| `s-gen.sh`, `profile-during.sh`, `mem-during.sh` | Diagnostics: RSS of one generator without a client; a `sample(1)` profile; heap and VM regions mid-run |
| `un-stress` (`crates/stress`) | The driver: `churn`, `deep`, `spawn`, `latency`, `clients`, `slow` (raw peers that never read), `reconnect`, `stale-resume` (raw garbage `Hello`s), `keys`, `paste`, `layout`, `projects` |

"Echo latency" is the time from sending a token to a pane running `cat` until it comes back in
that pane's stream, measured by a separate client while the load runs.

The machine was a shared M-series Mac. During the first half of the runs its load average was
500–650 from other jobs, so the latency and churn numbers from that period are much worse than
the machine allows. The churn and soak rows were measured at a load of about 5.

### Scenarios and results

Numbers are for the release build after the fixes, unless a row says "before".

| Scenario | Peak (RSS, CPU, fds, threads) | Focused-pane echo | Outcome |
|---|---|---|---|
| 400 panes as tabs (real PTYs) | 96 MB, 46 %, 1218 fds, 820 threads | — | Survived. 0.2 MB and 3 fds per pane, idle CPU 0. After closing: 65 MB, 18 fds |
| Daemon started with launchd's soft fd limit (256), 150 panes | before: 78 panes, then `Too many open files` | — | **Fixed** (raise the soft limit at start): 150/150 |
| fd limit 600, 150 panes | 42 MB, 360 fds | — | Limit: 114 panes, then "too many panes: this host's file descriptor limit allows 114". 256 fds stay free for connections and state |
| 80 nested splits, then a restart | before: `layout.json` unreadable, **every session lost** | — | **Fixed**: nesting capped at 16, the layout comes back |
| Pane churn, create+close, 1 op in flight | 23 MB, 57 % | — | 608 panes/s, op p99 1.7 ms; back to 21 fds |
| Pane churn, 64 ops in flight | 29 MB, 66 %, 213 fds | — | 368 panes/s, op p99 170 ms (ops of one connection run in order; `fork` dominates) |
| 4 panes `yes` | 72 MB, 364 % | p50 0.5 ms, p99 20 ms | Survived, back to 32 MB |
| 3 panes `cat /dev/urandom` | 34 MB, 324 % | p99 3.7 ms | Survived |
| 2 panes, 100 MB line without a newline | 50 MB | p99 10 ms | Survived |
| 2 panes, emoji/ZWJ/flags/40 stacked combining marks/RTL storm | 57 MB, 232 % | p99 6.5 ms | Survived |
| 2 panes, alt-screen toggle storm | 38 MB | p99 1.4 ms | Survived |
| Titles (OSC 0) as fast as possible | 27 MB | p99 2.2 ms | Survived. Pushes to clients now coalesced to 20/s per pane |
| OSC 7, OSC 9/777, OSC 7501, OSC 52 (small) floods | 27–31 MB | p99 1–9 ms | Survived |
| OSC 52 with 1 MB payloads | 57 MB | p99 32 ms | Survived |
| OSC 8 hyperlinks, a new URI per line, 2 panes | 50 MB | p99 27 ms | Survived (millions of distinct URIs over the run) |
| OSC 133 marks as fast as possible | before: +130 MB/s, killed at 4 GB | — | **Fixed** (bounded pane-event queue): 38–48 MB |
| Kitty images (64×64, new id each) with a client watching | before: +300 MB/s, killed at 3 GB | p99 119 ms | **Fixed** (snapshot buffer sized up front): peak 545 MB, settles at 148 MB |
| 4 clients that stop reading, next to a `yes` flood and a title flood | before: 1.5 GB after a minute, still growing | p99 12 ms | **Fixed**: 42 MB; the daemon disconnects them (backlog or a 60 s stalled write) |
| 50 paired clients following a `yes` pane | 213 MB | p99 135 ms (load 600) | Survived; connection bursts from one IP are throttled by the pre-auth gate and retried |
| 100 guests (one unlimited invite) following a `yes` pane | 274 MB footprint, 136 MB live heap | p99 450 ms (load 600) | Survived. After they left: 5 MB live heap; macOS malloc kept 150 MB of free blocks resident |
| 200 guests, each resizing 5×/s (1000 resizes/s, all different sizes) | 1.69 GB RSS, 1270 % | p50 3.4 ms, p99 35 ms, max 4.3 s | Survived; 195 connected within 40 s (the rest throttled by the per-IP pre-auth gate). Memory per client under a flood is high, see open items |
| Keys at 10 000/s for 10 s | — | p99 0.4 ms after | Survived |
| 100 MB paste | — | p99 0.5 ms after | before: the paste failed to encode (over the 4 MiB frame), the client's connection dropped and the paste was lost. **Fixed** (client-core sends 1 MiB pieces) |
| Layout ops at 1000/s, project ops at 1000/s (10 000 each) | — | p99 0.5 ms / 4 ms after | Survived; the last op is answered |
| Connect, subscribe, drop after 0–30 ms, 8 in parallel (3661 in 15 s) | — | p99 0.4 ms after | Survived |
| Raw `Hello`s resuming garbage (5000 points: unknown panes, `u64::MAX`, stale generations), 2186 in 15 s | before: 3.6 GB, killed, unresponsive | p99 5 ms after | **Fixed** (16 connections per device, 256 resume points per `Hello`): 129 MB |
| 5 panes running `trap '' HUP; exec sleep`, then closed | — | — | before: the processes ran on forever with their wait threads. **Fixed**: process group killed after 3 s |
| 1000 unreaped zombies in a pane, then closed | 24 MB | — | Survived |
| SIGSTOP the daemon for 20 s with a client following a flood | 38 MB | p99 0.5 ms after | Survived; the client stayed connected |
| Kill and restart the daemon with a client attached | — | p99 0.3 ms after | Survived; the client reconnected by itself |
| State directory made read-only, 20 tabs created | — | p99 0.3 ms | Survived; logs "saving layout: Permission denied" |
| State directory on a 32 MB disk image filled to 100 %, 20 tabs created, then space freed and a restart | 23 MB | p99 0.3 ms | Survived; all 26 tabs came back after the restart |
| Idle connections to the hook socket | — | — | before: held forever. **Fixed**: closed after 10 s; at most 512 served at once |
| Mixed soak (see below) | see below | see below | see below |

### Bugs found and fixed

| Severity | Bug | Cause | Fix | Test |
|---|---|---|---|---|
| Critical | A client that stops reading (or a stuck path) grows the daemon without bound | Unbounded `ctl` queue per client; the writer coalesced without a bound | Coalesce at most 256 KiB per write; disconnect past 8192 queued messages or a 60 s stalled write; a client whose `ctl` stream is gone is disconnected | `stress::a_client_that_stops_reading_is_disconnected` |
| Critical | A peer reconnecting in a loop takes the daemon to GBs | Old connections stay open until timeout, each with pane-stream data in flight | At most 16 connections per device, oldest closed; at most 256 resume points per `Hello` | `stress::a_device_keeps_a_bounded_number_of_connections` |
| Critical | Shell-integration marks printed fast grow the daemon 130 MB/s | Unbounded queue from the PTY thread to the pane task | Bounded queue (dropped when full; the VT and command log keep the state); titles and directories kept as the latest value | `pane::tests::an_event_flood_is_bounded_and_keeps_the_last_title` |
| Critical | A client watching a pane with kitty images grows the daemon ~300 MB/s | Each snapshot (all images) encoded into a doubling `Vec`; macOS malloc keeps the freed large blocks resident | Encode into a buffer sized from the previous snapshot | Measured by the `kitty` flood scenario (allocator behaviour; no unit test) |
| High | More than ~60 nested splits lose every session on the next start | `serde_json`'s nesting limit (128) when reading `layout.json` | Nesting capped at 16 splits (split, move and merge) | `layout::tests::nesting_is_capped_so_saved_layouts_load` |
| High | A daemon started as a LaunchAgent caps out at ~78 panes; at fd exhaustion everything else fails too | Soft fd limit 256 (launchd) / 1024 (systemd) never raised | Raise the soft limit at start (pane processes get the inherited one back); refuse new panes while 256 fds would not stay free | `limits::tests::a_low_soft_limit_is_raised` |
| High | Pastes and input over 4 MiB drop the client's connection and are lost | One `Input` frame per paste; frames are capped at 4 MiB | client-core sends 1 MiB pieces | `stress::a_paste_larger_than_a_frame_arrives_whole` |
| Medium | Input to a program that never reads it grows without bound | The PTY thread drained the input channel into an unbounded queue | 8 MiB of unread input per pane, then writes wait; the daemon refuses input that waited 2 s (`InputRejected { Blocked }`) so one stuck pane cannot hold up the client's other panes | `lifecycle::input_for_a_program_that_never_reads_is_bounded` (pty) |
| Medium | Programs that ignore SIGHUP outlive their closed pane forever | Close sent SIGHUP only | Kill the process group after 3 s | `stress::a_process_ignoring_hangup_dies_with_its_pane` |
| Medium | Title floods push every title to every client | One metadata push per change | At most one push per 50 ms per pane, always ending with the latest | `stress::title_floods_are_coalesced` |
| Medium | Silent hook-socket connections are held forever; at fd exhaustion the accept loop spins | No read timeout, no connection cap, `continue` on accept error | 10 s for the request line, 512 connections at once, 100 ms back-off after an accept error | `stress::idle_hook_connections_are_closed` |
| Low | Opening a PTY failed with a bare `Too many open files` / `Device not configured` | No context | "cannot open a pseudo-terminal: …" | — |

### Limits (by design)

| Limit | Value | When hit |
|---|---|---|
| Panes per host | (soft fd limit − 256) / 3; on macOS the system allows 511 PTYs for all programs together | `SpawnFailed`: "too many panes: …" or "cannot open a pseudo-terminal: …" |
| Nested splits | 16 | `Invalid`: "too many nested splits (at most 16)" |
| Connections per device | 16 | The oldest is closed ("replaced by a newer connection") |
| Resume points per `Hello` | 256 distinct panes | The rest subscribe as usual |
| `ctl` backlog per client | 8192 messages, or a write stalled 60 s | Disconnected ("too slow"); resumes on reconnect |
| Unread input per pane | 8 MiB; a write waits at most 2 s | `InputRejected { Blocked }` |
| Pane events queued | 1024 | Notifications dropped; state kept |
| Hook-socket connections | 512 at once; request line within 10 s | New ones wait in the backlog; silent ones are closed |
| Pane metadata pushes | 20/s per pane | Coalesced to the latest |

### Mixed soak

30 minutes (`s-soak.sh 30`, machine load about 5): 40 idle shells, a Unicode stream at 2000
lines/s, titles at 200/s, OSC 133 marks at 200/s, a client reconnecting every 0–2 s (3599
connections), pane churn every 30 s, and a latency probe each minute.

| Minute | RSS | fds | threads | Echo p50 / p99 / max |
|---|---|---|---|---|
| 1 | 147 MB | 151 | 122 | 0.18 / 0.30 / 0.44 ms |
| 10 | 173 MB | 151 | 122 | 0.19 / 0.36 / 1.70 ms |
| 20 | 177 MB | 157 | 122 | 0.26 / 5.17 / 5.38 ms |
| 30 | 184 MB | 151 | 122 | 0.18 / 0.25 / 0.35 ms |
| +10 s after | 161 MB | 19 | 23 | — |

Descriptors and threads stay flat. RSS rose by about 1.2 MB a minute; the OSC 133 stream
records a new distinct command 200 times a second into the command history, which is capped
at 50 000 entries, so this growth is expected to level off there (a longer soak should confirm
it). No input was lost and the worst echo in 30 minutes was 12 ms.

### Not tested, and open items

- **1000 and 2000 panes, and the real PTY cap.** macOS allows 511 PTYs system-wide and the
  machine is shared, so the runs stopped at 400. The exhaustion path was driven through the fd
  limit instead (same error path). On Linux (Hetzner host, off limits for this pass) note that
  every pane has two threads and `RLIMIT_NPROC` counts threads there.
- **Self-upgrade under load**, **clock jumps** (timers are
  tokio's monotonic clock by design, but not exercised), **network chaos** (loss and latency via
  a lossy transport or local relay), **approval spam from fake agents**, real `un-hook` floods
  (only idle connections were tested), **MCP `cmd_run`/`pane_wait` at high concurrency**, and
  **knock floods**.
- **Memory per client under a flood is high**: about 1.5–8 MB per client watching a `yes` pane
  (QUIC send buffers within each stream's in-flight budget, snapshots). 200 such clients reached
  1.7 GB. Bounded, but worth shrinking: share one snapshot encode between clients that ask
  within a few ms of each other, and lower budgets for non-focused panes.
- **Kitty images**: a pane keeps up to three full snapshots (cache plus two for history paging),
  each with every image (up to the 64 MB storage limit). 545 MB peak for one image-heavy pane.
  Snapshots for history could drop the image payloads.
- **macOS malloc keeps freed memory resident** after a burst (150 MB after 100 clients left).
  `malloc_zone_pressure_relief` did not release it in a quick try; the system reclaims it under
  memory pressure.
- **Echo latency under extreme client counts**: max 4.3 s with 200 guests on a loaded machine.
  The daemon was CPU-bound on the guests' TLS handshakes and streams; the focused pane has no
  priority over other connections' work.

### Failure classes elsewhere, checked against us


| Failure class | Seen in | Us |
|---|---|---|
| Unbounded queue between PTY reader and consumer | zellij #525, xterm.js, VS Code (watermarks) | PTY ring is bounded; the event queue was not (**fixed**) |
| Children that ignore SIGHUP linger | WezTerm #8226 | **Fixed** (group kill after 3 s) |
| Clock jumps break timers | mosh #1014 | Monotonic timers by design (untested) |
| Reconnect storms | zellij #1948, WezTerm #7771 | 3661 reconnects in 15 s survived; garbage resumes were not (**fixed**) |
