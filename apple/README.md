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
