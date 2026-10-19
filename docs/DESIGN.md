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
| split divider | background × 0.6 brightness (`#181A1F`) | same | 1 pt dividers, header rules, sidebar edge | Ghostty `splitDividerColor` (darken 40 %) |
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
4. The window chrome follows the terminal, not the system (Ghostty `window-theme = auto`, the
   default "Match Terminal"): a dark theme gives dark chrome everywhere (sidebar, toolbar and
   title bar, tab strip, sheets, key bar) even with the system in light mode, and the reverse.
   Where chrome touches the terminal (toolbar band, tab strip, pane headers, iPhone top bar) it
   is painted with the terminal background, seamless like Ghostty's transparent titlebar.
   flush with the window edge, on `TerminalTheme.sidebarBackground` (the terminal background
   at 0.82 brightness for dark themes, 0.955 for light), separated by a 1 pt split-divider line.
   It is drawn by hand (a scroll view of rows), because the system sidebar list paints its own
   material.

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

### Windows and widths

- Layout by window width, never by device (`WidthBucket`): under 600 pt the compact layout (one
  pane, the tab switcher, the floating tab bar), from 600 pt the sidebar with splits; 12 pt of
  hysteresis. An iPhone in portrait, Slide Over, a third or an 11" half of an iPad and narrow
  Stage Manager windows are compact; an iPhone in landscape, a foldable's inner screen, iPad mini
  and wider windows are regular. Crossing the boundary keeps the tab, the focused pane and its
  scroll position, and never shows the cols × rows overlay.
- Every window is its own (iPad scenes, Stage Manager, Mac windows): New Window (⌘N) opens the
  same hosts on the same tab; tab and host context menus have Open in New Window
  (`macwindow.badge.plus`); on iPad a tab dragged out of the window becomes a window.
- An external display without Stage Manager shows the iPad's tab full size, chrome-free, the
  font scaled to fill it; the iPad keeps the keyboard and the chrome.
- Handoff from another device opens the same host, tab and pane. A host this device does not
  have: an alert, "studio isn't set up on this iPad", with Add Host (SSH address filled in) and
  Not Now; never a silent failure.

### Window and title bar (Mac)

- One layout for both tab placements: the integrated sidebar (vertical tabs only) beside a
  detail column whose toolbar is the same in both: the sidebar toggle leading; the tab's name
  with a subtitle ("Local · 3 panes", or the host's name); presence avatars; one monochrome glass
  group with Hosts, Find, the pane menu and the command palette; the tab-placement toggle on its
  own. Never accent-tinted. `ChromeUITests.testToolbarIsTheSameInBothTabPlacements` compares the
  buttons' frames in both placements and attaches screenshots.
- The toolbar background is hidden: the sidebar color runs up behind the traffic lights and the
  terminal background behind the rest. The window title's folder is the proxy icon
  (`navigationDocument`) for local tabs.
- Switching to vertical tabs always shows the sidebar; covered by
  `testSidebarAppearsAfterSwitchingFromTabStrip` and the `toggle` screenshot fixture. The divider
  drags to resize (200–360 pt, double-click restores 248).


- Inbox (count badge, red only when something needs you) and Hosts at the top.
- One group per host the window shows, all at once (owner, 2026-10-18: switching hosts never
  goes through the Hosts screen): This Mac first (macOS only), then each open daemon and plain-SSH
  (`laptopcomputer` for this Mac) in `.secondary`, the host's name in the section font
  (`.primary` when live, `.tertiary` when not), an "SSH" outline badge for plain-SSH hosts, the
  host's aggregate agent glyph, a state glyph **only when not live** (§3.3: reconnecting
  `arrow.triangle.2.circlepath` amber, offline `wifi.slash`, can't connect
  `exclamationmark.triangle.fill` red, a mini spinner after 1 s while dialling; each labelled with
  its copy), and + "New Terminal" (quiet until hover on the Mac, always on touch). No dots, no
  status text. Tapping the header collapses the group (a collapsed group shows its tab count).
  Rows of a host that is down stay, at 60 %. Context menu: New Terminal, Collapse, Retry Now
  (only when not live), Show in Hosts, Disconnect.
- A host with no tabs shows one row "New Terminal" (`plus` in `.secondary`) under its header
  (§3.5); the terminal area shows the welcome view with New Terminal ⌘T, never a void.
- One row per tab: its number across all hosts (tertiary, monospaced), a leading slot (16 pt on
  holds the focused pane's program mark (14 / 16 pt: the official logo where its terms allow,
  replaced by the agent glyph on unfocused tabs (§3.4: working = mini spinner, needs input =
  amber `questionmark.circle.fill`, done = `checkmark.circle.fill`, failed = `xmark.circle.fill`);
  every row has the slot so titles align. The live context in SF Mono underneath, under the title, ⌘N on the Mac (⌘1–8 index the
  unified list; numbers do not change when a group collapses or a host goes down). Selection is a
  9 % fill with radius 10 (hover 6 %), never the accent. Drag to reorder within a host; context
  menu Rename / Close. Under a group's tabs, its agents.
- Footer: Settings only (no connection summary, §3.7 rule 1).
- Tab strip: a single-host window shows no host; with tabs from several hosts, each tab gets the
  host's name as a second line (`meta`, `.tertiary`).
- iPhone: the bar shows the tab's title with the host's name as a second line (state glyph after
  it only when not live); the title menu lists every host as a section with its tabs and
  "New Terminal on …".
- Inbox: + is a menu, New Terminal (default) then New Agent. Terminal toolbar: a pencil "Draw"
  button next to the pane menu (⌃⌘D), disabled where the focused pane cannot be drawn on.
- Tab names: every new tab gets a short friendly adjective-noun name ("quiet-otter",
  `Workspace/FriendlyName.swift`, curated lists), stable, and sent to the daemon as a rename so
  every device shows it. A user rename always wins. The context line is the agent's task, else
  the foreground program, else the program's OSC 0/2 title, else `repo:branch` (local), else the
  directory. Settings ▸ "Tab Title from Shell" (`title-from-shell`) lets an OSC title replace a
  generated name.
- A group's agents: every pane of that host whose program reports status, across its tabs:
  focuses the pane, switching hosts if needed.

### Tab strip (horizontal tabs) — Ghostty native tabs

Equal-width tabs across the row; centered title led by the same slot as the sidebar
(program mark, the agent glyph instead on unfocused tabs); ⌘N right-aligned; close
button on hover at the leading edge; 1 pt separators between unselected tabs (none beside the
selected one); the selected tab a slightly lighter rounded pill (primary 11 %, radius 7, 0.5 pt
hairline), moved with `matchedGeometryEffect`; + at the end. The strip sits under the shared
toolbar (Mac and iPad alike) on the terminal background with a divider-colored bottom rule. Drag
tabs to reorder.

### Splits, panes, overlays — Ghostty 1:1

- Dividers 1 pt in the split-divider color, 7 pt hit area with resize pointer on Mac, 20 pt with
  pointer highlight on iPad; double-click/tap equalizes; adjustable for VoiceOver ("Horizontal
  split divider", ±2.5 %). Split sizes snap to whole cells (main's `SplitSnapping`).
- No focus ring. Unfocused panes are dimmed with the background at 1 − `unfocused-split-opacity`.
- Pane header (only in splits, 24 pt, on the terminal background): program mark (12 pt),
  program's display name, status glyph and state word in its color, and the pane menu (… on hover/focus). Tap focuses.
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

iPhone and iPad have no shell of their own: a fresh install opens here with "Connect a Host",
one sentence, and Connect with SSH…, Paste a Pairing Ticket…, Scan a QR Code…, Command Palette.
New Tab there opens Add Host. The local echo backend is only for UI tests (`-localEcho YES`),
`-mock` and the design fixtures; `ChromeUITests.testFirstLaunchShowsWelcomeNotAShell` guards it.

### Command palette (⌘K, ⇧⌘P)

Ghostty's palette in a glass panel near the top: 20 pt light query "Execute a command…", divider,
rows with icon or status glyph, title, subtitle, badge and shortcut. Empty query: sections Needs
You → Tabs → Terminal → Go → Hosts. With a query: fuzzy ranked flat list, matched characters bold
in the accent. ↑↓ / ⌃P ⌃N move, Return runs, Esc or a click outside closes.

Two more modes of the same panel: **Go to Tab…** (⌘P, "Go to a tab on any host…") lists every
tab on every host in sidebar order, subtitle "host · context", so a query matches a tab's name,
its context line or its host; **New Tab On** (⌥⌘T, "New tab on…") lists the open hosts, the
current one first with a "Current" badge, then other saved hosts (connects, then opens the tab)
and Add Host…. The empty-query Tabs section also spans every host.

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

Needs you / Running / Finished. Row: status glyph, the agent's mark (14 pt) and name, host · session, an accent dot while
unseen, age (ticking for running), an open-pane arrow, prompt. Permission requests show the tool
and command in an SF Mono block with Deny (glass) and Approve (prominent); questions and finished
turns offer Reply…, an inline composer that types into the agent. Finished turns carry the
agent's last message; long commands appear with a check/cross glyph and "Exited 0 · 4m 12s".
The subtitle says "3 new · studio 2, devbox 1"; after 1.5 s on screen the dots fade (seen on
every device). Optimistic: an answered request moves to Running at once. Swipe Mark Done;
context menu Open Pane, Copy Prompt/Summary. New Agent sheet: agent, connected host and its
directory, New Worktree (+ branch), prompt (optional); Start shows "Starting…" and the sheet
closes as soon as the pane exists.

### Share session (`Screens/InviteSheet.swift`) and presence

Toolbar avatars (≤ 3 + N, typing ring; a share glyph when alone) open Share Session (live since

- **Header**: tab name, "You and 3 others · you own this host", the others' avatars.
- **Invite** (owner): a name field; four role tiles (Viewer locked on, Prompter, Driver,
  Approver — SF Symbol, title, one line of what it allows; selected = accent hairline + 10 %
  accent fill, the only accent on the screen besides the primary button); scope segment Host /
  Session / Tab / Pane with its sentence; Expires (1 h, 24 h, 7 d, never) and Who Can Use It
  (1 person, 5 people, anyone) menus; Can Invite Others; "Create Invite Link" (prominent glass;
  "Signing invite…" in words). The result replaces the composer: a QR code (Core Image, dark
  on white, quiet zone, 168 pt) beside the summary ("Driver · Session · 24 hours · 1 person"),
  the link in SF Mono (middle-truncated, selectable) and "Expires in 23 hr"; Copy Link (✓ swap)
  and Share (system share sheet); "New Invite" in the header.
- **People Here**: avatar (dimmed when away), name, "Driving" pill in their own hue, where they
  are ("In cargo test · Claude Code · typing…" in their hue while typing), role words and
  scope right-aligned. Swipe or context menu: Revoke Access (confirmation that says what it
  does and does not undo), Give Control, Copy Device Key.
- **Access & Grants**: active invites (glyph by strongest role, label, "Can invite" pill, roles
  · scope, "Expires in 6 days · 1 of 1 used", grant id in SF Mono), devices (owner/guest,
  first seen, key, connected dot), ended invites; swipe Revoke with confirmation.
- **Audit Log**: a seal header ("Log intact · 10 records; every hash and approval signature
  re-verified on the host", or red "Log was altered"), All / Approvals / Access / Control,
  search; rows with a glyph per kind (approvals green seal / red seal), who did what, time and
  `#seq`; approvals carry the command in SF Mono and "Signed by Mira Holt · Option “Yes”", tap
  for signer key, signature, agent request id and record hash.
- **Guests** see Your Access (role, scope, expiry, what each role allows) instead of Invite.

On the terminal, nothing shows while the owner is alone. With others: split headers show the
avatars of people in that pane (14 pt, typing dots in their hue, a keyboard glyph in the
driver's hue). The control chip (top-trailing glass capsule) says "Mira is driving · Take
Control", then "Asked Mira · yours if idle 4 s · Cancel" (owner: "Take Now"), or "You're
driving · Release" when someone watches your pane. The holder gets a glass card at the top of
the pane: avatar, "Mira wants control", "Hands over in 4 s unless you keep typing", Keep /
Hand Over (prominent), with the attention haptic. A viewer's focused pane has a bottom capsule
"View only · Alex invited you to watch · ends in 23 hr"; a prompter's agent pane has the
composer (glass, "Prompt Claude Code…", round send button, ⌘↩), other panes the "prompts go
to agent panes" capsule. Refusals and hand-overs arrive as toasts in words ("Mira is driving.
Take control to type.", "Needs an owner: …").

Join a Session (deep link `<scheme>://join/…`, palette, paste): the link field, then a card
read before dialling — inviter avatar, "Alex Kim invites you as Mira", each granted role with
its sentence, scope, expiry, devices, the host key — a display-name field, and "Join as
Driver" (prominent). Refusals say why (expired or used up, revoked, offline).

`ipad-presence`, `ipad-lease-request`, `ipad-viewer`, `ipad-prompter`, `ipad-driver-share`,
`ipad-join`, `iphone-*` (`-mock`, `-mockPresence YES`, `-mockRole …`, `-shareRoute …`), and
`ipad-live-1…5` from `MultiplayerUITests` against a real daemon (presence, signed invite with QR,
grants, revoked guest, audit log).

Notifications: Settings ▸ Notifications lists the five kinds with a sentence each and "Only
When the App Is in the Background"; the footer says whether this build can receive pushes.
Approval notifications carry Approve / Deny (Face ID first) / Open. The agent-run Live Activity
is terminal-dark with state hue only: amber working (with a running timer), red "Needs you",
green done.

### Links & paths (`Screens/LinksSheet.swift`)

All / URLs / Paths, filter, rows with icon, path with file name emphasized and `:line:col`
secondary, "on screen" / "in output", missing paths dimmed ("not found"). A path opens in VS Code
at its line; a URL in the in-app browser. Context menu Open, Copy, Insert in Terminal.

### Diff review (`Screens/DiffReviewView.swift`)

A page sheet titled with the repository, the branch as subtitle; toolbar: scope menu
(Uncommitted / Staged / each agent turn "Claude Code · turn 4 · 6 min ago"), Layout (automatic,
unified, side by side), Reload ⌘R. "Uncommitted changes", "3 files · +425 −4 · ↑2". The code
sits on the terminal background in SF Mono, syntax-neutral, Ghostty-quiet: per-file pinned
headers on the raised background (status letter, directory secondary + file name, note count,
counts, collapse), hunk headers dim, old/new numbers at 32 %, 2 pt gutter bars and 13 % fills in
the palette's green/red. Side by side on iPad/Mac (lines wrap; empty cells a faint fill), unified
on iPhone (horizontal scroll per file, 18 pt rows). Tap a line → an inline note composer; notes
are accent-tinted cards under their line; a floating glass bar "2 notes · Goes to Claude Code as
one prompt" with Copy and Send to Claude Code (⌘↩).


The daemon's repository snapshot (docs/DAEMON.md §5.12) drives four surfaces. Values from

- **Sidebar**: inside each host group, tabs outside a repository first (as before), then one
  section per repository: the name in the section style, `.secondary`, sentence case, no icon,
  + New Task (hover on the Mac, 0.6 on touch), padding top 12 / bottom 4. Under it one row per
  worktree, main first: a 16 pt slot (18 on touch) with the branch glyph, or the pull request's
  glyph in its state colour (open green, merged purple from the palette's magenta, closed red,
  draft grey), at 0.6 with a 10 pt checks badge in the corner; the branch (body 13 on the Mac,
  subheadline 15 on touch, regular weight always) with the worktree's name under it in
  footnote `.tertiary`, hidden when it repeats the branch; then a fixed-size trailing cluster,
  6 pt apart: `+N −M` (caption, monospaced digits, palette green/red), `#PR` (caption
  cross-fades the cluster to the row's ⌘N (0.15 s, no reflow). Rows: 6 pt vertical insets, title
  and subtitle touching, selection a neutral 10 % fill at radius 8, and on the selected row every
  coloured glyph and count drops to `.secondary`. A worktree with one tab is that tab's row; with
  several, the tabs follow one level in (14 pt); with none it is quiet and a click opens a tab
  there. Context menu: New Tab Here, Open on GitHub, Run ▸, Copy Path, Copy Branch Name,
  Rename/Close Tab, Archive Worktree…, Delete Worktree…. The ⌘1–9 order follows the rows.
- **Needs you**: above the hosts, a highlight section (6 pt amber dot at 60 % with a hairline,
  "Needs you") hoists every tab, on any host, whose agent waits or failed: glyph, tab, "host ·
  branch", the state word in its colour. The rows also stay in place below.
- **Toolbar**: next to the host button, the focused worktree's pull request: its glyph at 0.6
  with the checks badge and `#42` in subheadline `.secondary` (or the branch when there is none).
  Hover opens the popover and it closes 150 ms after the pointer leaves both (tap on touch; a
  sheet on iPhone). Then one glass group: Open In ▾ (VS Code, Files, Diff, GitHub) and Run ▾
  (the default script on click, ⌘R; the repository's scripts with their tinted symbols, then
  Global, then Edit Scripts…).
  Headline "Open Title #42" with the state word and number `.secondary`; a `.secondary` line
  "branch · Ready to merge" (or why not: behind, blocked, conflicts, draft, still checking);
  `+128 −17` in subheadline green/red (and "· Merge conflicts" in red); the checks ring (12 pt,
  2 pt line: failed, in progress, skipped, passed) with "1 failed, 1 in progress, 3 successful";
  a divider; one caption row per check: coloured symbol, name (opens its page), status word
  right-aligned `.secondary`; then Open on GitHub, Re-run Failed (when an Actions run failed)
  and Merge… (prominent, only when GitHub allows it). With no PR: "No Pull Request" and Create
  Pull Request. When the host's `gh` is missing or signed out, the popover says so, once, with
  the command (`gh auth login`) and Copy: no token is ever asked for in the app.
- **Palette** (section "Git · branch"): Merge PR #42 (strategy from Settings, then a
  confirmation naming it; an UNSTABLE PR says an optional check failed), Re-run Failed Checks,
  Open PR on GitHub ⌃⌘G, Create Pull Request, Check Out Pull Request… (into a new worktree),
  Run: <script> (badge "Script"), Archive Worktree, Delete Worktree…, Restore <branch>. A Git
  menu carries the same, with ⌘R and ⌃⌘G.
- **New Task** (replaces New Agent): Run (Claude Code · Codex · Shell, segmented), host,
  repository, New Worktree, the name (a friendly generated one, shuffle) and the branch (its
  placeholder is the branch the host derives from the name), "Runs setup first: `pnpm i`", the
  prompt. Start makes the worktree and opens its tab at once; the prompt is typed when the agent
  is ready.
- **Archive and delete** ask only when there is something to lose: "It has 3 uncommitted
  changes. They are kept with the archive and come back when you restore it." Settings ▸ Git:
  merge strategy, Delete Merged Worktrees (Never, 1, 3, 7 (default), 14, 30 days; sent to each
  host), global scripts (name, command, SF Symbol, tint, ⌘R).

with a stand-in `gh`): `ipad-sidebar-dark`, `ipad-sidebar-fix-login-dark`, `ipad-toolbar-pr-dark`,
`ipad-pr-popover-dark`, `ipad-merge-confirm-dark`, `ipad-new-task-dark` from `GitUITests`
(`apple/scripts/git-ui-test.sh`); `mac-sidebar-dark` drawn by the app
(`apple/scripts/git-mac-screenshot.sh`; glass toolbar items come out as white shapes in that
path). `ipad-before-sidebar-dark` and `mac-before-sidebar-dark` are the same data before the
grouping.

### Files (`Screens/FilesBrowserView.swift`) and editor (`Screens/EditorView.swift`)

Files: on the terminal background; directories first (folder glyph in `info`), monochrome SF
Symbols per kind, the change letter in the palette's colour, size and age, symlink badge, push to
descend, filter, pull to refresh; + menu Upload Files… / New Folder; drop files onto the list
(dashed accent outline while targeted); a floating progress capsule for transfers. Context
menu Open in VS Code, Share…/Download, Copy Path, Rename…, Reveal in Terminal, Insert Path, Move
to Trash (confirmed). A file pushes a preview: text with a line-number gutter in SF Mono, images
fit, others a card with size and Download.

Editor: VS Code's own workbench, full screen on iPhone/iPad (a large sheet on Mac) under a 36 pt
strip on the terminal background: close, `</>`, folder name, host in SF Mono, Reload, More (Copy
Folder Path, Stop Editor on host). While it starts: a centred card of steps — Set up VS Code on
host (first run only) / Start the editor / Open the workbench — each with a check, spinner or
ring and its seconds, and one line saying what is happening ("First time on studio: VS Code is
being set up there. It takes about 15 seconds, once."). No licence prompt, no sign-in, no editor
choice; failures say why with Try Again. The workbench fades in once loaded.

### In-app browser (`Screens/BrowserView.swift`, `Screens/BrowserPorts.swift`)

Ports list first: "Dev servers" (globe in accent, `localhost:5173` in SF Mono, process · pane),
"Other ports", an address field. A new server on the window's host is offered by a glass capsule
over the terminal ("● localhost:5173 is up · node · pnpm dev [Open] ×", 15 s). The page: SwiftUI
`WebView`. iPhone: Safari-26-style floating glass capsules at the bottom (Ports, back/forward,
address, more). iPad/Mac: 36 pt bar on the terminal background with Ports, back, forward,
reload, glass address field (lock for https, `localhost:5173` for local), share, Open in Safari;
2 pt accent progress line.

### Settings (`Views/SettingsView.swift`)

Ghostty's config as native settings; each control shows its Ghostty key in SF Mono under the
label. Appearance: Theme (463 Ghostty themes, searchable, Dark/Light filter, each row a prompt in
the theme's colors plus an ANSI swatch), Window (`window-theme`), Panes (compact/comfortable).
Font: JetBrains Mono, size stepper with live sample. Cursor: style, blink. Splits: unfocused
opacity, size overlay. Keyboard: Option sends Meta, ASCII keyboard, key bar profiles (rendered
from the real profiles). Notifications. About and Acknowledgements. Mac: toolbar-tabbed Settings
window; iOS: one grouped form. Values reach the renderer through `TerminalAppearance`
(`TerminalAppearance.fromPreferences()`).

### Drawing in the terminal (`App/Sources/Drawing`)

Draw mode lays a transparent Excalidraw over the pane: the terminal stays visible and keeps
scrolling underneath (two fingers scroll it), the scene is pinned to its row (a 2 pt accent bar
marks the anchor row's left edge). Excalidraw's own chrome is hidden: nothing sits over the
first rows. One quiet glass capsule at the bottom carries the tools as monochrome SF Symbols
(Select, Pen, Rectangle, Ellipse, Arrow, Text, Eraser; the chosen one on a 14 % primary fill, no
tint; one menu on narrow panes), Write on iPad, Cancel, and one prominent action: Send to
Claude/Codex (⇧⌘↩) when an agent runs, else Done (⌘↩). One pane draws at a time. No dimming, no
sheet: you never leave the terminal. Done turns the drawing into an image in the output at the
same cells, drawn by the renderer like kitty graphics, outlines it in the accent for a moment and
says "Placed in terminal · scrolls with the output" in a glass capsule where the toolbar was (with
Send to Claude/Codex when an agent runs); a tap on it reopens it in place. Drawings whose row
left the scrollback wait in a small glass chip (pin.slash + count) at the pane's top-right.
Write (iPad) shows handwriting at the prompt as underlined marked text, like an IME, until
Return. Canvas panes show the same editor full size on the terminal background. Screenshots:

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
settings toggle programs` (`programs`: one tab per program for the marks, `-fixtureTabs N` for

`hosts` (live hosts list), `hetzner-splits` / `hetzner` (the Hetzner daemon session, split on the
host), `reconnect`, `sidebar`, `tabstrip`, `settings`, `pairing`; `mac-*` drawn by the app itself
(`-snapshot`; glass controls come out as white shapes in that path). Live-data launch options:
`-openHost <name>`, `-destination hosts|inbox`, `-screen live-splits`, `-noAutoFocus YES`.

Multi-host sidebar (2026-10-19, real local daemons, `-testTickets a,b -testTicketNames …`):
itself), `ipad-alpha.png` / `ipad-beta.png` (switching by click), `ipad-new-tab.png` (⌘T on the
current host), `ipad-alpha-down.png` (one host reconnecting, the other live), `ipad-alpha-back.png`,
`ipad-no-tabs.png` (New Terminal in the sidebar and the welcome view), `iphone-switcher.png` (the
title menu grouped by host), `iphone-hetzner.png` (title + host line).

## Known gaps

- **Theme changes reach open panes only partly.** Font size, padding, cursor and dimming apply
  live through `TerminalAppearance`; colors (background, palette) are fixed when a terminal is
  created, so a new theme shows in new panes. Needs a live `Terminal.Configuration` update in
  TerminalKit.
- **Mac verification is partial.** The Mac was locked during the merge run: Mac screenshots come
  from the app drawing itself (glass toolbar buttons show as white shapes; the integrated sidebar
  draws correctly), and the Mac UI tests (`ChromeUITests`, `testSidebarAppearsAfterSwitchingFromTabStrip`,
  `MacDogfoodUITests`) are written but could not activate the app. Re-run on an unlocked Mac.
- **Context-menu previews** of panes (live thumbnails) are not wired.
- **Scan QR** runs VisionKit's scanner inside the viewfinder where a camera exists; untested on a
  device (the simulator has no camera and shows the hint instead).
- **Search** shows the daemon's total over the whole scrollback (daemon panes); stepping through
  matches and highlights belong to the renderer and are not wired.
- **Real vs mock**: everything but Share/presence reads the hosts (docs/APP-ARCHITECTURE.md §10);
  `-mock` keeps the `MockData.swift` stand-ins for screenshots.
- **Key bar screenshots** show main's hardware-keyboard strip (profile chip + esc), because the
  simulators have a hardware keyboard attached; the full row uses the same `KeyBarLook` keys.
- **Light terminal themes** are supported by the chrome (window theme "Match Terminal", seamless
  toolbar rule) but not reviewed screen by screen.
