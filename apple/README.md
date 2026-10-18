# Apple apps

One multiplatform SwiftUI app (iPhone, iPad, Mac; iOS/iPadOS/macOS 26+) over three local packages:

| Path | What |
|---|---|
| `App/Sources` | The app: `Workspace` (one window: layout + live panes), split/tab views, menu commands, iOS key bar, pane backends |
| `App/UITests` | Hardware-keyboard UI tests (splits, zoom, focus, tabs, key bar) |
| `Packages/PaneLayout` | Layout model shared in spirit with the daemon: Session → Tab → split tree, `LayoutOp`, `LayoutStore` |
| `Packages/TerminalKit` | libghostty-vt wrapper (`TerminalCore`), Metal renderer + AppKit/UIKit `TerminalView` (`TerminalRenderer`), `LocalPTY` (macOS) |
| `Brand.xcconfig` | Product name and bundle id prefix; nothing else hard-codes them |
| `project.yml` | XcodeGen spec; `App.xcodeproj` is generated and not committed |

Pane I/O goes through `PaneBackend`: a login shell on a local PTY on macOS, and a local echo on iOS until
the daemon connection exists. The layout goes through `LayoutStore` (`LocalLayoutStore` for now).

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

The scheme's test action runs the layout tests and the UI tests (iPad: shortcuts, splits, zoom, focus,
tabs; key bar and sticky Ctrl over the software keyboard; divider drag, ⌃⌘ resize and rotation while
split). Set `TEST_RUNNER_HOLD_SECONDS=30` to keep a UI test's final screen up for
`xcrun simctl io "$DEVICE" screenshot`.

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

Backend hooks (additive, in `App/Sources/Panes/PaneBackend.swift`): `PredictionFeed` and
`ForegroundProgramReporting` (picks the key bar profile; the title stands in until the daemon reports
the program).

Bench (`swift run -c release TerminalBench`, 112×35 at 2x, M-series Mac): typing 0.10 ms/frame build;
sprite screen full redraw 1.08 ms avg / 1.45 ms p99; selection drag (whole viewport dirty every frame)
2.33 ms avg / 5.47 ms p99.

## Shortcuts (Ghostty defaults)

| | |
|---|---|
| ⌘D / ⇧⌘D | Split right / down |
| ⌘W | Close pane (its tab when it is the last pane; the window on macOS when it is the last tab) |
| ⇧⌘↩ | Zoom pane |
| ⌥⌘ arrows | Focus pane in that direction |
| ⌃⌘ arrows | Move the divider |
| ⌘T | New tab |
| ⇧⌘[ / ⇧⌘], ⌘1…⌘8, ⌘9 | Previous / next tab, tab N, last tab |

They are SwiftUI commands: menu-bar items on macOS, and on iPadOS the menu bar and the ⌘-hold overlay.
Split / zoom / close are also in the pane menu in the toolbar, for touch. In the simulator, XCUITest's
synthesized ⇧⌘↩ never reaches the app (the UI test zooms through the pane menu); check zoom on a real
hardware keyboard.
