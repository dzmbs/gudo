# Apple apps

One multiplatform SwiftUI app (iPhone, iPad, Mac; iOS/iPadOS/macOS 26+) over three local packages:

| Path | What |
|---|---|
| `App/Sources` | The app: `Workspace` (one window: layout + live panes), split/tab views, menu commands, iOS key bar, pane backends |
| `App/UITests` | Hardware-keyboard UI tests (splits, zoom, focus, tabs, key bar) |
| `Packages/HostKit` | Data/control layer: hosts, pairing, daemon and plain-SSH connections, `DaemonLayoutStore`, pane backends, lifecycle (docs/APP-ARCHITECTURE.md) |
| `Packages/UnnamedCore` | The Rust core (UniFFI): `cargo xtask build-xcframework` (docs/APPLE-FFI.md) |
| `Packages/PaneLayout` | Layout model shared in spirit with the daemon: Session → Tab → split tree, `LayoutOp`, `LayoutStore` |
| `Packages/DesignSystem` | Tokens, Liquid Glass components, Ghostty overlays (resize, search, palette, exit bar), agent status, the 463 Ghostty themes; spec in `docs/DESIGN.md` |
| `App/Sources/Screens` | Hosts, pairing, Inbox, share, links, diff, files, browser, editor: views over the protocols in `App/Sources/Model/ScreenModels.swift` (mock data in `MockData.swift`) |
| `Packages/NotifyKit` | Notification categories and actions, per-kind preferences, local notifications from the attention feed, the action handler, the Notification Service Extension's work (over `PushCrypto`) and the Live Activity attributes; no core, so the extensions stay small |
| `Packages/PushCrypto` | Opens the daemons' sealed pushes (CryptoKit; shared vectors with `crates/push`) |
| `NotificationService`, `AgentActivityWidget` | iOS app extensions: decrypts pushes; draws the agent-run Live Activity. Push registration needs a team: `PUSH_ENTITLEMENT` in `Brand.xcconfig` (docs/PUSH.md step 9) |
| `Packages/TerminalKit` | libghostty-vt wrapper (`TerminalCore`), Metal renderer + AppKit/UIKit `TerminalView` (`TerminalRenderer`), `LocalPTY` (macOS) |
| `Brand.xcconfig` | Product name and bundle id prefix; nothing else hard-codes them |
| `project.yml` | XcodeGen spec; `App.xcodeproj` is generated and not committed |

Pane I/O goes through `PaneBackend` (HostKit): a login shell on a local PTY on macOS, a local echo on
iOS (the scratch workspace), and for remote hosts `DaemonPaneBackend` / `SshPaneBackend`. The layout
goes through `LayoutStore`: `DaemonLayoutStore` for paired daemons, `LocalLayoutStore` otherwise. The
Hosts button (⇧⌘H) opens the hosts list: just ssh, pairing, ssh_config import.

Before building the app: `cargo xtask build-xcframework` (the core) and `cargo xtask build-hostd-linux`
(the daemons "Install helper" uploads, bundled from `build/hostd/`).

## Setup

Needs Xcode 27 (iOS 27 simulators), Zig 0.16.x and XcodeGen (`brew install zig@0.16 xcodegen`).

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
open build/DerivedData/Build/Products/Debug/unnamed.app
```

iPad simulator (any Apple silicon simulator; the xcframework has no x86_64 simulator slice):

```sh
cd apple
DEVICE=$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$DEVICE"; open -a Simulator
xcodebuild -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/DerivedData build
xcrun simctl install "$DEVICE" build/DerivedData/Build/Products/Debug-iphonesimulator/unnamed.app
xcrun simctl launch "$DEVICE" dev.unnamed.app
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
sheet, invite + QR, grants, revoke, audit against a local daemon with a guest joined by the `un`
CLI).

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
multi-line paste confirmation, IME marked text (`-demoPreedit`, debug builds) and echo prediction
(`-echoLatencyMs`). Paste reads the pasteboard, so grant it once per simulator:
`xcrun simctl privacy "$DEVICE" grant pasteboard dev.unnamed.app` (a denied prompt is remembered and
paste then silently reads nothing). `MacPasteUITests` needs macOS UI-automation approval (Touch ID), so
the Mac paste path is also covered in process by `AppKitPasteTests` in TerminalKit.

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

## Design review

Every screen opens directly with mock data: `-screen <name> -mock` (names in `docs/DESIGN.md`,
e.g. `splits`, `inbox`, `palette`, `diff`). Screenshots in light and dark:

```sh
scripts/mac-screenshots.sh build/DerivedData/Build/Products/Debug/unnamed.app out  # Mac, works while locked
```

The Mac script uses the Debug-only `-snapshot <png>` switch (the app draws its own window; glass and
the vibrant sidebar do not draw that way and show white). UI tests that paste need the
simulator's paste permission: `xcrun simctl privacy "$DEVICE" grant pasteboard dev.unnamed.app`.

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
