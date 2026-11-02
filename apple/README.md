# Apple apps

One multiplatform SwiftUI app (iPhone, iPad, Mac; iOS/iPadOS/macOS 26+) over three local packages:

| Path | What |
|---|---|
| `App/Sources` | The app: `Workspace` (one window: layout + live panes), split/tab views, menu commands, iOS key bar, pane backends |
| `App/UITests` | Hardware-keyboard UI tests (splits, zoom, focus, tabs, key bar) |
| `Packages/HostKit` | Data/control layer: hosts, pairing, daemon and plain-SSH connections, `DaemonLayoutStore`, pane backends, lifecycle (docs/APP-ARCHITECTURE.md) |
| `Packages/GudoCore` | The Rust core (UniFFI): `cargo xtask build-xcframework` (docs/APPLE-FFI.md) |
| `Packages/PaneLayout` | Layout model shared in spirit with the daemon: Session → Tab → split tree, `LayoutOp`, `LayoutStore` |
| `Packages/DesignSystem` | Tokens, Liquid Glass components, Ghostty overlays (resize, search, palette, exit bar), agent status, the 463 Ghostty themes; spec in `docs/DESIGN.md` |
| `Packages/DrawingKit` | Drawing without UI: overlay anchor math (Excalidraw scene px ↔ cells ↔ points), PencilKit → Excalidraw `freedraw`, the row tracker that pins daemon anchors in the app's VT |
| `App/Resources/Excalidraw` | Offline Excalidraw build (`scripts/build-excalidraw.sh`, MIT) |
| `App/Sources/Screens` | Hosts, pairing, Inbox, share, links, diff, files, browser, editor: views over the protocols in `App/Sources/Model/ScreenModels.swift` (mock data in `MockData.swift`) |
| `Packages/NotifyKit` | Notification categories and actions, per-kind preferences, local notifications from the attention feed, the action handler, the Notification Service Extension's work (over `PushCrypto`) and the Live Activity attributes; no core, so the extensions stay small |
| `Packages/PushCrypto` | Opens the daemons' sealed pushes (CryptoKit; shared vectors with `crates/push`) |
| `Packages/FilesProviderKit`, `FilesProvider` | Paired hosts as Files app locations (File Provider extension over the daemon's file RPCs); adds locations only with `FILES_PROVIDER = YES` and the shared groups (`Brand.xcconfig`, docs/APP-ARCHITECTURE.md §22) |
| `NotificationService`, `AgentActivityWidget` | iOS app extensions: decrypts pushes; draws the agent-run Live Activity. Push registration needs a team: `PUSH_ENTITLEMENT` in `Brand.xcconfig` (docs/PUSH.md step 9) |
| `Packages/TerminalKit` | libghostty-vt wrapper (`TerminalCore`), Metal renderer + AppKit/UIKit `TerminalView` (`TerminalRenderer`), `LocalPTY` (macOS) |
| `Brand.xcconfig` | Product name and bundle id prefix; nothing else hard-codes them |
| `project.yml` | XcodeGen spec; `App.xcodeproj` is generated and not committed |

Pane I/O goes through `PaneBackend` (HostKit): a login shell on a local PTY on macOS, a local echo on
iOS (the scratch workspace), and for remote hosts `DaemonPaneBackend` / `SshPaneBackend`. The layout
goes through `LayoutStore`: `DaemonLayoutStore` for paired daemons, `LocalLayoutStore` otherwise. The
Hosts button (⇧⌘H) opens the hosts list: just ssh, pairing, ssh_config import.

Before building the app: `cargo xtask build-xcframework` (the core) and `cargo xtask build-hostd-linux`
(the daemons "Install helper" uploads, bundled from `build/hostd/`). For the Mac's own helper
("This Mac" with files, changes, ports, the editor and agents): `cargo xtask build-hostd-macos`; a
build without it gives This Mac plain shells only.

## Setup

Needs Xcode 27 (iOS 27 simulators), Zig 0.17.x and XcodeGen (`brew install zig xcodegen`).

```sh
git submodule update --init vendor/ghostty
apple/scripts/build-libghostty-vt.sh   # -> apple/build/ghostty-vt/lib/ghostty-vt.xcframework
cd apple && xcodegen                   # -> apple/App.xcodeproj
```

Run `xcodegen` again after adding or moving source files.

## Build and run

macOS:

```sh
cd apple
xcodebuild -project App.xcodeproj -scheme App -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/gudo.app
```

iPad simulator (any Apple silicon simulator; the xcframework has no x86_64 simulator slice):

```sh
cd apple
DEVICE=$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$DEVICE"; open -a Simulator
xcodebuild -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/DerivedData build
xcrun simctl install "$DEVICE" build/DerivedData/Build/Products/Debug-iphonesimulator/gudo.app
xcrun simctl launch "$DEVICE" dev.gudo.app
```

Or open `App.xcodeproj` in Xcode and run the `App` scheme on "My Mac" or a simulator.

## Tests

```sh
(cd Packages/PaneLayout && swift test)    # layout ops
(cd Packages/TerminalKit && swift test)   # renderer and key encoding
xcodebuild -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/DerivedData test
```

Notifications: `(cd Packages/NotifyKit && swift test)` (NSE decrypt with the shared vectors,
action handler, local content, prefs). Multiplayer: `MultiplayerSessionTests` and
`MultiplayerIntegrationTests` in HostKit, and `scripts/multiplayer-ui-test.sh <udid>` (iPad: share
sheet, invite + QR, grants, revoke, audit against a local daemon with a guest joined by the `gudo`
CLI).

Developer-workflow screens (Inbox, Files, Diff, Editor, Browser, Links): `AppTests` (the models
against a fake daemon client; `-only-testing:AppTests`), `DaemonWorkspaceTests` in HostKit, and
`scripts/w3-ui-test.sh <udid> [test …]` (iPad against a local daemon on `w3-fixtures.sh`: a git
repository, a `claude` stand-in that drives the daemon's hooks, a `code serve-web` stand-in).
`scripts/w3-daemon.sh start <dir>` starts that daemon by itself; `scripts/w3-screenshots.sh
<udid> <prefix> <dir>` captures the screens on its data.

Files app locations: `(cd Packages/FilesProviderKit && swift test)` (needs `cargo build -p hostd`).
Echo prediction on a daemon pane over a slow link: `scripts/prediction-ui-test.sh <udid>`. A canvas pane
live with a second device: `scripts/canvas-peers-ui-test.sh <udid>`.

Remote hosts: `(cd Packages/HostKit && swift test)` (needs `cargo build -p hostd`),
`scripts/daemon-ui-test.sh <udid>` (iPad UI test against a local daemon that is killed and restarted
mid-test), `scripts/multihost-ui-test.sh <udid>` (two local daemons in one window: switching by click
and ⌘1/⌘2 with no reconnect; one daemon killed while the other stays live), and `RealHostUITests` with `TEST_RUNNER_SSH_TARGET` / `TEST_RUNNER_SSH_KEY`
(docs/APP-ARCHITECTURE.md §7).

The scheme's test action runs the layout tests and the UI tests (iPad: shortcuts, splits, zoom, focus,
tabs; key bar and sticky Ctrl over the software keyboard; divider drag, ⌃⌘ resize and rotation while
split). Set `TEST_RUNNER_HOLD_SECONDS=30` to keep a UI test's final screen up for
`xcrun simctl io "$DEVICE" screenshot`.

`TerminalInputUITests` (iPad) covers long-press/double-tap selection with handles and the edit menu,
copy and paste (⌘V, the edit menu, the key bar's paste key, after a sheet closes), multi-line paste
confirmation, IME marked text (`-demoPreedit`, debug builds) and echo prediction (`-echoLatencyMs`).
Text the test runner puts on the pasteboard is another app's, so every paste path must be one iOS
trusts (the system Paste command or ⌘V): no simulator pasteboard grant is needed, and a test fails if
iOS asks. `MacPasteUITests` needs macOS UI-automation approval (Touch ID), so the Mac paths (paste,
copy, double-click on a URL, drops) are covered in process by `AppKitPasteTests` in TerminalKit.

End-to-end on the Mac without any permission prompt: `scripts/dogfood.sh [scenario]` builds Debug and
runs a scenario (`Dogfood/core.json`: the daily-driver checklist) inside the app, which synthesizes
its own input and writes `report.json` plus PNGs; see `Dogfood/README.md`.

(TerminalBench `--glyphs-png`), `selection-handles-ipad.png`, `ime-preedit-ipad.png`.

## Terminal view


| Area | Where | Notes |
|---|---|---|
| Sprite glyphs | `TerminalRenderer/Sprite/*` | Box drawing, blocks, braille, Powerline (incl. rounded/extended), branch drawing, legacy computing (+ supplement, octants): drawn procedurally like Ghostty so they join at any cell size. `--glyphs-png` in TerminalBench; `-echoFixture glyphs` shows `GlyphFixture` in the iOS app |
| Nerd Font / fallback | `NerdFontConstraint`, `NerdFontTables`, `FontGrid` | Ghostty's per-range icon constraints; icons grow into a following blank cell; emoji and CJK fallback scaled to their cells |
| Decorations | `FrameBuilder` | Underline single/double/curly/dotted/dashed with SGR 58 color, overline, strikethrough, faint, inverse, invisible, SGR 5 blink; cursor blink (DECSCUSR, focus), hollow when unfocused |
| Selection | `TerminalCore/Selection.swift` | Terminal-owned (tracked through scrolling/reflow). Ghostty's selection gesture (double/triple click, ⌥ block, edge auto-scroll). Copy is plain text with soft wraps joined |
| Paste | `TerminalCore/Paste.swift` | `ghostty_terminal_paste`: bracketed when DECSET 2004, else asks before a multi-line paste |
| Mouse | `TerminalCore/Mouse.swift`, `TerminalSurface.mouse/wheel` | libghostty-vt encoder (SGR etc.); ⇧ selects instead; wheel → reports, alt-screen arrows (DECSET 1007), or scrollback |
| IME | `UITextInput` / `NSTextInputClient` | Marked text drawn inline at the cursor, underlined, never sent; candidate window at the cursor |
| Links | OSC 8 | Underlined on hover; tap (iOS) / ⌘-click (Mac) opens after confirmation |
| Echo prediction | `TerminalCore/Prediction/*` | 05 §5.5 with the S6 rule. Backends adopt `PredictionFeed` (hints, acks, RTT); the iOS echo backend simulates latency with `-echoLatencyMs 150` |
| Appearance | `TerminalAppearance` | Font family/size, palette, colors, cursor, selection colors, padding, unfocused-split opacity — configuration, not constants |

iOS gestures: tap focuses (or clicks in mouse mode, or opens a link); double/triple tap and long-press
select with drag handles and the edit menu; one finger scrolls with momentum (arrows on the alt screen,
drags in mouse mode); two fingers send the wheel. iPad pointer: click-drag selects, ⇧-click extends,
hover underlines links and reports motion in any-event mode. Hardware keys: full HID map incl.
function keys, Option-as-Meta per side (Pane menu ▸ Keyboard), ⌘ chords go to the app.

Key bar (`App/Sources/KeyBar*`): profiles as data (Shell, Claude Code, Codex, Vim, Pager) picked from
the foreground program, else the OSC title, with a chip to override; snippets row; composer (multi-line,
⌘↩ or Send pastes it bracketed then Return; default on for agents, per pane); collapses to a 28 pt strip
when a hardware keyboard is attached (`-keyBar.fullWithHardwareKeyboard YES` keeps the full row). All
visuals come from `KeyBarStyle`.

Backend hooks (additive, in `App/Sources/Panes/PaneBackend.swift`): `PredictionFeed` and
`ForegroundProgramReporting` (picks the key bar profile; the title stands in until the daemon reports
the program).

Bench (`swift run -c release TerminalBench`, 112×35 at 2x, M-series Mac): typing 0.03 ms/frame build;
sprite screen full redraw 0.61 ms avg / 0.66 ms p99; selection drag (whole viewport dirty every frame)
0.60 ms avg / 0.67 ms p99; GPU ≤ 0.3 ms avg. All within the ~2 ms budget.


The app side of docs/DAEMON.md §7.11, on panes of a daemon (local and plain-SSH panes have none).

| | |
|---|---|
| Draw mode | ⌃⌘D (Pane menu ▸ Draw on Pane, command palette), a Pencil stroke on the pane (iPad; the stroke becomes the drawing's first, a Pencil tap opens it empty), or a two-finger long press. ⇧⌘D stays Ghostty's Split Down. One pane draws (or writes) at a time, across windows: another pane's empty overlay closes, one holding a drawing asks (Place It / Discard It / Keep Drawing There; `DrawingKit.DrawExclusivity`). A transparent overlay anchored to the touched row (the cursor row from the keyboard) holds one Excalidraw scene: shapes, arrows and text from the bundled editor, Pen ink from PencilKit converted to `freedraw` elements (`DrawingKit.Freedraw`). It scrolls with the output (wheel / trackpad scroll, or two fingers on iPad and iPhone, scroll the terminal) and syncs live (`excalidrawPut`, pushes reconciled with Excalidraw's rule, Pencil points streamed with `inkLive` every 16 ms) |
| Tools | One choice for every input (`DrawTool`, `DrawRouting`): Select, Pen, Rectangle, Ellipse, Arrow, Text, Eraser in our glass toolbar at the bottom of the pane (folded into one menu on narrow panes); Excalidraw's own chrome is hidden (`index.html`), so nothing sits over the first rows. One finger and the Pencil draw with the chosen tool, which stays picked after each shape (Excalidraw `locked`); the editor's keyboard letters and its switch back to selection after text update the toolbar (`tool` message). Pen inks through PencilKit for finger and Pencil; with Select the Pencil still inks. Excalidraw's pen mode (fingers stop drawing once a Pencil touched the page) is forced off. Pencil double tap: eraser and back |
| Pencil hand-off | `DrawingKit.InkHandoff`: a lifted stroke is converted and sent; the page holds elements until its scene has loaded (`loaded`; earlier ones were replaced by the scene load and vanished), draws them, and confirms (`inkApplied`); PencilKit's stroke is removed only after that and only between strokes (replacing the drawing mid-stroke cancelled the next stroke); unconfirmed elements are resent after 1 s (the page de-duplicates by id); Done waits for every stroke. Each step logs `ink:` lines to the `drawing` category (`log stream --predicate 'category == "drawing"'`) |
| Actions | Draw mode is modal and holds the keyboard focus (`DrawKeySink`, a hidden text view on iOS; the overlay view on the Mac): Esc / ⌘. cancel, ⌘↩ keeps, ⇧⌘↩ sends, the tool letters pick tools, nothing reaches the shell (an Esc used to: the overlay stayed open and the shell's bell flashed the pane white; the key bar and software keyboard are away while drawing). Cancel deletes a new drawing and reverts a reopened one (`canvas.revert`: the loaded elements put back with higher versions). The primary button names where the drawing goes (`DrawingActions.swift`): **Send to Claude Code / Codex** (⇧⌘↩) when the pane or another pane in its tab runs an agent, with a chevron menu of every other destination; otherwise a **Send To…** menu: agent panes on any host the window shows (other hosts get the PNG uploaded), Start Claude Code / Codex with This Drawing (a split launched with `launchAgentPane`; the image is attached once the agent reports idle), Copy Image, Share… (iOS share sheet) / Save Image… and Share… (Mac), Keep in Terminal. Keep (⌘↩) only places it. Every choice also keeps the drawing in the output. The first draw mode shows a one-line hint above the toolbar saying what drawings are for (`drawingHintSeen` once one is finished). After it a notice says what happened ("Sent to Claude Code · in the prompt as an image · also kept here", "Image copied", "Kept in terminal · tap it to send, copy or edit" with Send to Claude/Codex when an agent runs) and the placement is outlined for a moment |
| Write (iPad) | The pencil-and-scribble button in the toolbar, or the Pencil held still on the terminal for 0.5 s. Handwriting anywhere over the pane goes through Scribble (`UIIndirectScribbleInteraction`) into a hidden field and shows live at the prompt as marked text (`TerminalSurface.preedit`); a hardware keyboard edits the same draft. Return or Send types it as one line and presses Return; Cancel or Esc drops it. Nothing reaches the shell before that (`WriteController`; the terminal's own Scribble stays off, `TerminalView.allowsHandwriting = false`) |
| Done | The covered cells (`OverlayGeometry.cells(covering:)`) are exported from the editor at device scale (`exportToBlob`, dark theme applied to the pixels because WebKit has no canvas `filter`) and placed with `placePng(replace:)`; the device's PNG shows at once, the `Placed` push follows |
| Placements | Drawn by the Metal renderer as image quads above the text (Ghostty's `image` pipeline, `TerminalSurface.inlineImages`), pinned to rows with libghostty-vt tracked refs (`Terminal+Pins`), resolved from the daemon's `(at_seq, from_bottom)` anchors by `DrawingKit.RowTracker`; blobs are downloaded once per hash. Tap/click one for its menu: the same destinations as the overlay (Send to…, Start Claude Code / Codex with This Drawing, Copy Image, Share… / Save Image…) plus Edit Drawing (reopens its scene in place) and Delete Drawing; viewers get Copy and Share only. Placements whose row is gone (detached by `clear` or a restart, or evicted from this device's scrollback ring) are not drawn and go to the loose tray, a glass chip top-right of the pane: Place at Cursor, Send to Claude/Codex, Remove |
| Canvas pane | Pane menu ▸ New Canvas Split (⌃⇧⌘D) splits with `PaneLaunch.canvas`; canvas leaves (`ArtifactEvent.canvases`) show the full editor on the terminal background, live on every device |
| Paste / drop | Images and `.excalidraw` files → `importToPane` (placed at the cursor row); on the Mac ⌥-drop of an image onto an agent pane sends it to the agent |
| Viewers | Overlays open read-only (Excalidraw view mode); draw mode, paste and drop are off (`MultiplayerSession.isViewOnly`) |
| Peers | Other devices' live Pencil strokes show over the pane in their presence colour and fade when the stroke lands in the scene |

Tests: `(cd Packages/DrawingKit && swift test)` (anchor math, freedraw conversion with real
`PKStroke`s, anchor ↔ pin through later and in-flight output); TerminalKit `PinTests`,
`InlineImageTests` (pixels over the right cells, scrolling with the pinned row, +0.04 ms/frame for
8 placements); `DrawingUITests` (iPad, local daemon: ⌃⌘D, the toolbar clear of the first row, a rectangle
through the editor, Done → notice → placement visible, still there after relaunch; one finger draws
two rectangles and Pen ink with the chosen tool; one pane draws at a time (quiet close, then the
question); Write previews at the prompt and sends only on Send; Esc leaves draw mode with no key bar up and no flash of the pane, sampled from screenshots while it closes; the Send To… menu, Copy Image, and a placement's tap menu with Edit and Delete Drawing). AppTests `DrawingMenuTests` (what each menu lists). `DrawingKit` `DrawInputTests`
(routing, hand-off, exclusivity, loose tray, handwriting) and AppTests `WriteControllerTests`
(the commit path). Debug: `-drawingDemo overlay|done|scroll|canvas`
"Rect" button the UI test uses.

## Design review

Every screen opens directly with mock data: `-screen <name> -mock` (names in `docs/DESIGN.md`,
e.g. `splits`, `inbox`, `palette`, `diff`). Screenshots in light and dark:

```sh
scripts/mac-screenshots.sh build/DerivedData/Build/Products/Debug/gudo.app out  # Mac, works while locked
```

The Mac script uses the Debug-only `-snapshot <png>` switch (the app draws its own window; glass and
the vibrant sidebar do not draw that way and show white). UI tests that paste need the
simulator's paste permission: `xcrun simctl privacy "$DEVICE" grant pasteboard dev.gudo.app`.

## Shortcuts (Ghostty defaults)

| | |
|---|---|
| ⌘D / ⇧⌘D | Split right / down |
| ⌘W | Close pane (its tab when it is the last pane; the window on macOS when it is the last tab) |
| ⇧⌘↩ | Zoom pane |
| ⌥⌘ arrows | Focus pane in that direction |
| ⌃⌘ arrows | Move the divider |
| ⌘T / ⌥⌘T | New tab on the current host / on a host you pick |
| ⇧⌘[ / ⇧⌘], ⌘1…⌘8, ⌘9 | Previous / next tab, tab N, last tab — across every host in the window (the sidebar's numbering) |
| ⌘P | Go to Tab… (any host; matches name, context line, host) |

They are SwiftUI commands: menu-bar items on macOS, and on iPadOS the menu bar and the ⌘-hold overlay.
Split / zoom / close are also in the pane menu in the toolbar, for touch. In the simulator, XCUITest's
synthesized ⇧⌘↩ never reaches the app (the UI test zooms through the pane menu); check zoom on a real
hardware keyboard.
