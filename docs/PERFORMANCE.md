# Performance and resource use

How much RAM, CPU and wakeups the daemon and the app cost, how it was measured, what changed,
and what is left. Keep the tables current: re-run the scripts and update the numbers when you
change anything on these paths.

Goal: with nothing changing on screen, cost nothing, whatever the pane count. Under load, the
focused pane stays smooth and background panes cost little. The slowest Mac to care about is a
2019-2020 Intel Mac with integrated graphics and 8 GB, or a base M1 with 8 GB. On iPhone,
background panes should cost close to nothing.

## 1. How it is measured

Scripts are in `scripts/perf/`. Each one starts a release `gudo-hostd` with a temporary state
directory and `--no-relay`, drives it with `gudo`, and samples the daemon process. Output goes to
`$BENCH_OUT` (default `$TMPDIR/gudo-bench`).

| Script | Scenario |
|---|---|
| `measure.sh <bin> <label>` | Idle zsh panes: 0, 1, 10 and 50, then 50 with one attached client, then after that client leaves |
| `busy.sh <bin> <label> <N> yes\|no` | N panes in one session. With `yes`, a realistic share are active (`role.sh`): 1× `yes`, 1× `cat` of a 64 MB file in a loop, 5× `top -s 1`, 5× `tail -f` of a log growing 10 lines/s, 5× build-like output at 50 lines/s, 5× spinner at 12 updates/s, 2× fake agent (OSC 9/7501 plus bursts). The rest are idle. |
| `heavy.sh <bin> <label> yes\|cat` | One flooding pane, without and with a client |
| `agents.sh <bin> <label> <claude> <idle> [pi] [kimi]` | Real coding-agent sessions (Claude Code launched the daemon's way, via `split --agent`; Kimi as a command), each in its own scratch git repo (`agent-repos.sh`), with idle panes around them. The prompt keeps each agent busy for several minutes (eight feature-plus-test rounds). |
| `profile.sh <bin> yes\|cat <out>` | `sample(1)` of the daemon under a flood; `busy.sh` with `PROFILE=<file>` samples the busy scenario |

How each metric is taken:
- **CPU %** is the daemon's CPU time (`ps -o time`) over the window (20-30 s), divided by wall time.
- **ctx/s** is the change in `top`'s cumulative `CSW` (context switches), divided by wall time. This is the stable
  stand-in for wakeups. `top`'s `IDLEW` swings with the rest of the machine's load, so it is not used.
- **RSS** is `ps -o rss` at the end of the window.

The machine is a 128 GB M-series Mac shared with other build jobs, so CPU numbers carry noise
of about ±0.5 percentage points at idle and much more under load. The context-switch counts are steadier.

App-side numbers come from in-process tests, because the Mac app is never launched in the foreground for
measurements. `SharedFontGridTests` in TerminalKit prints a pane's memory on and off screen.
Run it alone for clean numbers:
`swift test --filter offscreenPanesGiveBackGPUMemory`.

## 2. Daemon

### Idle panes (zsh at a prompt, no client unless noted)

Measured 40 s after the last pane was created (`SETTLE=40`): a pane that just did something keeps
polling its terminal modes once a second for 30 s, then stops.

| Panes | Before: RSS, CPU, ctx/s | After: RSS, CPU, ctx/s |
|---|---|---|
| 0 | 17.9 MB, 0.05 %, 51 | 17.7 MB, 0.05 %, 8 |
| 1 | 22.5 MB, 0.10 %, 53 | 22.7 MB, 0.05 %, 11 |
| 10 | 24.8 MB, 0.65 %, 121 | 24.8 MB, 0.00 %, 10 |
| 50 | 32.7 MB, 2.30 %, 230 | 33.2 MB, 0.05 %, 10 |
| 50, one client attached | 33.8 MB, 1.35 %, 202 | 34.2 MB, 0.30 %, 40 |
| 50, after the client left | 33.8 MB, 1.10 %, 185 | 34.2 MB, 0.05 %, 9 |
| 200 | 62.4 MB, 4.5 %, 736 | 61.2 MB, 0.0 %, 11 |
| 200, one client attached | 63.3 MB, 4.6 %, 736 | 62.3 MB, 0.6 %, 38 |

RSS is the same before and after: an idle pane costs about 0.2-0.3 MB in the daemon (PTY, ring,
libghostty terminal), and that is all memory that is actually used.

Before, every pane paid for itself many times a second, even with no client connected:
- a 500 ms agent/port tick per pane (with a foreground-process read every second);
- a PTY thread polling the terminal modes every second;
- a global 40 ms input-assist loop that read every pane's foreground process (sysctl argv and env) ten times a second;
- a 500 ms multiplayer tick and a 2 s port-scan timer.

After, a quiet pane costs nothing: 200 idle panes cost the same ~10 context switches/s as none.
With a client attached, the foreground sampler reads the panes the client shows at 10 Hz and the rest of
its session's panes at 1 Hz. It reuses a process read while the foreground group id is unchanged, so most
samples are one `tcgetpgrp` per pane.

### Busy panes (100 panes, 25 active as listed above)

| Client | Before: RSS, CPU, ctx/s | After: RSS, CPU, ctx/s |
|---|---|---|
| none | 95 MB, 173 %, 56 k | 72 MB, 175 %, 51 k |
| one attached | 101 MB, 88 %, 39 k | 79 MB, 183 %, 41 k |

The busy numbers did not move (the run-to-run noise is ±50 points). Almost all of this is the two
floods (`yes`, `cat` of 64 MB in a loop) going through libghostty-vt on the daemon at about 70 MB/s
each. A macOS PTY master hands out at most 1 KiB per read, and waiting to batch reads only throttles
the writer: measured, a 0.5 ms pause per wake cut `yes` from 77 MB/s to 1.3 MB/s. So every KiB used to cost
one poll sleep and one wakeup. Ghostty measured the same limit and bridges the gaps instead: after a full read it
retries the read a few times before sleeping. Doing the same (16 retries) cut the context switches
spent draining a 64 MB `cat` from 22-44 k to 2-13 k, at equal or lower CPU (0.3-0.8 CPU s either
way; `drain.sh`, 3 runs each). In the busy run the daemon's context switches fell from 51 k/s to 18 k/s,
at the same 176 % CPU. In a profile of the busy run, parsing, printing and scrollback page growth inside
libghostty are most of the active samples. The rest was per-chunk work in the daemon:
- The OSC scanner stepped through every byte. It now jumps to the next ESC with `memchr`; it had been about 7 % of active samples.
- The PTY thread called `tcgetattr` after every read. Under a stream it now reads the modes at most every 25 ms; this had been about 5 %.

### Real agent sessions (Claude Code on Haiku, plus Kimi, with idle panes around them)

| Sessions | Client | Before: RSS, CPU, ctx/s | After: RSS, CPU, ctx/s |
|---|---|---|---|
| 5 Claude + 30 idle | none | - | 39 MB, 0.9 %, 369 |
| 5 Claude + 30 idle | one | - | 41 MB, 2.4 %, 466 |
| 10 Claude + 2 Kimi + 40 idle | none | 52 MB, 4.4 %, 850 | 52 MB, 3.1 %, 900 |
| 10 Claude + 2 Kimi + 40 idle | one | 54 MB, 4.2 %, 933 | 53 MB, 4.7 %, 985 |
| 20 Claude + 60 idle | none | 74 MB, 15.1 %, 2.4 k | 72 MB, 5.6 %, 2.0 k |
| 20 Claude + 60 idle | one | 77 MB, 14.1 %, 1.6 k | 76 MB, 10.7 %, 1.6 k |

A `sample(1)` profile with 10 Claude sessions and a client attached (1.5 % CPU) shows nothing hot:
the daemon's threads sit in `poll`/`kevent`, and the top Rust frame is the echo-state update with 21
samples in 15 s.

The daemon is not the bottleneck for agent work. Twenty concurrent Claude Code sessions cost it
about 5-11 % of one core, and each agent's own Node process costs far more. Agent panes keep
their 500 ms tick on purpose: the state arbiter's timers and agent-exit detection need it. The
idle panes around them now cost nothing. The variance between runs is large because the agents' pace
varies.

`pi` was not part of the matrix. On this machine it is configured for a local 27B model through
Ollama, so running it would load the shared machine far more than the thing being measured.

### Regression guards

- `daemon` `terminal::unchanged_pane_metadata_is_not_pushed_again`: setting the same title five
  times pushes nothing. Before, every title set or agent event re-sent the pane's metadata to every client,
  and each push re-renders the app's sidebar.
- `daemon` `core::tests::idle_panes_stop_ticking`: three quiet panes stop ticking within the
  activity window, and output makes a pane tick again. It fails if pane tasks go back to a fixed timer.
- `pty` `echo_state::refresh_echo_reads_a_silent_mode_change`: a quiet terminal no longer polls its
  modes, and `refresh_echo` (called on focus and subscribe) picks up a silent change at once.

## 3. App

### Renderer memory per pane (TerminalKit, 900×600 pt at 2×, headless)

| | On screen | Off screen (hidden tab, background, occluded window) |
|---|---|---|
| Before | 12.3 MB | 12.3 MB (nothing was released) |
| After | 9.5 MB | 1.0 MB |

What changed:
- **Shared glyph atlases.** Panes with the same font and size share one `FontGrid` with its atlases and their
  Metal textures. Before, every pane rasterized and kept its own copy. That was 2.5 MB at the
  starting size, and an atlas doubles as it fills (emoji, CJK), so the saving grows with use.
- **GPU memory released off screen.** A surface that leaves its window, a backgrounded iOS scene or an occluded Mac window
  releases its `CAMetalLayer` together with its drawables, plus its frame buffers, offscreen target and built frame.
  Releasing the layer is the only reliable way to free the drawables. Shrinking `drawableSize` or
  clearing `contents` frees nothing while the layer lives. On screen, a pane holds up to three
  full-size drawables. That is 26 MB for this size, and roughly 60 MB each on a 5K display. A hidden tab used to keep all of
  that. The next frame rebuilds everything in one pass, from the local terminal state.
- **Display link stops for occluded windows.** It already stopped when a view left its window and
  idled when nothing changed.

Guard: `SharedFontGridTests` checks the grid is shared and freed with its last surface, and that the released layer is deallocated.

### Timers and invalidation

| Before | After |
|---|---|
| Every daemon workspace re-read every pane's metadata once a second, forever, also in the background | Follows the daemon's metadata through Observation, coalesced to at most 2 refreshes/s. No timer. |
| Every SSH pane ran a 250 ms timer for echo inference for as long as it was open | The timer runs only while keystrokes wait for their echo |
| The agent `Spinner` was a `TimelineView(.animation)`: every working agent's indicator rebuilt its view on every frame (120 Hz on ProMotion). A SwiftUI repeating animation then still ran on the main thread every frame | A Core Animation rotation on the arc's layer: the render server turns it, the main thread does nothing |
| The working-title shimmer was a 30 Hz `TimelineView` rebuilding a per-glyph gradient: about 30 % of the main thread in Debug with 10 working titles, and XCUITest never saw the app idle (60 s stalls) | A gradient layer slid by Core Animation, masked by the text; same band, same phase. A sidebar of 12 working rows woke the main run loop 8299 times in 1 s before, under 15 after (`LayerAnimationTests`) |
| The daemon re-sent a pane's metadata on every title set or agent event, and the app assigned it even when equal, which invalidated every view reading `meta` | Sent and assigned only when it changed |
| Every terminal's display link asked for 60-120 Hz | 120 Hz only for the focused terminal; others stream output at up to 60 Hz. Every link still pauses when nothing changes. |

### Instant start (M5 Max, debug builds; docs/APP-ARCHITECTURE.md §26)

A window opens on the workspace this device saved of each host, before the host answers.

| | Time |
|---|---|
| Saved workspace read, decoded and seeded into its connection (`model.open`, local daemon) | 1.0 ms median of 5 (cache file 1.4 KB, one pane); 0.9-4.9 ms sealed, on a busy machine |
| Opening the sealed file (AES-GCM) / the whole `load` (read, open, LZFSE, plist) | 0.004 / 0.18 ms for a 6 KB file (one 120×40 pane); 0.05 / 0.84 ms for a 92 KB file (three 240×70 panes of random hex, 388 KB of screens) |
| Reading the cache key from the Keychain (once per launch, then kept in memory) | 1.2 ms (login keychain, test item) |
| …then connected / daemon layout / the focused pane's live screen on it (local daemon, loopback) | 7.1 / 8.4 / 8.1 ms median of 5 (the screen comes before the layout: panes subscribe before attaching) |
| First frame of a window on the saved workspace, no host connected (seed + window model + 3 panes + layout + draw, in-process offscreen) | 0.37-0.86 s first window of a test process; 0.17-0.36 s warm (three runs, machine shared with other builds) |
| The same window on this device's plain shell, for comparison | 0.14-0.24 s warm |

This Mac as the app reaches it (its own helper with relays on, a `pair --local` ticket, the app's
relay settings; HostKit `ThisDeviceTests`, M5 Max, debug):

| | Time |
|---|---|
| Opened again: connected / daemon layout | 8 / 12 ms median of 5 |
| Helper started after the app dialled (login item still starting): helper up, then live | 50 ms, then 11 ms (was 430-460 ms: the redial waited for the dial in flight to find the helper) |

A connection on its way shows nothing for 1 s (no notice, no "Connecting to…" page, the saved
tabs undimmed), so none of this is seen.

So the saved workspace costs about 1 ms to show and 0.03-0.1 s of drawing over an empty window
(three Metal surfaces and the host's sidebar rows, debug build); the rest is the window itself.
Before, the window showed "Connecting to This Mac…" until the host's layout arrived. Reproduce:
`GUDO_HOSTD_BIN=… swift test --filter instantStartShowsTheSavedWorkspaceThenGoesLive` (HostKit) and
`AppTests/InstantStartTests` (`testFirstFrameTimesWarm` prints both window times).

In the app, the `launch` log category (`log stream --predicate 'subsystem == "<bundle id>" AND
category == "launch"'`) records process start → first frame (and whether it was a saved
workspace) → the shown host live, and the `app` category the moment This Mac's helper is dialled.
Not measured yet: a real cold launch of a release build with the login-item helper (the Mac app
is not launched by agents).

## 4. Data-oriented pass on the hot paths

Profiled first (`sample(1)` of the TerminalKit probes and of the daemon under the stress
scenarios), then each candidate was measured A/B against the commit before it, runs interleaved,
same machine load, 3 runs each; ranges are min-max. A change was kept only if it was clearly
faster with nothing slower elsewhere.

Renderer probes (release; `GUDO_STRESS=1 swift test -c release -Xswiftc -enable-testing --filter StressProbeTests`):
- `probeTinyFont6K`: 6K window at 4 pt (1201×306 cells, colored ASCII), full redraw every frame.
- `probeTinyFont6KNonASCII`: the same with box drawing, Greek and CJK.
- `probeSixteenPanes6K`: a 6K window split into 16 panes at 7 pt (187×46 each), all flooding colored output.
- `probeGlyphLookup`: one cached glyph lookup.

Build time is the CPU side of a frame: render-state update, row rebuild and instance assembly.

| Candidate | Measure | Before | After | Kept |
|---|---|---|---|---|
| Gather each row's cells into flat per-column arrays (codepoints, widths, styles, colors; clusters in one side buffer) from libghostty's bulk raw-cell view, instead of 8 calls and a nested `[UInt32]` per cell | 6K tiny build avg | 24.7-24.8 ms | 16.8-16.9 ms | yes |
| | 16 panes, per pane frame | 0.53-0.57 ms | 0.33-0.34 ms | |
| Reuse a style across a run of cells with the same style id; read arrays and the frame style from locals | 6K tiny | 16.6-17.0 ms | 13.4-13.6 ms | yes |
| Direct-mapped glyph cache (4096 slots, key packed into a u64: codepoint, style, span, constraint width) in front of the dictionary for non-ASCII codepoints | cached non-ASCII lookup | 39-40 ns | 9.1 ns | yes |
| | 6K non-ASCII build avg | 20.7-21.1 ms | 11.5-11.7 ms | |
| ASCII table and glyph cache as plain memory behind a `let` (no exclusivity or uniqueness check per cell) | lookup ASCII / non-ASCII | 6.4 / 9.1 ns | 2.5 / 5.6 ns | yes |
| | 6K tiny / 6K non-ASCII / 16 panes | 13.4 / 11.3 / 0.31 ms | 11.0 / 9.5 / 0.26 ms | |
| Copy a cached row's instances in bulk, then patch y | 6K tiny / 6K non-ASCII / 16 panes | 11.0 / 9.7 / 0.26-0.31 ms | 10.0 / 8.7 / 0.24 ms | yes |
| One `ghostty_cell_get_multi` per cell instead of four `ghostty_cell_get` | 6K tiny / 6K non-ASCII / 16 panes | 10.9-11.1 / 9.4-9.7 / 0.257-0.262 ms | 11.0-11.1 / 9.6-9.7 / 0.262-0.266 ms | no |

Overall the 6K full redraw went from 24.8 to 10.0 ms per frame, the non-ASCII one from 21 to
8.7 ms, and a pane of the 16-pane flood from 0.55 to 0.24 ms.

Daemon (release; stress scenarios from docs/STRESS.md plus an `#[ignore]`d timing test):

| Candidate | Measure | Before | After | Kept |
|---|---|---|---|---|
| Walk split trees without boxing an iterator per node (`has_leaf` recursive, `leaves()` with a stack that one pane never allocates). Every event a client is sent asks which session and tab hold its pane, under the layout lock | `session_of_pane` + `tab_of_pane`, 402 panes (`layout::tests::pane_lookup_cost`) | 3540-3607 ns | 235-237 ns | yes |
| | 400 panes setting their title twice a second, 20 clients, daemon CPU over 20 s | 38.3-39.2 s | 27.6-37.1 s | |
| | same, samples of threads blocked on a mutex (the layout lock) | 5705-8166 | 149-247 | |
| Resize count in an atomic, so a stream's per-chunk resize check skips the VT lock the parser holds | 100 guests on a `yes` pane: daemon CPU per MB delivered | 0.198-0.213 s | 0.201-0.212 s | no |
| | 4 `yes` panes, one client: MB delivered in 30 s; echo p50/p99 | 890-907 MB; 0.27/0.41 ms | 905-913 MB; 0.27/0.41 ms | |

The atomic resize count cut the samples of tokio workers blocked on the VT lock from 1366 to 128
(100 guests), but nothing a client sees moved, so it was not kept.

What the profiles showed, and so was not changed:
- **Fan-out to many clients** is socket syscalls: with 100 guests on a flood, `sendmsg`/`recvmsg`
  are 78 % of the active samples, QUIC 5 %, libghostty 4 %, and the daemon's own code (stream
  bookkeeping, frame encoding, the per-client copy of each chunk and snapshot) 1.6 %.
- **Floods** are libghostty parsing (out of scope); the OSC scanner is 0.15 % of active samples.
- **Pane registry** (`HashMap<PaneId, …>` in `Core`) and the attention and approval tables did not
  appear in any profile. A flat pane → (session, tab) index on top of the cheaper walk would save
  about 0.2 µs per lookup, under 1 % of a core at 20 clients and 800 events/s.

Not tried (low expected value against the profiles above): generational slot indices for panes,
borrowed serialization of `Bytes`/`SnapshotZstd` frames to skip the per-client copy, reused
snapshot and history encode buffers, client-core resume and stream bookkeeping per pane (not
profiled), per-row arrays in the frame builder's row cache, and writing instances straight into
the Metal buffer.

Guards: `RendererStressTests.fullRebuildOfA6KGridStaysWithinBudget` (a full 6K rebuild within
0.6 s in debug and 40 ms in release; now 235 ms and about 10 ms, before 408 and 25 ms),
`gatheredRowsMatchTheCellByCellReads` (the row gather equals the per-cell API on styles, colors,
wide characters and clusters), `DirectGlyphCacheTests` (misses, "draws nothing", collisions never
answering for another key, same glyphs with and without the cache), and
`leaves_walk_left_to_right_and_find_each_pane`.

## 5. What is left (estimated gains)

Daemon:
- **Floods are bounded by libghostty parsing (inherent).** A cheaper path for panes nobody watches would help:
  parse at a lower rate and coalesce. libghostty has to see every byte to stay correct, so the gain is
  in batching (fewer, larger writes). Estimate: 10-30 % of flood CPU.
- **Agent panes tick at 2 Hz.** Each tick reads the screen text when the screen changed. This could be
  driven by output plus the arbiter's next deadline, for a small gain (about 1 % CPU at 20 agents).
- **The art tick (1 s) and the iroh endpoint** are the remaining idle wakeups (about 6/s, independent of the pane count).

App (not measured end to end, because the Mac app is not launched in the foreground for benchmarks):
- **App CPU and RSS with N panes and N agents.** This needs a headless host or an Instruments run by a person. The
  in-process numbers above cover memory per pane only.
- **Client terminal scrollback.** Each pane keeps a 10 MB scrollback cap. Lowering it on iOS
  (1-2 MB) and compacting background panes would save up to about 8 MB per busy pane.
- **Ghostty-style gather/parse split.** Ghostty reads on one thread and parses 64 KiB batches on
  another, one lock per batch. With bridging in place, our remaining flood cost is parsing itself
  (libghostty, same code). A split would move it off the PTY thread but not shrink it. Worth it only if focused-pane
  latency during floods shows up in a measurement.
- **The renderer's idle tick does work before it can say "clean".** `renderIfDirty` runs the
  inline-image, gutter and kitty closures (allocating arrays) before checking dirty flags. Checking flags first would make
  every idle display-link tick near free.
- **Atlases keep a CPU copy of every glyph bitmap** alongside the texture. Dropping it after upload
  would roughly halve atlas memory (the atlas is now shared, so about 1.3 MB per font size).
- **Other periodic SwiftUI views:** `TabSubtitle` (one per tab, 1 s) and the presence/knock timelines. Each is small,
  but they scale with tabs.
- **Keystroke latency and frame pacing under load** were not measured. This needs instrumentation in the
  client (input → echo applied → frame presented).

## 6. Approach and references

The rules followed: delete work before optimizing it; every change is backed by a measurement and
a known technique; no speculative caches, custom allocators or thread pools.

What we took, and from where:
- **Wake only on events, never on timers.** Apple's energy guide says to replace polling with dispatch sources
  and to give the remaining timers tolerance
  ([Energy Efficiency Guide: Timers](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)).
  Ghostty runs its display link "only while the surface is visible and has something to draw"
  ([DisplayLink.zig](https://github.com/ghostty-org/ghostty/blob/main/src/renderer/DisplayLink.zig)).
  This is why pane ticks, the sampler, the port scan and the multiplayer tick sleep until something happens.
- **Bridge the 1 KiB macOS PTY reads.** Ghostty: "the kernel tty output queue caps every read on the master at 1 KB";
  its 8-16 immediate retries catch "over 90 % of the gaps" ([Exec.zig](https://github.com/ghostty-org/ghostty/blob/main/src/termio/Exec.zig)).
  We adopted the retries alone.
- **Share glyph atlases.** foot shares fonts and glyph caches across windows in server mode
  ([foot](https://codeberg.org/dnkl/foot)). Zed keeps one long-lived glyph atlas
  ([Leveraging Rust and the GPU to render user interfaces at 120 FPS](https://zed.dev/blog/videogame)). Windows Terminal's
  AtlasEngine shows why an atlas must not be per view and grow-only
  ([PR #11623](https://github.com/microsoft/terminal/pull/11623)).
- **GPU memory is app memory.** On Apple silicon the footprint includes GPU objects, and jetsam
  counts it ([WWDC22 10106](https://developer.apple.com/videos/play/wwdc2022/10106/),
  [Reducing your app's memory use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-memory-use)).
  So surfaces off screen drop their layer and drawables
  ([maximumDrawableCount](https://developer.apple.com/documentation/quartzcore/cametallayer/maximumdrawablecount)).
- **Frame rate follows need.** "The fastest animation sets the display rate"; dropping from 60 to 30 fps can save up to 20 %
  of battery drain ([WWDC22 10083](https://developer.apple.com/videos/play/wwdc2022/10083/),
  [ProMotion](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays)).
  Hence 120 Hz only for the focused terminal, and no per-frame `TimelineView` for spinners.
- **Observation granularity.** An equal assignment to an `@Observable` property still invalidates its readers, and
  per-item models beat one big dictionary ([WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)).
  Hence the equality guards on pane metadata.

Deliberately not adopted, and why:
- **kitty's fixed `repaint_delay` / `input_delay` timers** ([kitty.conf](https://sw.kovidgoyal.net/kitty/conf/)).
  They are timers, so they wake the CPU. The display link plus dirty tracking already coalesces renders to the screen's rate
  and costs nothing when idle.
- **Buffer-age partial redraw** (Alacritty, [PR #5863](https://github.com/alacritty/alacritty/pull/5863)).
  `CAMetalLayer` exposes no buffer age, and a full instanced redraw of a pane is a fraction of
  a millisecond.
  Our dirty-row cache already skips rebuilding unchanged rows.
- **`displaySyncEnabled = false`** ([docs](https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled)).
  It tears.
- **One thread multiplexing every pane** (foot server mode). foot itself warns that a busy window starves the others.
  We keep one PTY thread per pane, and those threads cost nothing while idle.
- **Raising the PTY output speed to get bigger reads.** Measured: `B230400` left reads at about 1 KiB on macOS 26.
- **Purgeable atlases and heaps** ([setPurgeableState](https://developer.apple.com/documentation/metal/mtlresource/setpurgeablestate(_:))).
  With one shared atlas per font size, the atlas is too small to be worth the complexity.
