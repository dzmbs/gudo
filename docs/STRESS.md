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
cargo build --release -p hostd -p cli -p stress     # gudo-hostd, gudo, gudo-hook, gudo-stress
B=target/release
scripts/stress/scenarios.sh $B panes churn floods slow clients control lifecycle soak
scripts/stress/scenarios.sh $B outages hooks term knocks upgrade many   # second pass
scripts/stress/scenarios.sh $B deadmount     # needs FUSE (bindfs, or sshfs to localhost)
SOAK_MIN=90 scripts/stress/scenarios.sh $B soak
```

| Script | What it does |
|---|---|
| `scenarios.sh <bin> <case>...` | The scenario matrix below, one case at a time |
| `with-daemon.sh <bin> <name> <cmd>...` | Starts a daemon, pairs `gudo`, samples it every second while `<cmd>` runs, reports peak and recovery |
| `panes.sh`, `deep-restart.sh`, `lifecycle.sh`, `diskfull.sh` | Pane count and fd limits; nested splits across a restart; SIGHUP, zombies, SIGSTOP, restart under load, read-only state; a full disk (hdiutil image) |
| `s-flood.sh <kind> <n> <secs>` | `n` panes running an output generator, one client following, echo latency of a quiet pane |
| `s-slow.sh`, `s-clients.sh`, `s-control.sh`, `s-soak.sh` | Stuck clients; many clients (paired or `GUESTS=1`); input and control storms; mixed soak |
| `gen.py <kind> [rate]` | Output generators: titles, OSC 7/133/9/777/7501/52, OSC 8 links, Unicode storm, alt-screen storm, kitty images, long lines |
| `s-gen.sh`, `profile-during.sh`, `mem-during.sh` | Diagnostics: RSS of one generator without a client; a `sample(1)` profile; heap and VM regions mid-run |
| `gudo-stress` (`crates/stress`) | The driver: `churn`, `deep`, `tabs`, `spawn`, `latency`, `clients`, `slow` (raw peers that never read), `reconnect`, `stale-resume` (raw garbage `Hello`s), `keys`, `paste`, `layout`, `projects`, `outages` (lines typed while the daemon is frozen, checked exactly once), `push-sink` (a device registered with a local fake push relay, counting pushes), `knocks` (fresh devices knocking on one invite) |
| `s-outages.sh`, `s-hooks.sh`, `s-term.sh`, `s-knocks.sh`, `s-upgrade.sh`, `many.sh`, `s-soak-heap.sh` | Second pass: input across outages; real `gudo-hook` floods and approval spam with a push sink; agents' terminal tools at high concurrency (a fake `codex` for `agent_spawn`); knock floods; self-upgrade under full load; 1000 panes and a restart; the soak with heap snapshots |
| `s-deadmount.sh` | A pane, a git worktree and agents' `pane_split cwd=` on a FUSE mount whose server is stopped (SIGSTOP), next to a healthy repository and a client with `Caps::REPO_STATUS`: echo, tab and sidebar latency while it hangs (`gudo-stress dead-mount`) |
| `hookload.py`, `jobs.sh` | Load from inside panes (they hold the pane's hook token): `gudo-hook` processes, held approvals, terminal-tool calls on the hook socket |

"Echo latency" is the time from sending a token to a pane running `cat` until it comes back in
that pane's stream, measured by a separate client while the load runs.

The machine was a shared M-series Mac. During the first half of the runs its load average was
500-650 from other jobs, so the latency and churn numbers from that period are much worse than
the machine allows. The churn and soak rows were measured at a load of about 5.

### Scenarios and results

Numbers are for the release build after the fixes, unless a row says "before".

| Scenario | Peak (RSS, CPU, fds, threads) | Focused-pane echo | Outcome |
|---|---|---|---|
| 400 panes as tabs (real PTYs) | 96 MB, 46 %, 1218 fds, 820 threads | - | Survived. 0.2 MB and 3 fds per pane, idle CPU 0. After closing: 65 MB, 18 fds |
| Daemon started with launchd's soft fd limit (256), 150 panes | before: 78 panes, then `Too many open files` | - | **Fixed** (raise the soft limit at start): 150/150 |
| fd limit 600, 150 panes | 42 MB, 360 fds | - | Limit: 114 panes, then "too many panes: this host's file descriptor limit allows 114". 256 fds stay free for connections and state |
| 80 nested splits, then a restart | before: `layout.json` unreadable, **every session lost** | - | **Fixed**: nesting capped at 16, the layout comes back |
| Pane churn, create+close, 1 op in flight | 23 MB, 57 % | - | 608 panes/s, op p99 1.7 ms; back to 21 fds |
| Pane churn, 64 ops in flight | 29 MB, 66 %, 213 fds | - | 368 panes/s, op p99 170 ms (ops of one connection run in order; `fork` dominates) |
| 4 panes `yes` | 72 MB, 364 % | p50 0.5 ms, p99 20 ms | Survived, back to 32 MB |
| 3 panes `cat /dev/urandom` | 34 MB, 324 % | p99 3.7 ms | Survived |
| 2 panes, 100 MB line without a newline | 50 MB | p99 10 ms | Survived |
| 2 panes, emoji/ZWJ/flags/40 stacked combining marks/RTL storm | 57 MB, 232 % | p99 6.5 ms | Survived |
| 2 panes, alt-screen toggle storm | 38 MB | p99 1.4 ms | Survived |
| Titles (OSC 0) as fast as possible | 27 MB | p99 2.2 ms | Survived. Pushes to clients now coalesced to 20/s per pane |
| OSC 7, OSC 9/777, OSC 7501, OSC 52 (small) floods | 27-31 MB | p99 1-9 ms | Survived |
| OSC 52 with 1 MB payloads | 57 MB | p99 32 ms | Survived |
| OSC 8 hyperlinks, a new URI per line, 2 panes | 50 MB | p99 27 ms | Survived (millions of distinct URIs over the run) |
| OSC 133 marks as fast as possible | before: +130 MB/s, killed at 4 GB | - | **Fixed** (bounded pane-event queue): 38-48 MB |
| Kitty images (64×64, new id each) with a client watching | before: +300 MB/s, killed at 3 GB | p99 119 ms | **Fixed** (snapshot buffer sized up front): peak 545 MB, settles at 148 MB |
| 4 clients that stop reading, next to a `yes` flood and a title flood | before: 1.5 GB after a minute, still growing | p99 12 ms | **Fixed**: 42 MB; the daemon disconnects them (backlog or a 60 s stalled write) |
| 50 paired clients following a `yes` pane | 213 MB | p99 135 ms (load 600) | Survived; connection bursts from one IP are throttled by the pre-auth gate and retried |
| 100 guests (one unlimited invite) following a `yes` pane | 274 MB footprint, 136 MB live heap | p99 450 ms (load 600) | Survived. After they left: 5 MB live heap; macOS malloc kept 150 MB of free blocks resident |
| 200 guests, each resizing 5×/s (1000 resizes/s, all different sizes) | 1.69 GB RSS, 1270 % | p50 3.4 ms, p99 35 ms, max 4.3 s | Survived; 195 connected within 40 s (the rest throttled by the per-IP pre-auth gate). Memory per client under a flood is high, see open items |
| Keys at 10 000/s for 10 s | - | p99 0.4 ms after | Survived |
| 100 MB paste | - | p99 0.5 ms after | before: the paste failed to encode (over the 4 MiB frame), the client's connection dropped and the paste was lost. **Fixed** (client-core sends 1 MiB pieces) |
| Layout ops at 1000/s, project ops at 1000/s (10 000 each) | - | p99 0.5 ms / 4 ms after | Survived; the last op is answered |
| Connect, subscribe, drop after 0-30 ms, 8 in parallel (3661 in 15 s) | - | p99 0.4 ms after | Survived |
| Raw `Hello`s resuming garbage (5000 points: unknown panes, `u64::MAX`, stale generations), 2186 in 15 s | before: 3.6 GB, killed, unresponsive | p99 5 ms after | **Fixed** (16 connections per device, 256 resume points per `Hello`): 129 MB |
| 5 panes running `trap '' HUP; exec sleep`, then closed | - | - | before: the processes ran on forever with their wait threads. **Fixed**: process group killed after 3 s |
| 1000 unreaped zombies in a pane, then closed | 24 MB | - | Survived |
| SIGSTOP the daemon for 20 s with a client following a flood | 38 MB | p99 0.5 ms after | Survived; the client stayed connected |
| Kill and restart the daemon with a client attached | - | p99 0.3 ms after | Survived; the client reconnected by itself |
| State directory made read-only, 20 tabs created | - | p99 0.3 ms | Survived; logs "saving layout: Permission denied" |
| State directory on a 32 MB disk image filled to 100 %, 20 tabs created, then space freed and a restart | 23 MB | p99 0.3 ms | Survived; all 26 tabs came back after the restart |
| Idle connections to the hook socket | - | - | before: held forever. **Fixed**: closed after 10 s; at most 512 served at once |
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
| Low | Opening a PTY failed with a bare `Too many open files` / `Device not configured` | No context | "cannot open a pseudo-terminal: …" | - |

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
lines/s, titles at 200/s, OSC 133 marks at 200/s, a client reconnecting every 0-2 s (3599
connections), pane churn every 30 s, and a latency probe each minute.

| Minute | RSS | fds | threads | Echo p50 / p99 / max |
|---|---|---|---|---|
| 1 | 147 MB | 151 | 122 | 0.18 / 0.30 / 0.44 ms |
| 10 | 173 MB | 151 | 122 | 0.19 / 0.36 / 1.70 ms |
| 20 | 177 MB | 157 | 122 | 0.26 / 5.17 / 5.38 ms |
| 30 | 184 MB | 151 | 122 | 0.18 / 0.25 / 0.35 ms |
| +10 s after | 161 MB | 19 | 23 | - |

Descriptors and threads stay flat. RSS rose by about 1.2 MB a minute; the OSC 133 stream
records a new distinct command 200 times a second into the command history, which is capped
at 50 000 entries. No input was lost and the worst echo in 30 minutes was 12 ms.

**90 minutes** (same mix, machine load 3 to 290 from other jobs, heap sampled every
10 minutes with `heap(1)`): the growth levels off. It was the command history filling up.

| Minute | RSS | Live heap | History file lines | fds / threads |
|---|---|---|---|---|
| 1 | 75 MB | - | - | 151 / 116 |
| 10 | 106 MB | 81 MB | 69 370 | 151 / 122 |
| 20 | 114 MB | 85 MB | 90 199 | 151 / 124 |
| 30-90 | 113-122 MB, flat | 85-88 MB | 55 675-97 004, sawtooth | 151 / 124 |
| +10 s after | 93 MB | - | - | 19 / 19 |

The history keeps up to twice its cap (100 000 distinct commands, about 60 MB here) before it
compacts to 50 000; the live heap follows that sawtooth and nothing else grows. 10 411
reconnects over the run. Echo p50 0.25-20 ms and p99 under 190 ms throughout, except one
sample of 4.0 s at minute 52 during a load spike of the machine; nothing was lost.

### Second pass

Self-upgrade, network outages, clock steps, approval spam, real hook floods, agents' terminal
tools, knock floods, a 90-minute soak (above) and 1000 panes, on the same shared Mac (load 3
to 290). "Before" rows ran the build from before the fixes, A/B at the same load where they
compare numbers.

| Scenario | Peak (RSS, CPU, fds, threads) | Focused-pane echo | Outcome |
|---|---|---|---|
| Self-upgrade under full load (40 shells, 2 `yes`, a Unicode stream, a title flood, 20 guests following a flood, 2 reconnect loops), 3 rounds | 122 MB, 955 %, 157 fds, 120 threads | p99 under 1 ms between rounds | before: **the daemon died** restarting on round 2 or 3 (SIGPIPE, exit 141). **Fixed** (`execv`): every round answers in 0.8-5 s (the 38 MB build over QUIC), back 1.0-1.1 s later, all 46 tabs back, same PID; the 20 guests reconnected each round |
| Same, no load, a client reconnecting, 10 upgrades in a row | - | - | before: 0 of 10 came back. After: 10 of 10 |
| Lines typed every 20 ms while the daemon is frozen (SIGSTOP) 2 s every 10 s, and 8 s every 20 s | 24 MB | - | Survived: 2001/2001 and 3001/3001 lines, exactly once, no reconnect (QUIC retransmits) |
| Same, frozen 20 s every 30 s (past the 12 s idle timeout, so the link drops) | 24 MB | back 8.3 s after the thaw | before: **601 of 4501 lines lost** (everything typed between the freeze and the drop). **Fixed** (input resume): 5500/5500, none lost or doubled, over 2 drops |
| Packet loss, high RTT and link flaps through a UDP proxy | - | - | **Not testable on one host**: QUIC multipath opened a direct loopback path around the proxy (12 of thousands of datagrams went through it). Needs pf/dummynet (root) or a second machine |
| Approval spam: 20 fake agents × 4 threads running `gudo-hook claude PermissionRequest` in a loop (about 35 000 requests a minute), a device registered for pushes with a local fake relay | 107 MB, 33 %, 275 fds | p99 64 ms | Survived. Each pane holds one request (a newer one replaces it) and identical requests merge into one approval: 20 pushes, 20 inbox items |
| 40 fake agents each asking for a new approval every 4 s | - | - | before: 40 pushes at once (the relay accepts 30 a burst per daemon, so 10 would be refused and retried). **Fixed**: within the relay's budgets, the rest wait their turn: all 40 delivered over 130 s |
| Real `gudo-hook` flood: 4 panes × 16 threads, PreToolUse/PostToolUse, 30 s | 62 MB, 31 % | p99 13-22 ms | Survived: 640-860 hooks/s (by machine load), none failed, hook p99 under 300 ms (process start included) |
| 600 `pane_wait`s for a pattern that never comes on a `yes` pane, real hooks from another pane | before: 1.07 GB, 1040 % | before: p50 2.0 s, p99 3.9 s, one lost | **Broke, fixed**: renders were synchronous on the async workers and unbounded; the hook socket was full (hooks 2/s, 5 s each, 32 failed). After: 442 MB, 412 %, echo p99 6 ms, hooks 298/s, none failed; calls past 32 per pane are refused at once |
| `cmd_run` without a pane from 40 threads | - | - | before: after 16 panes **every call failed** ("too many nested splits"). **Fixed**: past the nesting limit panes open in a background tab; the 32-pane budget then holds |
| `agent_spawn` (a stand-in `codex`) from 16 threads | - | - | before: **41 panes** opened for a budget of 32 (parallel calls raced the count). **Fixed**: exactly 32 |
| Knock flood: 32 fresh devices at a time knocking on one knock invite, 60 s, then 32 that stay | before 205 MB; after 437 MB (cheaper refusals let more connections through: 21 000 in 90 s) | p99 118 → 44 ms | before: 254 knocks reached the owner a minute and 10 366 refusals filled the audit log (4.6 MB a minute). **Fixed**: 16 knocks reached the owner, 47 audit records in all. Waiting knocks stay at 8 per invite |
| Same, live heap 65 s after the flood | 118 MB → 31 MB | - | Recovers: iroh keeps state per remote key for 60 s after its last connection (see limits) |
| 100 guests following a `yes` pane, 40 s, without and with shared snapshots (A/B at load ~24) | 439 → 397 MB, 813 → 748 % | p99 311 → 272 ms | Shared snapshots: 8 % less CPU, 10 % less RSS. The first version **deadlocked the daemon** (fixed before merging, regression test). Memory per client stays about 3.5-4 MB: QUIC send buffers, not snapshots |
| Kitty images (64×64, new id each), one client, 40 s | 416 → 351 MB | p99 13 ms | Older history snapshots now kept only within 48 MiB: one full snapshot fewer, 276 → 211 MB after the load |
| 1000 panes: 300 tabs running `sleep` (real PTYs) and 700 canvas tabs, then a restart | 70 MB, 921 fds, 622 threads | p99 0.4 ms | Survived. PTY tabs 2.7 ms each; canvas tabs 32 ms each at 1000 (three fsynced writes per canvas, see limits); layout 8 KiB on the wire, `layout.json` 270 KB; answering 1.0 s after the restart with all 1001 panes; 48 MB after closing |
| Clock steps (wall clock set back or forward) | - | - | Reviewed, **two bugs fixed** (not exercised on the real clock, which needs root): the hook shim ordered hooks by wall-clock nanoseconds, so after the clock went back every hook of an agent was dropped as stale until the clock caught up (approvals vanished from the app for that long); the agent arbiter measured its debounces and staleness on the wall clock, so a step back delayed "blocked" notifications by the step. Both use the boot clock now (`daemon::clock`). Expiries (grants, tickets, push action tokens, auto-approve rules) stay on the wall clock by design: they are absolute times |

Bugs found and fixed in the second pass:

| Severity | Bug | Cause | Fix | Test |
|---|---|---|---|---|
| Critical | Self-upgrade killed the daemon instead of restarting it whenever clients were connected | `Command::exec` resets SIGPIPE to its default before `execve` while the runtime's other threads still run; a write to a socket a peer had just closed delivered SIGPIPE | Restart with `execv` directly (the new build ignores SIGPIPE again as it starts) | `hostd/tests/restart.rs` (a real daemon, 4 upgrades, clients reconnecting) |
| Critical | Shared snapshots deadlocked the daemon (found by the A/B run before merging) | The ring's oldest offset was read under the VT lock; the PTY thread feeds the VT under the ring's lock | Read it before taking the VT lock | `pane::tests::snapshots_of_a_flooding_pane_are_shared_without_deadlock` |
| High | Keystrokes typed while the link was dying were lost (601 in a 20 s freeze) | Input written to a connection that then died was never sent again | Input resume: clients with `Caps::INPUT_RESUME` keep numbering input across reconnects and resend what was not acknowledged; the `Welcome`'s resume token names the input stream and the daemon applies each number once (`DaemonFeatures::INPUT_RESUME`) | `stress::input_sent_again_after_a_reconnect_is_applied_once`, `resend` and `resume` unit tests |
| High | Waits with a pattern stalled the whole daemon and the hook socket | Each wait re-rendered up to 1 MiB on every chunk, synchronously on the async workers; one agent could hold all 512 hook connections | Renders off the workers, four at a time, at most every 100 ms per wait over batched output; 32 calls in progress per pane | `term::tests::one_pane_cannot_hold_every_call_slot`; the `term` scenario |
| High | After the clock went back, an agent's hooks (approvals) were dropped until it caught up | Hook order by wall-clock nanoseconds | Boot-clock order | `clock` unit tests (a real step needs root) |
| Medium | A leaked knock link flooded the owners and the audit log (4.6 MB a minute on disk, forever) | No limit per invite but 8 waiting; every refusal audited | 8 knocks at once per invite, then one per 10 s; refusals audited once a minute with a count | `mp::rate_limit` tests |
| Medium | Agents' panes past 16 nested splits all failed | Every new pane split the caller's pane again | Open them in a background tab | `term::panes_past_the_nesting_limit_open_in_a_tab` |
| Medium | Parallel tool calls overshot the 32-pane budget (41) | Count and open were not atomic | One lock around both | `term::parallel_opens_stay_within_the_pane_budget` |
| Medium | Push bursts past the relay's budget were refused and retried with back-off | No budget on the daemon side | The relay's budgets (30 a burst then one per 3 s per daemon, one per 12 s per device), honouring 429 `retry-after`; pushes past them wait their turn | `notifier::tests::alerts_stay_within_the_relays_budgets` |
| Medium | Blocked-agent notifications from the screen were held back by a step of the clock | Arbiter debounce on the wall clock | Steady clock (wall time at start, carried by the boot clock) | - |
| Low | Loading a long audit log held it whole in memory; each append shifted 10 000 records | `Vec` then `drain` | Bounded `VecDeque` while reading | existing audit tests |
| Low | An image-heavy pane kept two full snapshots (tens of MB each) | Two kept for history paging whatever their size | Older ones only within 48 MiB | `pane::tests::large_snapshots_keep_no_older_copies` |

New limits (by design):

| Limit | Value | When hit |
|---|---|---|
| Terminal-tool calls in progress per pane | 32 | Refused at once, retryable ("32 calls from this pane are still running") |
| Agents' output renders at once | 4 | Calls wait their turn |
| Knocks per invite | 8 at once, then one per 10 s (and 8 waiting) | `Refused { InvalidGrant }`; audited once a minute with a count |
| Alert pushes | 30 a burst then one per 3 s per daemon, one per 12 s per device | Waits its turn; dropped if seen meanwhile |
| Input kept for resending | 4 MiB or 8192 inputs per client | Older unacknowledged input could be lost on a dead link, never doubled |
| Input streams remembered | 4096 (idle ones forgotten after 30 min) | A client resuming after that starts a new stream |
| iroh state per remote key | 60 s after its last connection | A stranger opening connections from fresh keys holds memory for a minute: about 13 KB per key; 118 MB live after 21 000 connections in 90 s, 31 MB a minute later |
| Canvas panes | three fsynced writes each | about 30 per second at 1000 canvases |

### Stalled mounts

A directory on a network mount whose server stops answering (NFS, SMB, sshfs, an autofs
`/net` path) blocks `stat` and every git there for minutes. Found in review; each fix has a
test that makes the hang with a probe that never returns or a fake git that sleeps.

| Severity | Bug | Cause | Fix | Test |
|---|---|---|---|---|
| Medium | A pane, split or agent tool with its directory on a stalled mount froze that client's ops, and a few parallel agent calls froze the daemon | `is_dir()` on the pane's directory on an async worker, under the agents' opening lock | The directory is checked on a thread of its own for at most 500 ms (falling back to home), once per stuck path; agent tools check theirs before taking the lock | `fsutil::tests::a_hanging_directory_is_unreachable_without_holding_the_caller` |
| Medium | One stuck git stopped the git sidebar and turn diffs for every repository, for good | No timeout on daemon git; one tracker task and one serial snapshot queue awaited it | Every daemon git runs in its own process group and is killed after 60 s; the tracker runs git per directory, one at a time each, off its task; turn snapshots run per pane | `git::tests::a_hung_git_is_killed_with_its_helpers`, `repo::tests::a_hung_repository_holds_back_no_other`, `turns::tests::a_stuck_pane_holds_only_its_own_turns` |
| Low | A stopping daemon waited for blocking work stuck on the mount | The runtime waits for blocking tasks when dropped | At most 2 s | - |

The `deadmount` scenario could not run with a real stalled mount on the test Mac: no FUSE
(macFUSE, bindfs, sshfs), no `/net` automount, and NFS or SMB servers need root. It ran
with a stand-in (a plain directory, a stopped `sleep` as the "server") to check the driver:
echo p99 3.3 ms, a tab in 40 ms, a change in the healthy repository on the sidebar in 0.8 s
(the 250 ms tick plus the debounce). Run it on Linux with bindfs or sshfs to localhost, or
set `DEADMOUNT_MOUNT`, `DEADMOUNT_PID` and `DEADMOUNT_UNMOUNT` for an NFS export whose server
can be stopped.

### Not tested, and open items

- **2000 panes and the real PTY cap.** macOS allows 511 PTYs for the whole machine
  (`kern.tty.ptmx_max`, root to raise) and other jobs hold some, so real PTYs stopped at 300 and
  1000 panes were reached with 700 canvas panes. The exhaustion path is driven through the fd
  limit instead (same error path). On Linux note that every pane has
  two threads and `RLIMIT_NPROC` counts threads there.
- **Packet loss, latency and flaps on the wire.** Outages were made by freezing the daemon, which
  covers the dead-link and resume paths; QUIC's own loss recovery was not exercised (see the
  scenario table). On a second machine, put `pf`/`dnctl` or `tc netem` between client and daemon
  and run `gudo-stress outages` with `--every 0` (a plain typing check).
- **A real clock step** (needs root). Timers and the arbiter run on monotonic or boot clocks;
  the remaining wall-clock uses are absolute expiries and timestamps.
- **Memory per client under a flood**: about 3.5-4 MB per client following a `yes` pane, mostly
  QUIC send buffers within each stream's in-flight budget. Lower budgets for non-focused panes
  would shrink it.
- **Agent pane renders**: a render of a megabyte of short lines still takes 40 ms and up to 30
  MB; four run at once.
- **macOS malloc keeps freed memory resident** after a burst (150 MB after 100 clients left).
  `malloc_zone_pressure_relief` did not release it in a quick try; the system reclaims it under
  memory pressure.
- **Echo latency under extreme client counts**: max 4.3 s with 200 guests on a loaded machine.
  The daemon was CPU-bound on the guests' TLS handshakes and streams; the focused pane has no
  priority over other connections' work.

### Known failure classes of terminal servers, checked against us

Collected from public bug reports of terminal emulators and multiplexers.

| Failure class | Us |
|---|---|
| VT parser crash or livelock takes every pane down (fate sharing) | Same risk: one libghostty-vt per pane, in-process. Floods above found none; seeded fuzzing is still to do |
| Unbounded queue between PTY reader and consumer | PTY ring is bounded; the event queue was not (**fixed**) |
| Slow or stuck client grows the server | Pane streams were bounded by acks; `ctl` was not (**fixed**) |
| Per-connection work or task floods | Pre-auth gate for strangers; paired devices now capped at 16 connections (**fixed**) |
| Reader/writer deadlocks | PTY thread never blocks on a queue (event queue uses `try_send`); no lock held across `.await` |
| Huge paste blocks or is dropped | Non-blocking PTY writes; pastes over 4 MiB were dropped with the connection (**fixed**) |
| Scrollback, hyperlink and image memory | Byte caps per pane (10 MB scrollback, 64 MB images); OSC 8 floods stayed at 50 MB; snapshot buffers were not (**fixed**) |
| Title and notification floods | Coalesced (**fixed**) |
| fd and PTY exhaustion, accept loop spinning | Soft limit raised, pane cap with reserve, accept back-off (**fixed**) |
| Children that ignore SIGHUP linger | **Fixed** (group kill after 3 s) |
| Restart loses sessions | Layout and agent sessions restored; clients reconnect by themselves (verified under load) |
| Disk full, corrupt state | Atomic writes; a full disk and a read-only state dir both survive |
| Clock jumps break timers | Timers were monotonic, but hook ordering and the agent arbiter used the wall clock (**fixed**: boot clock) |
| Self-update kills the process | `Command::exec` let SIGPIPE through during the restart (**fixed**) |
| Keystrokes lost on a dying link | Unacknowledged input is resent and applied once (**fixed**) |
| Reconnect storms | 3661 reconnects in 15 s survived; garbage resumes were not (**fixed**) |

## App and renderer

Machine: a shared 128 GB M-series Mac. Other build jobs and simulators ran at the same time, and the load average
ranged from 20 to 890. Timings marked *loaded* were taken at a load average above 200. Compare them with each other, not with
other machines. Renderer numbers come from in-process TerminalKit tests in a release build (the Mac app is
never launched in the foreground). They drive the same `TerminalSurface` path the app uses, headless.

### How to run

- Regression tests (fast; they run with the normal suite):
  `cd apple/Packages/TerminalKit && swift test --filter 'RendererStressTests|AtlasTests|SearchTests'`
- Probes that print the numbers below (slow, opt-in):
  `GUDO_STRESS=1 swift test -c release -Xswiftc -enable-testing --filter StressProbeTests`.
  Set `GUDO_STRESS_SAMPLE=<file>` to `sample(1)` the hot loop of probes that support it, and
  `GUDO_STRESS_PAUSE=<file>` to make `probeSurfaceChurn` and `probeKittyLimits` write their pid and wait 40 s, so
  `leaks <pid>` and `vmmap --summary <pid>` can inspect them.

### Renderer scenarios

| Scenario | Peak / result before | After | Outcome |
|---|---|---|---|
| 20k distinct CJK at 48 pt (`probeCJK`) | Grayscale atlas grew to 16384² (256 MB CPU + 256 MB GPU). The next doubling (32768) exceeds Metal's limit, the texture would fail to allocate, and every pane with that font goes blank. Worst frame 1.1 s *loaded* | Atlas capped at 8192² (64 MB); a full atlas starts over. Footprint +138 MB instead of +588 MB. Worst frame 118 ms (headless, no budget) | **Broke, fixed** |
| 1107 emoji at 48 pt, 500 per frame | One frame took 1.8 s on the main thread (each large color emoji rasterizes in about 3-4 ms) | Glyph rasterization gets a shared budget of 6 ms per display frame; the rest fill in over the next frames. 400 new emoji at 40 pt: worst frame < 200 ms in the test under load, 608 ms without the budget | **Broke (hang), fixed** |
| A frame needing more glyph space than a whole atlas | n/a | Draws what fits, stays incomplete and retries; no loop, no crash | Limit by design |
| Shared atlas reset by one pane while others show it | n/a | Other panes rebuild every row on their next frame; new textures, so frames still on the GPU keep the old ones | Fixed with the above |
| Random bytes (64 KiB × 200) plus random combining clusters (`probeRandomBytes`) | Glyph lookup caches grew without bound (one entry per distinct cluster or glyphless codepoint) | Caches cleared past 65,536 entries. Worst frame 63 ms, atlas 2048² | **Broke (unbounded memory), fixed** |
| View larger than 16384 px (9000×5000 pt at 2×, `probeHugeDrawable`) | `CAMetalLayer` refused the size (`drawableSize` 0×0): the pane stayed blank | Scale lowered in quarter steps (1.75×), drawable 15750×8750, draws | **Broke, fixed** |
| 6K window (3008×1692 pt at 2×), 4 pt font: 1201×306 = 367k cells, full redraw every frame (`probeTinyFont6K`) | Build avg 70 ms, max 155 ms per frame, all on the main thread (fair A/B, same load) | Build avg 36 ms, max 75 ms. Drawables 3 × 81 MB | Survived. Cost halved, and the main thread is protected by the render budget |
| 120 panes, 16 visible, each flooding 30 lines per frame (`probeManySurfaces`) | 16-pane round avg 12.9 ms, worst 57 ms | Round avg 9.0 ms, worst 11-18 ms. Releasing GPU memory gives back what drawing took (+0 MB vs start) | Survived |
| Floods saturating the main thread (many visible panes, huge grids) | Nothing limited render time: 16 visible flooding panes, or one huge grid, could take the whole main thread | Display-link frames share a token bucket: at most 50 % of the main thread on average, bursts up to 50 ms, focused pane first. Panes drop frames, never content | **Broke (by design gap), fixed** |
| Font-size and theme change every frame during a flood, 200 steps 6-60 pt (`probeFontSizeStorm`) | Worst 20 ms, avg 8 ms | Same. An equal appearance assignment no longer discards cached rows | Survived |
| Kitty graphics: 60 × 2000×1500 RGBA, then one 8000×2000 (64 MB) image (`probeKittyLimits`) | Storage keeps 5 (64 MB limit); worst frame 5-13 ms; the 64 MB image is scaled to 4096 on upload in 30-44 ms. Off-screen panes kept their kitty textures | Off-screen panes drop kitty textures and reload them on the next frame | Survived. GPU memory leak off screen fixed |
| Scrollback search for "e" in a full 10 MB scrollback (375k matches) during a flood, with a match selected (`probeSearchDuringFlood`) | Every frame re-read and sorted all 375k matches: ~39 ms per frame, worst 152 ms | The selected index refreshes at most every 250 ms while output streams. Remaining cost is libghostty's own `ScreenSearch.pruneHistory` on the writer thread | **Broke (hang), fixed**; the libghostty part is a limit |
| Resize with a full scrollback of long wrapped lines (emoji, CJK), 20 resizes | Worst resize 5 ms | - | Survived |
| Unterminated OSC with 100 MB of payload | 4 ms, +1 MB, title discarded | - | Survived |
| Open, draw, hide and close 50 panes, 10 cycles (`probeSurfaceChurn`) | Footprint flat across cycles (246-261 MB in process); last surface freed; `leaks`: 0 leaks; 4 threads, 54 fds after | - | Survived |
| iOS memory warning | Nothing responded to it | Every shared atlas that grew starts over (frees up to 64 MB CPU + 64 MB GPU per font size); panes redraw from the terminal | Fixed (`memoryWarningReleasesGrownAtlases`) |

Bugs found in the renderer:

| Severity | Bug | Fix | Test |
|---|---|---|---|
| High | Glyph atlas doubled without limit: hundreds of MB, then past Metal's 16384 texture limit (blank panes) | Cap (8192 grayscale, 4096 color); a full atlas starts over (`FontGrid.epoch`) and builders rebuild | `fullAtlasStartsOverAndTheFrameIsRebuilt`, `otherBuildersRebuildAfterAReset`, `frameLargerThanTheAtlasDropsGlyphs`, `stopsGrowingAtItsCapAndStartsOver` |
| High | New glyphs rasterized synchronously on the main thread: seconds-long hangs on a screen of new emoji or CJK | Shared 6 ms per-frame rasterization budget; rows with deferred glyphs are rebuilt next frame | `newGlyphsNeverStallAFrame`, `rasterDeadlineDefersGlyphsToLaterFrames` |
| High | Rendering had no main-thread limit (floods in big grids or many panes starve input and UI) | `RenderBudget` token bucket in the display-link tick | `renderBudgetLeavesTheMainThreadTimeAndPrefersTheFocusedPane` |
| Medium | Search recount of every match on every frame during output | Throttled to 250 ms while output streams | `streamingOutputDoesNotRecountEveryFrame` |
| Medium | Views past 16384 px drew nothing | Lower drawable scale | `oversizedViewStillDraws` |
| Medium | Unbounded glyph lookup caches (hostile output) | Cleared past 65,536 entries | `lookupCachesStayBounded` |
| Medium | Off-screen panes kept kitty image textures | Released with the rest of the GPU state | `offscreenPanesDropKittyTextures` |
| Medium | No response to iOS memory warnings | `FontGrid.releaseCaches` on `didReceiveMemoryWarningNotification` | `memoryWarningReleasesGrownAtlases` |
| High (build) | iOS build broken on main: `releaseGPUResources` set the macOS-only `autoresizingMask` | `#if os(macOS)` | iOS simulator build of TerminalRenderer |
| Low (build) | `DuoUITests` broke the macOS test build (`XCUIDevice.orientation`) | File limited to iOS | macOS AppTests build |
| Low | An equal appearance assignment threw away every cached row | Guard | `equalAppearanceIsFree` |
| Perf | Full-grid row rebuild cost (class-property exclusivity checks per cell, hashing every ASCII glyph) | Local cell buffer; indexed ASCII glyph cache | Probe A/B: 70 → 36 ms |

Limits now by design (renderer):
- Glyph atlas: 8192² grayscale, 4096² color per font size; past that it starts over (a frame bigger than that drops glyphs).
- New-glyph rasterization: 6 ms of main thread per display frame, shared by all panes.
- Rendering: 50 % of the main thread on average (bursts to 50 ms); background panes yield first.
- Drawables: at most 16384 px per side. A 6K pane holds up to 3 × 81 MB of drawables while on screen.
- Search: with a match selected, "n of N" refreshes 4×/s while output streams.

### SwiftUI under churn and input (Mac, in-process)

Fake daemon with a real `DaemonConnection`, `LiveAgentFeed` and `WindowContent` in an offscreen window. Debug build (a Release
test build does not link `FilesProviderKitTests`). "Hang" is the longest the main queue went unserved, measured by a
watchdog thread that pings it every 5 ms (`HangWatch`).

| Scenario | Before | After | Outcome |
|---|---|---|---|
| Sidebar, 120 tabs / 12 projects, 100 agent updates/s | hang 1.0-1.5 s, main thread 100 % busy | hang 85-196 ms *loaded* | **Broke, fixed**: the session was recomposed on every read (O(tabs²)), any pane's metadata invalidated every row, and there was no rate limit |
| Sidebar, 500 tabs / 50 projects, 100 updates/s, 10 s | hang 161 ms, CPU 72 % | hang 109 ms (3 of 555 pings > 100 ms), CPU 75 %, footprint 163 → 174 MB | **Broke, fixed**: project suggestions re-resolved every host's tabs per tab (60 → 1.4 ms per render) |
| Sidebar idle, 500 tabs | - | hang 9 ms, CPU 24 % (the shimmer and spinner of visible rows) | Survived |
| Inbox, 500 agents, 100 updates/s + 100 attention items/s | hang 443-844 ms (120 agents), saturated | hang 220 ms, CPU ~100 % (low load) | **Broke, fixed in part**: the Inbox was O(items²) (each row rebuilt the feed), and every visible row re-rendered on every update (closure inputs defeat SwiftUI's diff; rows now equatable on what they show). Still over 100 ms at this extreme rate |
| Opening a host with 500 tabs | one hang of 450-550 ms (500 panes, terminal + surface + view, made in one turn) | worst hang 92 ms (0 of 146 pings over 100 ms), all 500 panes made within the run | **Broke, fixed**: the window's tab is made at once and the rest in 8 ms stages between frames; each pane is observed on its own (`Workspace.pane(_:)`, `PaneHolder`), so a stage redraws only the views that show its panes (`testManyTabsAreMadeInStagesAndObservedPerPane`). Sampling the open then showed two more O(tabs²) costs, both fixed: naming 500 new tabs composed the window's session once per rename (`WindowLayoutStore.apply` now composes only for ops that read it), and the queue of panes to make was searched linearly by every sidebar row (`PaneQueue`, O(1)) |
| Sidebar idle, 12 working rows (shimmer + spinner) | main run loop woke 8299 times in 1 s (per-frame timelines) | under 15 | **Broke, fixed**: Core Animation layers (`LayerAnimationTests`) |
| Key storm, 20k keys with prediction on | - | ~25 µs per key, flat | Survived |
| Paste of 10 / 50 / 200 MB | 16 ms / 0.32 s / 1.3 s on main, +400 MB at 200 MB; the confirmation's line count took 4 / 14 / 100 s | Over 16 MiB refused in < 50 ms with an alert; line count is one pass | **Broke, fixed** (product decision: refuse, not chunk) |
| Drag of 64 MB of text over a pane | ~45 ms per pointer move | 60 moves < 100 ms (types checked only) | **Broke, fixed** |
| Notification storm from the attention feed | one Task and two XPC calls per item | one request in flight, newest note per pane (`NoteQueue`) | **Broke, fixed** |
| Open and close 10 windows of 30 panes | a closed window's `Workspace` stayed alive (strong captures in pending observations) | panes, views, surfaces and the window model freed | **Leak, fixed** |

### Client connection and mirror (HostKit, client-core, real release daemon)

Timings *loaded* (load average 500-650). Memory, fds and threads are reliable.

| Scenario | Peaks (footprint / threads / fds / main hang) | Outcome |
|---|---|---|
| Flood (`yes`, 32 MB text loop, urandom, CJK + emoji) into the client terminal, flooding pane focused | 75-171 MB / ≤ 12 / ≤ 45 / ≤ 5 ms; other pane echo p95 ≤ 20 ms | Survived. The client takes 13-36 MB/s, and the daemon switches to snapshots when it falls behind. Memory grows by about one scrollback (10 MB), then stays flat |
| History-page and view storm during a flood (~300 views opened and closed, 30 resubscribes, 200-300 pages) | 68-165 MB / ≤ 11 / ≤ 45 / 13-37 ms | Survived |
| Title and bell flood (`ESC]0;…BEL` × 200k in a loop) | before: footprint 17 → 145 MB in 8 s, 5.4 M main-actor tasks; after: 103-115 MB, main hang ≤ 15 ms | **Broke, fixed** (`MainActorCoalescer`, bell at most every 100 ms) |
| 20 hosts, 5 flooding, 60 s | 85 MB / 9 / 74; echo p50 14.5 → 4.5 ms | **Degraded, fixed** (pane streams yield the runtime's workers after each frame) |
| Daemon that admits and drops every connection | before: 3084 dials in 4 s | **Broke, fixed** (backoff resets only after a connection stayed up 5 s) |
| Flapping host (SIGSTOP/CONT, kill and restart ×5), resume after 15 s mid-flood | 46-102 MB, fds flat, live again in 12-110 ms through one snapshot | Survived |
| Closing the last view of a flooding pane | the pane resubscribed and kept streaming forever | **Broke, fixed** (output for a pane without a mirror is dropped) |
| Disconnecting or re-pairing a host while its panes are on screen | the client kept streaming and redialling | **Broke, fixed** (`close()` suspends the client) |
| 200 pane open/close and 100 connect/disconnect rounds | 13.5 → 13.7 MB / 21 fds; `leaks`: 0 | Survived |

### iOS lifecycle (own iPad Pro 13" simulator, iOS 27.0, local release daemon)

`apple/scripts/lifecycle-stress.sh [cycles]` creates the simulator and the daemon, runs `LifecycleStressUITests`, sends a
real memory warning every second (`notifyutil -p dev.gudo.debug.memorywarning`, a DEBUG hook that calls UIKit's own
memory-warning path), samples the app's footprint every second, lists crash reports, and deletes the simulator.

| Scenario | Peaks | Outcome |
|---|---|---|
| A pane flooding (`while :; do seq 1 100000; done`) among 7 splits: 10 background/foreground cycles, 20 rotations, ~57 memory warnings | footprint 115 MB peak, 102 MB at the end | Survived: the pane takes input and draws its text afterwards (checked on pixels) |
| Same, 40 cycles, 80 rotations, ~149 memory warnings (4 min) | 116 MB peak, 104 MB at the end, flat across cycles | Survived; no crash reports |

A frozen or vanished host must not show "connected" for QUIC's idle timeout (~30 s). Both sides keep alive every 3 s and time out after 12 s, and the app pings on
foreground and when a keystroke gets no ack within 1 s: no pong in 3 s (10 s while packets still arrive) drops the link
and it shows as reconnecting (`client-core` `liveness.rs`: a host whose runtime is frozen is dropped within 3-5 s of a
probe; a host answering after 5 s is kept). Known limit (client): the client terminal parses
13-36 MB/s, so a faster pane is shown through snapshots rather than byte for byte.

### More ways to run

- SwiftUI churn (from `apple/`): `TEST_RUNNER_GUDO_MOCK=1 xcodebuild -project App.xcodeproj -scheme App -destination
  'platform=macOS,arch=arm64' test -only-testing:AppTests/AppStressTests`. `TEST_RUNNER_STRESS=1` runs the full sizes
  (500 tabs, 50 projects, 10 s), and `TEST_RUNNER_STRESS_TABS` / `_SECONDS` override them.
- Client and connection: `cargo test -p client-core --test it` (`streams.rs`, `redial.rs`). Then
  `cd apple/Packages/HostKit && GUDO_STRESS=1 GUDO_HOSTD_BIN=<release gudo-hostd> swift test --no-parallel --filter
  'ClientStressTests|ConnectionChurnTests'`; `GUDO_STRESS=heavy` runs the long variants.
- iOS lifecycle: `GUDO_HOSTD_BIN=<gudo-hostd> apple/scripts/lifecycle-stress.sh 40`.

### Not tested (App and renderer)

- iPad multi-window with many scenes, and scene connect/disconnect (XCUITest cannot open scenes). App Lock lock/unlock cycles.
- Network-level drops (SIGSTOP and kill stood in for them).
- Release-build numbers for the SwiftUI runs (the Release test build fails to link `FilesProviderKitTests`).

- On-device runs (iPhone/iPad hardware, real jetsam limits, ProMotion pacing). Everything ran in-process or in simulators.
- The display-link path end to end with real windows on the Mac (the Mac app is never launched in the foreground). The render
  budget is tested as a policy and through headless surfaces.
- GPU stalls and loss (sleep/wake, display unplug, eGPU) and `nextDrawable` blocking up to 1 s when no drawable is free.
- Keystroke-to-photon latency under load (needs client instrumentation; see docs/PERFORMANCE.md).
- Leaving the CPU copy of the atlas out (it would halve atlas memory), and `maximumDrawableCount = 2` for 6K panes.
