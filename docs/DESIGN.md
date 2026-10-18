# Design

The Apple apps (iPhone, iPad, Mac; OS 26+) look like Ghostty's macOS app around the terminal and
system: its tokens, its rules, every screen, and for each element the reference it copies. Code:
`apple/Packages/DesignSystem` (tokens and components) and `apple/App/Sources` (screens).

Sources, and what may be taken from each:

| Reference | Where | Licence | Taken |
|---|---|---|---|
| Ghostty macOS app | `reference/ghostty/macos/Sources` | MIT | Swift UI code ported 1:1 with attribution (`apple/THIRD_PARTY_NOTICES.md`); config names and defaults; default palette; bundled theme list. Not the name or icon. |

## Principles

1. **The terminal is the product.** Chrome recedes: monochrome, thin, on the terminal's own
   background wherever it touches the grid. Nothing decorative is drawn over or next to it.
2. **Color is for state.** Chrome uses system label and fill colors. Hue appears only for agent
   and connection state, git status, focus and the single primary action per screen.
3. **Native first.** System controls, list styles, sheets, menus, context menus, swipe actions,
   searchable lists and Liquid Glass. Custom drawing only where the platform has no equivalent
   (dividers, tab strip, overlays on the grid), and then copied from Ghostty.
4. **Words, not spinners.** Every waiting state says what is happening and offers the next step
5. **Never blank.** Lost connections dim the last frame; empty lists name the next action.

## Tokens

All values live in `DesignSystem/Tokens`. Chrome text is SF Pro through text styles (Dynamic
Type on iOS); literals (paths, commands, hosts, code) are SF Mono; only the terminal grid uses
JetBrains Mono (bundled, OFL, Ghostty's default face).

### Color

Light/dark pairs; dark values are Ghostty's palette entries, light values are the same hues
darkened to ≥ 4.5:1 on white.

| Token | Light | Dark | Use | Source |
|---|---|---|---|---|
| `accent` | `#2F6DB5` | `#7AA6DA` | focus, selection, one primary action | Ghostty palette 12 |
| `working` | `#A87A00` | `#F0C674` | agent working | palette 3 |
| `blocked` | `#C8323A` | `#E8686C` | needs you, count badges | palette 9 |
| `done` | `#4E7A12` | `#B5BD68` | done, git added, connected | palette 2 |
| `error` | `#B83A3A` | `#CC6666` | failed, git deleted, unreachable | palette 1 |
| `info` | `#3F6E99` | `#81A2BE` | informational | palette 4 |
| `bell` | `#FFCC00` 50 % | same | bell border | Ghostty `BellBorderOverlay` |
| terminal background | `#282C34` | same | grid, pane headers, tab strip, iPhone top bar | Ghostty `background` |
| split divider | background × 0.6 brightness (`#181A1F`) | same | 1 pt dividers, header rules | Ghostty `splitDividerColor` (darken 40 %) |
| unfocused dim | background at 30 % | same | over unfocused panes | Ghostty `unfocused-split-opacity` 0.7 |

The asset catalog's `AccentColor` mirrors `accent`; `LaunchBackground` is the terminal
background.

### Type scale

| Token | Style | Use |
|---|---|---|
| `title` | title3 semibold | sheet/screen titles that are not navigation titles |
| `rowTitle` / `rowTitleEmphasis` | body / body medium | list rows; selected tab |
| `rowSubtitle` | subheadline | second lines |
| `section` | subheadline semibold, sentence case | section headers (never uppercase) |
| `meta` | caption, monospaced digits | ages, counts, ⌘N hints |
| `badge` | caption2 medium | pills (Ghostty palette badge) |
| `literal` / `literalSmall` | SF Mono callout / caption | paths, commands, hosts, code |
| `paletteQuery` | 20 pt light | command palette field (Ghostty) |
| `keyCap` | 12 pt medium rounded | shortcut key caps (Ghostty `KeyCap`) |
| `overlay` | callout, monospaced digits | cols × rows, exit bar |

### Spacing, sizes, radii

Grid: 4 pt with a 2 pt half step: `2 4 8 12 16 20 24 32`. Leading slots in rows are 22 pt so
titles align to one column.

| Size | Value | Source |
|---|---|---|
| Divider visible / hit (pointer) / hit (touch) | 1 / +6 / 20 pt | Ghostty `SplitView` (1 + 6); touch is ours |
| Tab strip / tab | 34 / 28 pt (selected pill inset 3) | macOS 26 titlebar tabs, Ghostty native tabs |
| Command palette width | ≤ 560 pt | Ghostty 500, plus room for shortcuts |
| Key bar row | 44 iPhone / 52 iPad, keys 34 / 40, hardware strip 28 | 04-mobile-ux C5, keyboard key height |
| Window padding | 2 pt, balanced | Ghostty `window-padding-x/y` = 2, `window-padding-balance` |

| Radius | Value | Source |
|---|---|---|
| `chip` | 4 | resize overlay, key caps (Ghostty) |
| `field` | 6 | search field, bar buttons (Ghostty) |
| `control` | 8 | row highlights, inline code blocks |
| tab pill | 7 | Ghostty/AppKit selected tab |
| `panel` | 16 (palette 20, search 14, reconnect 22) | floating glass panels; glass reads smaller than an opaque edge |

### Materials (Liquid Glass) rules

1. Glass is the navigation layer floating over content: toolbars, the floating tab bar on
   iPhone, the command palette, the search bar, toasts, the reconnect card, key bar keys. Content
   is never glass: the grid, rows, code, diffs and file lists are opaque.
2. Never glass on glass. Neighbouring glass controls share a `GlassEffectContainer` (toolbar
   groups do this already).
3. Tint glass only to carry state: the prominent primary action (`.glassProminent`) and a latched
   key-bar modifier. Never for decoration.
4. Where chrome touches the terminal (tab strip, pane headers, iPhone top bar, the toolbar band
   when the window and terminal agree on dark/light) it is painted with the terminal background,
   seamless like Ghostty's transparent titlebar. When they disagree (light mode, dark theme) the
   toolbar band keeps the window background so the title and status bar stay legible.
5. The iPad sidebar is opaque `secondarySystemBackground`: the floating glass sidebar sampled the
   dark terminal and turned grey in light mode.

### Motion

| Token | Curve | Use | Source |
|---|---|---|---|
| `snappy` | snappy 0.25 s | selection, rows, tab switch | — |
| `overlay` | easeOut 0.2 s | overlays in/out, search corner snap | Ghostty search bar |
| `indicator` | spring 0.3 / 0.8 | badges, status glyphs | Ghostty `KeyStateIndicator` |
| `bell` | easeInOut 0.3 s | bell border | Ghostty |
| `panel` | smooth 0.35 s | panels, tab style switch | — |
| resize overlay | visible 750 ms after the last change | cols × rows | Ghostty `resize-overlay-duration` |
| toast | 2.4 s | | — |

Only the working spinner loops; under Reduce Motion it stands still (and still reads as
"working"), and the secure-input gradient stops.

### Haptics (iPhone/iPad, touch only)

| Token | Feedback | When |
|---|---|---|
| `select` | selection | tab/pane change by touch |
| `structure` | light impact | split, close, divider snap |
| `success` | success | approve, pair, toast success |
| `attention` | warning | deny; an agent becomes blocked while visible |
| `failure` | error | connection failed, toast failure |

## Components (DesignSystem)

| Component | File | Notes / reference |
|---|---|---|
| `ListRow`, `SectionTitle`, `EmptyState` | `Components/Rows.swift` | dense rows with fixed leading slot; `ContentUnavailableView` |
| `BarButtonStyle` (`.bar`), `RowButtonStyle` (`.row`) | `Components/Glass.swift` | Ghostty `SearchButtonStyle` hover/press fills; iPad pointer highlight |
| `floatingPanel`, `floatingCapsule`, `phoneDetents` | `Components/Glass.swift`, `Sheets.swift` | glass rules above; bottom sheets only on iPhone |
| `ShortcutLabel`, `KeyCap` | `Components/KeyCaps.swift` | Ghostty `ShortcutSymbolsView`, `KeyCap` |
| `Toast`, `ToastCenter`, `toastHost` | `Components/Toast.swift` | one at a time, glass capsule, top |
| `PresenceAvatar`, `PresenceStack`, `Participant` | `Components/Presence.swift` | initials on ANSI hues, typing ring, +N |
| `KeyBarLook` | `Components/KeyBarLook.swift` | the key bar's look (app passes it as `KeyBarStyle.designSystem`) |
| `ResizeOverlay`, `ProcessExitedBar`, `BellBorder`, `UnfocusedDim`, `SecureInputBadge`, `URLHoverBanner` | `Overlays/TerminalOverlays.swift` | Ghostty `SurfaceView.swift` 1:1 |
| `TerminalSearchBar` | `Overlays/SearchBar.swift` | Ghostty `SurfaceSearchOverlay` 1:1 (glass instead of opaque) |
| `CommandPalette`, `PaletteCommand`, `FuzzyMatch` | `Overlays/CommandPalette.swift` | Ghostty `CommandPaletteView` + Raycast sections |
| `TerminalTheme`, `ThemeCatalog` (463 themes), `TerminalPreferences` | `Terminal/` | Ghostty theme files and config keys |

## Brand

The product name stays a placeholder (`apple/Brand.xcconfig`, `crates/brand`); every visual brand
decision is independent of it, so a rename is one line.

- **Accent**: Ghostty's bright blue, see Color.
- **App icon**: `apple/App/Resources/AppIcon.icon` (Icon Composer, layered Liquid Glass). A
  graphite field (#333840 → #16181D), a white glass window frame split into three panes (the
  product: one session, split), and a solid block cursor in the accent in the first pane, its own
- **Launch screen**: the terminal background (`LaunchBackground`), so launch never flashes white
  and the first terminal frame lands on the same color.

## Screens

Each screen can be opened directly for review: `-screen <name> -mock` (see Screenshots).

### Window and title bar (Mac)

- Sidebar layout: a standard `NavigationSplitView`; the toolbar carries the tab title (OSC 0/2
  title, else the focused pane's program or directory) with a subtitle ("Local · 3 panes"), then
  presence avatars, Find, the pane menu, the command palette and the tab-placement toggle.
- Tabs-on-top layout (Ghostty): the window title is the focused pane's directory with its folder
  as proxy icon (`navigationDocument`); the window takes the terminal's light/dark (Ghostty
  `window-theme = auto`), the toolbar background is the terminal background.
- Switching to vertical tabs always shows the sidebar (`columnVisibility = .all`); covered by
  `testSidebarAppearsAfterSwitchingFromTabStrip` and the `toggle` screenshot fixture.


- Inbox (count badge, red only when something needs you) and Hosts at the top.
- Section "This iPad / This Mac" with the connection dot. One row per tab: tab number (tertiary,
  monospaced), title (medium when selected) with the most urgent agent glyph, the directory in SF
  Mono underneath (or "3 panes"), ⌘N on the Mac. Selection is a 9 % fill with radius 10, never the
  accent. Drag to reorder; context menu Rename / Close.
- Section "Agents": every pane whose program reports status, across tabs: glyph, program, tab
- Footer: connection state and Settings.

### Tab strip (horizontal tabs) — Ghostty native tabs

Equal-width tabs across the row; centered title with the agent glyph; ⌘N right-aligned; close
button on hover at the leading edge; 1 pt separators between unselected tabs (none beside the
selected one); the selected tab a slightly lighter rounded pill (primary 11 %, radius 7, 0.5 pt
hairline), moved with `matchedGeometryEffect`; + at the end. On iPad the pane menu, palette and
placement toggle follow at the row's end. The strip sits on the terminal background with a
divider-colored bottom rule. Drag tabs to reorder.

### Splits, panes, overlays — Ghostty 1:1

- Dividers 1 pt in the split-divider color, 7 pt hit area with resize pointer on Mac, 20 pt with
  pointer highlight on iPad; double-click/tap equalizes; adjustable for VoiceOver ("Horizontal
  split divider", ±2.5 %). Split sizes snap to whole cells (main's `SplitSnapping`).
- No focus ring. Unfocused panes are dimmed with the background at 1 − `unfocused-split-opacity`.
- Pane header (only in splits, 24 pt, on the terminal background): status glyph, program, state
  word in its color, and the pane menu (… on hover/focus). Tap focuses.
- Overlays on the grid: cols × rows centered while resizing (hidden while the software keyboard
  moves, so it only answers user resizes); process-exited bar at the bottom (red 50 % on failure,
  hides under the pointer); secure-input badge top-right; bell border; hovered URL bottom-left;
  scrollback search bar top-right (draggable to any corner).

### Key bar (iPad, iPhone)

Keys read as part of the iOS 26 keyboard: no strip behind them, glass rounded rects at the
keyboard's key height and radius, SF Pro labels at its size, wider gaps between groups (esc tab ·
ctrl · arrows · symbols · profile), the latched Ctrl as prominent glass. Always dark, like the
terminal's keyboard. With a hardware keyboard, the 28 pt strip (main's behaviour). Profiles,
composer and snippets are main's (`App/Sources/KeyBar`), skinned through `KeyBarStyle`.

### iPhone

A Liquid Glass tab bar: Terminal · Inbox (badge) · Hosts; it minimizes on scroll. The terminal tab
is one pane full screen under a 36 pt bar on the terminal background: connection dot, tab title
with ▾ (switcher menu with tab count), pane switcher when the tab is split, palette, new tab.
Settings is in Hosts' toolbar.

### Welcome / empty

No tabs: terminal glyph, "No Open Tabs", one sentence, then four rows with shortcuts: New Tab ⌘T,
Connect to a Host…, Start an Agent…, Command Palette ⌘K.

### Command palette (⌘K, ⇧⌘P)

Ghostty's palette in a glass panel near the top: 20 pt light query "Execute a command…", divider,
rows with icon or status glyph, title, subtitle, badge and shortcut. Empty query: sections Needs
You → Tabs → Terminal → Go → Hosts. With a query: fuzzy ranked flat list, matched characters bold
in the accent. ↑↓ / ⌃P ⌃N move, Return runs, Esc or a click outside closes.

### Scrollback search (⌘F)

Ghostty's search bar: 180 pt field with "2/14" inside, ▲ ▼ ✕; Return next, ⇧Return previous, Esc
closes when empty. Glass panel, draggable between corners. (Matching is the renderer's; the bar
takes `selected`/`total`.)

### Hosts (`Screens/HostsView.swift`)

Quick connect field first (SF Mono, `user@host`, Return connects). Sections: Needs you (red
count + the reason line), Active (connection dot, address in SF Mono, sessions, agent glyph
counts, last output line), Pinned, Other (unreachable with reason and hint). Kind glyphs: daemon
`server.rack`, SSH `terminal`, local `laptopcomputer`. Swipe pin / forget (confirmed), context menu
Connect, Pin, Copy Address, Forget. Empty state "Add Host".

### Add host / pairing (`Screens/PairingSheet.swift`)

Segmented SSH / Ticket / Scan (Scan hidden on Mac). SSH parses `user@host:port` live into rows.
Ticket: SF Mono editor + Paste, footer names the host command (`<brand> pair`, from
`Brand.name`). Scan: a viewfinder with corner brackets. Progress only after 200 ms, errors inline in
red, success haptic.

### Connection lost / reconnecting

The pane keeps its last frame, desaturated to 25 % and dimmed to 55 %; a glass card says
"Reconnecting to studio", "Attempt 3 · last output 16s ago. Sessions keep running on the host;
you'll resume where you left off." with Disconnect and Retry Now (default). Unreachable: reason +
hint (e.g. Tailscale). The sidebar footer and connection dots show the same state.

### Agent Inbox (`Screens/InboxView.swift`)

Needs you / Running / Finished. Row: status glyph, agent, host · session, age (ticking for
running), prompt. Permission requests show the tool and command in an SF Mono block with Deny
(glass) and Approve (prominent); questions show the text and Reply… which opens an inline
composer. Optimistic: the row moves to Running with `snappy` at once. Swipe Mark Done; context
menu Open Pane, Copy Prompt. New Agent sheet: agent (Claude Code / Codex), connected host, prompt.

### Share session (`Screens/InviteSheet.swift`) and presence

Toolbar avatars (≤ 3 + N, typing ring) open Share Session: people with roles (Can type / Can
view; owner fixed), access segment for the link, SF Mono link, Copy (✓ swap) and Share.

### Links & paths (`Screens/LinksSheet.swift`)

All / URLs / Paths, filter, rows with icon, path with file name emphasized and `:line:col`
secondary, "3 lines up". Tap opens; context menu Copy, Open, Insert in Terminal.

### Diff review (`Screens/DiffReviewView.swift`)

A page sheet: "Working tree vs HEAD", "3 files · +425 −4", per-file pinned headers (status
letter, directory secondary + file name medium, counts, collapse), hunks on a subtle fill, old/new
line numbers, 2 pt gutter bars, 12 % added/removed backgrounds, horizontal scroll per file, 18 pt
lines. Toolbar Request Changes / Approve (⌘↩).

### Files (`Screens/FilesBrowserView.swift`) and editor (`Screens/EditorView.swift`)

Files: directories first, monochrome SF Symbols per kind, git letter in its color, size and age,
push to descend, filter, context menu Open / Copy Path / Reveal in Terminal / Insert Path. Editor:
36 pt header (icon, name, directory in SF Mono, Edited dot, Save ⌘S, menu), SF Mono text with a
line-number gutter, 22 pt status bar "Ln 1, Col 1 · UTF-8 · LF · TOML".

### In-app browser (`Screens/BrowserView.swift`)

SwiftUI `WebView`. iPhone: Safari-26-style floating glass capsules at the bottom (back/forward,
address, more). iPad/Mac: 36 pt bar with back, forward, reload, glass address field (lock for
https, `localhost:5173` for local), share, open in default browser; 2 pt accent progress line.

### Settings (`Views/SettingsView.swift`)

Ghostty's config as native settings; each control shows its Ghostty key in SF Mono under the
label. Appearance: Theme (463 Ghostty themes, searchable, Dark/Light filter, each row a prompt in
the theme's colors plus an ANSI swatch), Window (`window-theme`), Panes (compact/comfortable).
Font: JetBrains Mono, size stepper with live sample. Cursor: style, blink. Splits: unfocused
opacity, size overlay. Keyboard: Option sends Meta, ASCII keyboard, key bar profiles (rendered
from the real profiles). Notifications. About and Acknowledgements. Mac: toolbar-tabbed Settings
window; iOS: one grouped form. Values reach the renderer through `TerminalAppearance`
(`TerminalAppearance.fromPreferences()`).

## What makes it feel premium — checklist

- [x] Terminal frames at the display's rate (ProMotion key set; renderer display link); chrome
      animations are springs/short ease-outs, interruptible, nothing loops but the spinner.
- [x] No layout jank: splits snap to whole cells; resize overlay ignores keyboard-driven resizes;
      tab strip uses fixed equal widths; badges use `numericText` transitions and monospaced
      digits; space for progress labels is reserved.
- [x] Instant keyboard focus: palette and search fields focus on appear; Return/Esc everywhere;
      ⌘ shortcuts never reach the PTY.
- [x] Correct safe areas: terminal never under the status bar or home indicator; backgrounds
      extend behind bars so no seams; sidebar never samples the terminal.
- [x] iPad pointer: hover effects on dividers, bar buttons, rows; hover reveals tab close and pane
      menu.
- [x] Matched geometry: the selected tab pill slides between tabs.
- [x] Context menus on tabs, panes, hosts, inbox items, files, links; swipe actions on lists.
- [x] Optimistic UI: approve/deny/mark done move rows immediately; no spinners under 200 ms.
- [x] Words not spinners for connection state; never a blank pane.
- [x] One accent, used only for focus/selection/primary; state hues from the terminal palette.
- [x] SF Symbols only; SF Pro chrome; SF Mono literals; JetBrains Mono grid.
- [x] Light and dark everywhere; Dynamic Type through text styles on iOS; VoiceOver labels on
      dividers (adjustable), status glyphs, avatars, badges; Reduce Motion respected.
- [ ] Context menu *previews* (live pane thumbnails) — needs the renderer's snapshot API wired
      into `contextMenu(menuItems:preview:)`.

## Screenshots

`apple/scripts/screenshots.sh <udid> <prefix> <dir> [screens]` (simulator) and
`apple/scripts/mac-screenshots.sh <app> <dir> [screens]` (Mac; the Debug app draws its own window
with `-snapshot`, so it works on a locked Mac — glass and the sidebar list are not captured by
`cacheDisplay` and show as white). Screens: `single splits bar hosts inbox palette search
keybar reconnect overlays welcome pairing launchAgent invite links diff files browser editor
settings toggle`.

`-light`.

## Known gaps

- **Theme changes reach open panes only partly.** Font size, padding, cursor and dimming apply
  live through `TerminalAppearance`; colors (background, palette) are fixed when a terminal is
  created, so a new theme shows in new panes. Needs a live `Terminal.Configuration` update in
  TerminalKit.
- **Mac verification is partial.** The Mac was locked: screenshots come from the app drawing
  itself, which leaves glass and the vibrant sidebar white (the sidebar's list is present: 10 rows,
  248 pt, checked from the view tree), and the Mac UI test
  (`testSidebarAppearsAfterSwitchingFromTabStrip`) is written but could not run ("Authentication
  cancelled"). Re-run both on an unlocked Mac.
- **Context-menu previews** of panes (live thumbnails) are not wired.
- **Scan QR** draws a viewfinder only; no camera (`DataScannerViewController`) behind it.
- **Search** is UI only: the bar shows the counts it is given; matching and highlights belong to
  the renderer.
- **Editor**: line numbers do not follow wrapped lines; Ln/Col is static.
- **Inbox/Hosts/Links/Diff/Files/Browser** run on mock data behind protocols
  (`App/Sources/Model/ScreenModels.swift`); the wiring replaces `MockData.swift`.
- **Key bar screenshots** show main's hardware-keyboard strip (profile chip + esc), because the
  simulators have a hardware keyboard attached; the full row uses the same `KeyBarLook` keys.
- **Light terminal themes** are supported by the chrome (window theme "Match Terminal", seamless
  toolbar rule) but not reviewed screen by screen.
