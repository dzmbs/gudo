# Stress and chaos testing

How the product holds up under load: the scenarios run, their peak numbers, what broke and how
it was fixed, and the limits that are now by design. Re-run the probes when you change these paths.

## App and renderer

Machine: a shared 128 GB M-series Mac. Other build jobs and simulators ran at the same time, and the load average
ranged from 20 to 890. Timings marked *loaded* were taken at a load average above 200. Compare them with each other, not with
other machines. Renderer numbers come from in-process TerminalKit tests in a release build (the Mac app is
never launched in the foreground). They drive the same `TerminalSurface` path the app uses, headless.

### How to run

- Regression tests (fast; they run with the normal suite):
  `cd apple/Packages/TerminalKit && swift test --filter 'RendererStressTests|AtlasTests|SearchTests'`
- Probes that print the numbers below (slow, opt-in):
  `UNNAMED_STRESS=1 swift test -c release -Xswiftc -enable-testing --filter StressProbeTests`.
  Set `UNNAMED_STRESS_SAMPLE=<file>` to `sample(1)` the hot loop of probes that support it, and
  `UNNAMED_STRESS_PAUSE=<file>` to make `probeSurfaceChurn` and `probeKittyLimits` write their pid and wait 40 s, so
  `leaks <pid>` and `vmmap --summary <pid>` can inspect them.

### Renderer scenarios

| Scenario | Peak / result before | After | Outcome |
|---|---|---|---|
| 20k distinct CJK at 48 pt (`probeCJK`) | Grayscale atlas grew to 16384² (256 MB CPU + 256 MB GPU). The next doubling (32768) exceeds Metal's limit, the texture would fail to allocate, and every pane with that font goes blank. Worst frame 1.1 s *loaded* | Atlas capped at 8192² (64 MB); a full atlas starts over. Footprint +138 MB instead of +588 MB. Worst frame 118 ms (headless, no budget) | **Broke, fixed** |
| 1107 emoji at 48 pt, 500 per frame | One frame took 1.8 s on the main thread (each large color emoji rasterizes in about 3–4 ms) | Glyph rasterization gets a shared budget of 6 ms per display frame; the rest fill in over the next frames. 400 new emoji at 40 pt: worst frame < 200 ms in the test under load, 608 ms without the budget | **Broke (hang), fixed** |
| A frame needing more glyph space than a whole atlas | n/a | Draws what fits, stays incomplete and retries; no loop, no crash | Limit by design |
| Shared atlas reset by one pane while others show it | n/a | Other panes rebuild every row on their next frame; new textures, so frames still on the GPU keep the old ones | Fixed with the above |
| Random bytes (64 KiB × 200) plus random combining clusters (`probeRandomBytes`) | Glyph lookup caches grew without bound (one entry per distinct cluster or glyphless codepoint) | Caches cleared past 65,536 entries. Worst frame 63 ms, atlas 2048² | **Broke (unbounded memory), fixed** |
| View larger than 16384 px (9000×5000 pt at 2×, `probeHugeDrawable`) | `CAMetalLayer` refused the size (`drawableSize` 0×0): the pane stayed blank | Scale lowered in quarter steps (1.75×), drawable 15750×8750, draws | **Broke, fixed** |
| 6K window (3008×1692 pt at 2×), 4 pt font: 1201×306 = 367k cells, full redraw every frame (`probeTinyFont6K`) | Build avg 70 ms, max 155 ms per frame, all on the main thread (fair A/B, same load) | Build avg 36 ms, max 75 ms. Drawables 3 × 81 MB | Survived. Cost halved, and the main thread is protected by the render budget |
| 120 panes, 16 visible, each flooding 30 lines per frame (`probeManySurfaces`) | 16-pane round avg 12.9 ms, worst 57 ms | Round avg 9.0 ms, worst 11–18 ms. Releasing GPU memory gives back what drawing took (+0 MB vs start) | Survived |
| Floods saturating the main thread (many visible panes, huge grids) | Nothing limited render time: 16 visible flooding panes, or one huge grid, could take the whole main thread | Display-link frames share a token bucket: at most 50 % of the main thread on average, bursts up to 50 ms, focused pane first. Panes drop frames, never content | **Broke (by design gap), fixed** |
| Font-size and theme change every frame during a flood, 200 steps 6–60 pt (`probeFontSizeStorm`) | Worst 20 ms, avg 8 ms | Same. An equal appearance assignment no longer discards cached rows | Survived |
| Kitty graphics: 60 × 2000×1500 RGBA, then one 8000×2000 (64 MB) image (`probeKittyLimits`) | Storage keeps 5 (64 MB limit); worst frame 5–13 ms; the 64 MB image is scaled to 4096 on upload in 30–44 ms. Off-screen panes kept their kitty textures | Off-screen panes drop kitty textures and reload them on the next frame | Survived. GPU memory leak off screen fixed |
| Scrollback search for "e" in a full 10 MB scrollback (375k matches) during a flood, with a match selected (`probeSearchDuringFlood`) | Every frame re-read and sorted all 375k matches: ~39 ms per frame, worst 152 ms | The selected index refreshes at most every 250 ms while output streams. Remaining cost is libghostty's own `ScreenSearch.pruneHistory` on the writer thread | **Broke (hang), fixed**; the libghostty part is a limit |
| Resize with a full scrollback of long wrapped lines (emoji, CJK), 20 resizes | Worst resize 5 ms | — | Survived |
| Unterminated OSC with 100 MB of payload | 4 ms, +1 MB, title discarded | — | Survived |
| Open, draw, hide and close 50 panes, 10 cycles (`probeSurfaceChurn`) | Footprint flat across cycles (246–261 MB in process); last surface freed; `leaks`: 0 leaks; 4 threads, 54 fds after | — | Survived |
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
| Sidebar, 120 tabs / 12 projects, 100 agent updates/s | hang 1.0–1.5 s, main thread 100 % busy | hang 85–196 ms *loaded* | **Broke, fixed**: the session was recomposed on every read (O(tabs²)), any pane's metadata invalidated every row, and there was no rate limit |
| Sidebar, 500 tabs / 50 projects, 100 updates/s, 10 s | hang 161 ms, CPU 72 % | hang 109 ms (3 of 555 pings > 100 ms), CPU 75 %, footprint 163 → 174 MB | **Broke, fixed**: project suggestions re-resolved every host's tabs per tab (60 → 1.4 ms per render) |
| Sidebar idle, 500 tabs | — | hang 9 ms, CPU 24 % (the shimmer and spinner of visible rows) | Survived |
| Inbox, 500 agents, 100 updates/s + 100 attention items/s | hang 443–844 ms (120 agents), saturated | hang 220 ms, CPU ~100 % (low load) | **Broke, fixed in part**: the Inbox was O(items²) (each row rebuilt the feed), and every visible row re-rendered on every update (closure inputs defeat SwiftUI's diff; rows now equatable on what they show). Still over 100 ms at this extreme rate |
| Opening a host with 500 tabs | — | one hang of 450–550 ms | **Limit**: 500 panes (terminal + surface + view) are created synchronously. Staging needs per-pane observation of `Workspace.panes` first (staging alone made it worse) |
| Key storm, 20k keys with prediction on | — | ~25 µs per key, flat | Survived |
| Paste of 10 / 50 / 200 MB | 16 ms / 0.32 s / 1.3 s on main, +400 MB at 200 MB; the confirmation's line count took 4 / 14 / 100 s | Over 16 MiB refused in < 50 ms with an alert; line count is one pass | **Broke, fixed** (product decision: refuse, not chunk) |
| Drag of 64 MB of text over a pane | ~45 ms per pointer move | 60 moves < 100 ms (types checked only) | **Broke, fixed** |
| Notification storm from the attention feed | one Task and two XPC calls per item | one request in flight, newest note per pane (`NoteQueue`) | **Broke, fixed** |
| Open and close 10 windows of 30 panes | a closed window's `Workspace` stayed alive (strong captures in pending observations) | panes, views, surfaces and the window model freed | **Leak, fixed** |

### Client connection and mirror (HostKit, client-core, real release daemon)

Timings *loaded* (load average 500–650). Memory, fds and threads are reliable.

| Scenario | Peaks (footprint / threads / fds / main hang) | Outcome |
|---|---|---|
| Flood (`yes`, 32 MB text loop, urandom, CJK + emoji) into the client terminal, flooding pane focused | 75–171 MB / ≤ 12 / ≤ 45 / ≤ 5 ms; other pane echo p95 ≤ 20 ms | Survived. The client takes 13–36 MB/s, and the daemon switches to snapshots when it falls behind. Memory grows by about one scrollback (10 MB), then stays flat |
| History-page and view storm during a flood (~300 views opened and closed, 30 resubscribes, 200–300 pages) | 68–165 MB / ≤ 11 / ≤ 45 / 13–37 ms | Survived |
| Title and bell flood (`ESC]0;…BEL` × 200k in a loop) | before: footprint 17 → 145 MB in 8 s, 5.4 M main-actor tasks; after: 103–115 MB, main hang ≤ 15 ms | **Broke, fixed** (`MainActorCoalescer`, bell at most every 100 ms) |
| 20 hosts, 5 flooding, 60 s | 85 MB / 9 / 74; echo p50 14.5 → 4.5 ms | **Degraded, fixed** (pane streams yield the runtime's workers after each frame) |
| Daemon that admits and drops every connection | before: 3084 dials in 4 s | **Broke, fixed** (backoff resets only after a connection stayed up 5 s) |
| Flapping host (SIGSTOP/CONT, kill and restart ×5), resume after 15 s mid-flood | 46–102 MB, fds flat, live again in 12–110 ms through one snapshot | Survived |
| Closing the last view of a flooding pane | the pane resubscribed and kept streaming forever | **Broke, fixed** (output for a pane without a mirror is dropped) |
| Disconnecting or re-pairing a host while its panes are on screen | the client kept streaming and redialling | **Broke, fixed** (`close()` suspends the client) |
| 200 pane open/close and 100 connect/disconnect rounds | 13.5 → 13.7 MB / 21 fds; `leaks`: 0 | Survived |

### iOS lifecycle (own iPad Pro 13" simulator, iOS 27.0, local release daemon)

`apple/scripts/lifecycle-stress.sh [cycles]` creates the simulator and the daemon, runs `LifecycleStressUITests`, sends a
real memory warning every second (`notifyutil -p dev.unnamed.debug.memorywarning`, a DEBUG hook that calls UIKit's own
memory-warning path), samples the app's footprint every second, lists crash reports, and deletes the simulator.

| Scenario | Peaks | Outcome |
|---|---|---|
| A pane flooding (`while :; do seq 1 100000; done`) among 7 splits: 10 background/foreground cycles, 20 rotations, ~57 memory warnings | footprint 115 MB peak, 102 MB at the end | Survived: the pane takes input and draws its text afterwards (checked on pixels) |
| Same, 40 cycles, 80 rotations, ~149 memory warnings (4 min) | 116 MB peak, 104 MB at the end, flat across cycles | Survived; no crash reports |

Known limits (client): a frozen host shows "connected" for up to ~30 s (iroh's idle timeout). The client terminal parses
13–36 MB/s, so a faster pane is shown through snapshots rather than byte for byte.

### More ways to run

- SwiftUI churn (from `apple/`): `TEST_RUNNER_UNNAMED_MOCK=1 xcodebuild -project App.xcodeproj -scheme App -destination
  'platform=macOS,arch=arm64' test -only-testing:AppTests/AppStressTests`. `TEST_RUNNER_STRESS=1` runs the full sizes
  (500 tabs, 50 projects, 10 s), and `TEST_RUNNER_STRESS_TABS` / `_SECONDS` override them.
- Client and connection: `cargo test -p client-core --test it` (`streams.rs`, `redial.rs`). Then
  `cd apple/Packages/HostKit && UN_STRESS=1 UN_HOSTD_BIN=<release unnamed-hostd> swift test --no-parallel --filter
  'ClientStressTests|ConnectionChurnTests'`; `UN_STRESS=heavy` runs the long variants.
- iOS lifecycle: `UN_HOSTD_BIN=<unnamed-hostd> apple/scripts/lifecycle-stress.sh 40`.

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
