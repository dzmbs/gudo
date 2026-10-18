# Dogfood scenarios

End-to-end checks of real builds that need no permissions: no Accessibility, Input Monitoring,
Screen Recording or UI-automation approval.

```sh
apple/scripts/dogfood.sh                 # build Debug, run core.json, print the summary
apple/scripts/dogfood.sh core --no-build --case splits --out /tmp/df
```

Output: `report.json` (per case and step: pass/fail, ms, detail, metrics), PNGs, and `app.log` in the
out directory (default `apple/build/dogfood/<timestamp>`). Exit status 0 passed, 1 a case failed,
2 bad scenario, 3 hang (main thread stuck `hangSeconds`) or time limit (`timeoutSeconds`).

## How it works (macOS)

`App/Sources/Debug/` (compiled only in Debug: `#if DEBUG && os(macOS)`), started by the launch
arguments `-dogfood <scenario.json> -dogfoodOut <dir> [-dogfoodCase <name filter>]`:

- **Input** is real `NSEvent`s. Keys are posted to the app's own queue (`NSApp.postEvent`) and
  dispatched by AppKit: key equivalents and the menu bar for ⌘ shortcuts, then the first
  responder (`TerminalView.keyDown` → `interpretKeyEvents` → key encoder → PTY). Mouse events go to
  `NSWindow.sendEvent` (a posted mouse event's location is re-derived from screen coordinates and
  drifts when the display is asleep). A marker event posted after each batch tells the runner when
  AppKit has handled it.
- **Inactive app** (screen locked, another app in front): AppKit has no key window, drops key
  events and SwiftUI disables commands that read a focused scene value. The runner then delivers
  keys as AppKit would to the key window (window key equivalents, enabled menu items, the Edit
  actions on the first responder, else the first responder's `keyDown`), mouse events through
  the window's hit test, and a ⌘ shortcut whose menu item is disabled runs the same
  `WorkspaceAction` the item would. The report's `environment` and each shortcut step's detail
  ("via action (app inactive)") say when this happened.
- **Screen text** is `Terminal.visibleText()` of the pane; **processes** are the pane shell's tree
  (`PTY.pid` + `sysctl(KERN_PROC_ALL)`); the PTY window size is read with `TIOCGWINSZ`.
- **Screenshots**: `cacheDisplay` draws the SwiftUI chrome; each visible pane is rendered again by
  its renderer into an `MTLTexture`, read back and composited at its frame. The step fails if a
  pane has no ink (blank). Glass materials (sidebar, toolbar buttons) do not draw through
  `cacheDisplay` and come out flat white: judge chrome from a real screenshot.
- **Latency**: `type` with `"latency": true` measures keystroke → echo in the terminal state
  (cursor or text changed) and → the next rendered frame. With the window occluded (screen
  locked) the display link does not run, so only the echo time is reported (`framesMissed`).
- **Exit**: every shell gets SIGHUP; the report lists processes still alive after 3 s
  (`leakedProcesses`), which are then killed. A watchdog thread aborts on a main-thread hang.

`dogfood.sh` runs the user's own login zsh and config, but points `ZDOTDIR` at a wrapper that
switches `HISTFILE` to the out directory, so runs neither pollute nor read the real history
(`--real-history` turns this off). Paste steps overwrite the general pasteboard.

## Scenario format

```json
{ "name": "core", "window": { "width": 1100, "height": 700 }, "hangSeconds": 15, "timeoutSeconds": 600,
  "cases": [ { "name": "ctrl-c", "fresh": false, "steps": [ { "do": "type", "text": "sleep 100\n" } ] } ] }
```

A failed case stops at its failing step, saves `FAIL-<case>.png`, and the next case starts in a
fresh tab (as does any case with `"fresh": true`). `pane` is an index into the active tab's panes
(tree order); it defaults to the focused pane. `${OUT}` in text expands to the out directory.

| Step | Fields |
|---|---|
| `type` | `text` (`\n` is Return), `latency` |
| `key` / `shortcut` | `key` / `keys`: `ctrl+c`, `cmd+shift+d`, `cmd+opt+left`, `escape`, `space`, `f1`…; `repeat` |
| `paste` | `text`: put on the pasteboard, then ⌘V |
| `waitText` | `text` or `regex` (multi-line anchors), `absent`, `timeout`, `pane` |
| `waitIdle` | `quiet` (s the screen must not change), `timeout`, `pane` |
| `rememberScreen` / `waitScreenChanged` | `as` / `from` |
| `waitProcess` | `name`, `state`: `running` (default), `stopped`, `exists`, `gone`; `timeout`, `pane` |
| `capturePids` / `waitPidsGone` | `as` / `of`: the pane's shell and descendants |
| `assert` | one of `panes`, `tabs`, `focusIs`, `focusIsNot`, `focusIndex`, `tabTitle`, `pasteboard`, `firstResponderIsFocusedPane`, `bracketedPaste`, `altScreen`, `ptySizeMatchesGrid`; polled for `timeout` (2 s) |
| `remember` | `focus`: label for the focused pane |
| `click` / `selectText` / `scroll` | `pane`; `text` (drag across its last occurrence); `lines` |
| `resize` / `resizeLoop` | `width`, `height` / `sizes`, `count`, `intervalMs` |
| `screenshot` | `name`, `expectInk` (default true) |
| `sleep` | `seconds` |

## iPad simulator

`App/UITests/DogfoodUITests.swift` runs the XCUITest-expressible steps of a scenario (type, key,
shortcut, paste, waitText via each pane's accessibility value, `assert panes`, sleep, screenshot)
and skips the macOS-only ones. iOS panes use the local echo backend, hence `ios-smoke.json`:

```sh
TEST_RUNNER_DOGFOOD_SCENARIO=$PWD/Dogfood/ios-smoke.json TEST_RUNNER_DOGFOOD_OUT=/tmp/df-ios \
  xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath build/DerivedData -only-testing:AppUITests/DogfoodUITests -collect-test-diagnostics never
```
