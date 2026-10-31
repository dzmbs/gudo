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

### App, input, lifecycle and connection scenarios

See the subsections added from the SwiftUI/iOS-lifecycle and client-connection runs below.

### Not tested (App and renderer)

- On-device runs (iPhone/iPad hardware, real jetsam limits, ProMotion pacing). Everything ran in-process or in simulators.
- The display-link path end to end with real windows on the Mac (the Mac app is never launched in the foreground). The render
  budget is tested as a policy and through headless surfaces.
- GPU stalls and loss (sleep/wake, display unplug, eGPU) and `nextDrawable` blocking up to 1 s when no drawable is free.
- Keystroke-to-photon latency under load (needs client instrumentation; see docs/PERFORMANCE.md).
- Leaving the CPU copy of the atlas out (it would halve atlas memory), and `maximumDrawableCount = 2` for 6K panes.
