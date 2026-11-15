# Design

The Apple apps (iPhone, iPad, Mac; OS 26+) look like Ghostty's macOS app around the terminal: native, dense, quiet, precise. This document
is the design system: its tokens, its rules, every screen, and where an element follows Ghostty or
the platform. Code:
`apple/Packages/DesignSystem` (tokens and components) and `apple/App/Sources` (screens).

Ghostty's macOS app (MIT) is the one source of code:

| Reference | Licence | Taken |
|---|---|---|
| Ghostty macOS app | MIT | Swift UI code ported 1:1 with attribution (`apple/THIRD_PARTY_NOTICES.md`); config names and defaults; default palette; bundled theme list. Not the name or icon. |

## Principles

1. **The terminal is the product.** Chrome recedes: monochrome, thin, on the terminal's own
   background wherever it touches the grid. Nothing decorative is drawn over or next to it.
2. **Color is for state.** Chrome uses system label and fill colors. Hue appears only for agent
   and connection state, git status, focus and the single primary action per screen.
3. **Native first.** System controls, list styles, sheets, menus, context menus, swipe actions,
   searchable lists and Liquid Glass. Custom drawing only where the platform has no equivalent
   (dividers, tab strip, overlays on the grid), and then copied from Ghostty.
4. **Words, not spinners.** Every waiting state says what is happening and offers the next step
   Nothing visible under 200 ms, then a label.
5. **Never blank.** Lost connections dim the last frame; empty lists name the next action.

## Tokens

All values live in `DesignSystem/Tokens`. Chrome text is SF Pro through text styles (Dynamic
Type on iOS); literals (paths, commands, hosts, code) are SF Mono; only the terminal grid uses
JetBrains Mono (bundled, OFL, Ghostty's default face).

### Color

Every chrome colour is derived from the active terminal theme (`ChromePalette`,
`DesignSystem/Theme`). A theme gives background, foreground, cursor
and 16 ANSI colours; the chrome is the foreground laid over the background at fixed strengths, so a
light theme gets darker panels and a dark theme lighter ones with one rule, Solarized chrome is
Solarized and Dracula's is Dracula. `DS.Palette.*` are `ChromeStyle`s that resolve from the
environment's palette when drawn; window and sheet roots set it with `chromeTheme(_:windowTheme:)`,
content areas take the ink and tint with `chromeContent()` (never above a toolbar, so bar items
stay monochrome and keep their disabled look). UIKit/AppKit views read
`ChromePalette.fromPreferences()` (`KeyBarTheme` for the key bar).

| Token | Formula | Use |
|---|---|---|
| `base` | the theme background | window base, tab strip, toolbar band, iPhone top bar, Agents/Hosts lists |
| `sidebar` / `raised` / `overlay` | background + foreground at 5 / 10 / 15 % | sidebar; cards, popovers, palette glass tint, command blocks, fields; menus |
| `groupedPage` / `groupedRow` | dark: base / raised; light: sidebar / base (iOS convention) | Settings, sheets' forms |
| `text`, `textSecondary`, `textTertiary`, `textQuaternary` | foreground at 90 / 60 / 40 / 20 % | the hierarchical styles under `chromeContent()` (`.primary`, `.secondary`, `.tertiary` are these) |
| `hoverFill` / `selectedFill` / `pressedFill` | foreground at 5 / 10 / 15 % | every interaction state through `ControlState` (below): rows, tabs, the selected tab pill, bar, quiet and form buttons, lit toggles |
| `tile` | the ink at the selected level (10 %) over the row under it | a program mark's tile (`ProgramTile`); a selected row keeps its tile, its mark in full colour |
| `hairline` / `separator` / `border` | foreground at 10 / 15 / 20 % | one-physical-pixel lines (`Hairline`, `hairlineBorder`), the sidebar edge, tab strip rule |
| `accent` | the cursor colour when it is a real colour (chroma ≥ 20, not the foreground, not a red/green/yellow); else the theme's blue (bright, or normal where the bright is grey) when it stands clear of both inks; else the blue/magenta/cyan farthest (CIEDE2000) from background and foreground. Then refined in OKLCH: chroma ≤ 0.13, lightness 0.48-0.62 (light chrome) / 0.68-0.86 (dark), hue kept, so a raw `#0000FF` never reaches the chrome | focus, toggles, links, the selected theme card |
| `selection` / `onSelection` | the accent at 14 % (light) / 24 % (dark), translucent, under the normal text (≥ 4.5:1) | the selected row in the palette and lists (as in Spotlight) |
| `prominent` / `onProminent` | the accent deepened toward the darker ink until the lighter ink reads on it at 4.5:1 | the one primary button (`.primaryGlass`) |
| `onAccent`, `on(_:)` | on a solid fill: the theme's `cursor-text` when it reads at 4.5:1 (on the accent, the theme's own pairing), else the chrome background or ink, else white or black, the first that reads | a latched key, a count badge on amber, swipe action discs, a presence name tag |
| `accentDim` / `accentRing` | the accent at 12 % (the container strength) / 25 % | a pressed accent control, a lit pane-header button, drop targets, a note under review / a field's focus halo outside its solid accent edge |
| `doneContainer` … `infoContainer`, `container(_:)` | a signal over the surface under it at one strength, 12 %: the weakest tint that stands apart from its surface (1.2:1 on average over all 771 Ghostty themes). The signal moves just far enough to read on its own container at 4.5:1 (0.04 OKLab lightness on average) | status chips, the toast's and update card's disc, git status letters, project drop targets |
| `scrollbar` / `scrollbarActive` | foreground at 25 % / at the tertiary level (≥ 3:1) | a hand-drawn scrollbar at rest / scrolling or under the pointer |
| `edge` | foreground at 8 % (light) / 16 % plus-lighter (dark), one physical pixel | every surface's inner edge (Surfaces) |
| `outline` | the scrim's darker ink at 10 % (light) / 50 % (dark), one physical pixel | every floating or pane surface's outer edge |
| `topLight` | white at 60 % (light) / the lighter ink at 14 % plus-lighter (dark), one physical pixel fading out within 24 pt | the light along a surface's top |
| `scrim` | the darker ink taken halfway to black, at 10 % (light) / 28 % (dark) | behind the command palette |
| `veil` | the terminal background at 40 % | over a saved screen, a pane being moved, a pane shielded while sketching |
| `done` / `error` / `attention` / `working` / `info` | the theme's ANSI green / red / yellow / magenta / blue mixed 35 % toward the foreground (50 % would turn a dark theme's amber into cream); a slot that is grey or off-hue keeps Ghostty's hue. Where that falls short of 4.5:1, its OKLab lightness moves away from the surfaces with the hue kept | state glyphs and words, status chips (on their container, radius `chip`), diff counts, PR states |
| `terminal`, `ansi(n)` | the theme itself | the grid, presence avatars |
| `bell` | `attention` at 50 % | bell border (Ghostty `BellBorderOverlay`, in the theme's own amber) |
| split divider | background × 0.6 brightness (dark) / × 0.92 (light) | splits only (Ghostty `splitDividerColor`) |
| unfocused dim | background at 30 % | over unfocused panes (`unfocused-split-opacity` 0.7) |

Guarantees (unit-tested over all 464 bundled themes, and in `ThemeStressTests` over all 771
themes Ghostty ships upstream, read from `reference/` and never bundled; in the theme's scheme and
forced to the other, with and without Increase Contrast): main text ≥ 4.5:1 on every surface and
on every control state over it (rest, hover, selected, pressed on base, sidebar and raised; the
ink moves toward white or black only as far as needed; for a garish mid-tone background the
chrome's background steps away from the terminal's), secondary text ≥ 4.5:1 and tertiary ≥ 3:1
on the same (tertiary is the third step of meta text; at 4.5:1 it would reach the secondary level
on menus), state colours ≥ 4.5:1 on every surface and on their own container (they are words
too), main text ≥ 4.5:1 on every container and on `accentDim`, the accent ≥ 3:1 on every surface
and on its dim fill, selection text ≥ 4.5:1 over every surface, `onAccent` and every `on(_:)`
label ≥ 4.5:1, `scrollbarActive` ≥ 3:1, and a program's symbol, dimmed in the style it inherits,
≥ 3:1. Menus (`overlay`) are the system's and carry no hand-drawn states. Setting
`GUDO_DESIGN_GALLERY_DIR` writes the worst pairing per token and the container sweep as CSV.

`window-theme`: Match Terminal (default) takes the theme's scheme; Light/Dark/System that
differ from the theme put the chrome on a neutral near-white (tinted 3 % with the theme) or
near-black (tinted with its ink) with the theme's background as ink, and keep the theme's accent
and states. The terminal, its key bar and keyboard keep the theme's own scheme. The asset
catalog's `AccentColor` is Ghostty blue (the default theme's accent); `LaunchBackground` is the
terminal background.

### Type scale

| Token | Style | Use |
|---|---|---|
| `title` | title3 semibold | sheet/screen titles that are not navigation titles |
| `rowTitle` / `rowTitleEmphasis` | body / body medium | list rows; selected tab |
| `rowSubtitle` | subheadline | second lines |
| `section` | subheadline semibold, sentence case | section headers (never uppercase) |
| `meta` | caption, monospaced digits | ages, counts, ⌘N hints |
| `badge` | caption2 medium, monospaced digits | pills (Ghostty palette badge) |

Every number that changes (counts, countdowns, progress, ages, PR numbers, ⌘N, cols × rows) uses
monospaced digits, through `meta`, `badge`, `overlay` or `.monospacedDigit()`.
| `literal` / `literalSmall` | SF Mono callout / caption | paths, commands, hosts, code |
| `sidebar(_:)` | Mac: the system sidebar's 11 / 13 / 15 pt rows (small, medium, large); touch: subheadline / body / title3 titles over footnote / subheadline / body | sidebar rows, at `sidebar-text-size` (Settings › Appearance: System, the default, follows System Settings › Appearance › Sidebar icon size on the Mac and is medium on touch; small, medium or large otherwise), applied live; the column widens or narrows with it (`widthExtra`) |
| `tabTitle` | callout (Mac), subheadline (touch) | tab strip |
| `paletteQuery` | title3 light | command palette field (Ghostty 20 pt light on touch, 15 on the Mac) |
| `keyCap` | 12 pt medium rounded | shortcut key caps (Ghostty `KeyCap`) |
| `overlay` | callout, monospaced digits | cols × rows, exit bar |

### Spacing, sizes, radii

Grid: 4 pt with a 2 pt half step: `2 4 8 12 16 20 24 32`, plus `row` 6 (glyph to label, a dense
row's vertical inset), `gap10` 10 (a leading slot to its title) and the badge padding 7 / 3. No
arithmetic on spacing tokens. Leading slots in rows are 22 pt so titles align to one column.

No point sizes in chrome: every label and glyph is a text style (`.imageScale` for glyphs), so it
follows Dynamic Type; the exceptions are the Ghostty key cap (12 pt rounded) and the two 10 pt
check badges drawn inside a fixed corner frame. Fixed-height bands clamp their text where it stops
fitting: the sidebar at accessibility 1 (its column widens with the text size, `SidebarWidth`), the
tab strip at XXL, pane headers and the iPhone bar at XL.

| Size | Value | Source |
|---|---|---|
| Divider visible / hit (pointer) / hit (touch) | one physical pixel / +6 / 20 pt | Ghostty `SplitView` (1 + 6), drawn at `1 / displayScale` as every chrome line; touch is ours |
| Pane header | 24 pt | Ghostty-quiet |
| Tab strip / tab | 34 / 28 pt (selected pill inset 3) | macOS 26 titlebar tabs, Ghostty native tabs |
| Strip chip width | an equal share of the strip, 160 to 240 pt; more tabs scroll | - |
| Command palette width | 580 pt Mac / 640 pt touch | Spotlight: a title and its context on one line |
| Chat reading column | 680 pt of text, centred; full width on iPhone | about 75 characters of body text |
| Key bar row | 44 iPhone / 52 iPad, keys 34 / 40, hardware strip 28 | keyboard key height |
| Window padding | 2 pt, balanced | Ghostty `window-padding-x/y` = 2, `window-padding-balance` |

Six radii, nothing in between, every one with continuous corners: chrome rounds a rectangle with
`.rounded(DS.Radius.x)` (or `style: .continuous`), never a literal and never circular corners
(`StyleLintTests`).

| Radius | Value | Use |
|---|---|---|
| `chip` | 4 | status chips, key caps, the resize overlay |
| `field` | 6 | fields, bar, quiet and form buttons, pane-header buttons, the selected tab pill |
| `control` | 8 | rows and row highlights, code blocks, palette rows (concentric with the 16 pt panel at an 8 pt inset) |
| `pane` | 12 | comfortable panes, the search bar, the secure-input badge, drop regions, sidebar cards |
| `panel` | 16 | floating glass panels (palette); glass reads smaller than an opaque edge |
| `card` | 20 | glass cards over the terminal: secret prompts, knocks, reconnect and control requests |

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
   is painted with the terminal background, with no seam, like Ghostty's transparent titlebar.
5. The sidebar is integrated, never a floating glass card: full height,
   flush with the window edge, on `DS.Palette.sidebar` (the theme background with its foreground
   at 5 %), separated by a one-pixel `separator` line.
   It is drawn by hand (a scroll view of rows), because the system sidebar list paints its own
   material.

### Motion

One vocabulary, `DS.Motion` (`Tokens/Tokens.swift`, `Tokens/Motion.swift`). Every animation is a
critically damped spring (no overshoot, nothing reverses) that keeps its speed when interrupted, so a
second tap mid-move carries on from where the thing is. Chrome moves only by opacity, scale and
offset; it never animates its own frame, size or padding. Small things are fast and light.

| Role | Spring | Within 1 % by | Use |
|---|---|---|---|
| `micro` | 0.12 s, no bounce | 0.15 s | hover fills, a press (scale 0.97), pills, badges, status glyphs, ⌘ hints, lit toggles, a field's focus ring |
| `standard` | 0.22 s, no bounce | 0.25 s | rows and selection, toasts and banners, menus, popovers, the host switcher's highlight, panels and bars, overlays, the search corner snap, a swipe settling, sidebar rows making room for a drag, the bell border |
| `structural` | 0.3 s, no bounce | 0.34 s (within a point of a full-window move by `structuralSettle`, 0.42 s) | splits, closing, zoom, a pane floating out or docking, a window to the tray and back, a floating window settling after a flick, picture in picture, the sidebar, the iPhone Duo's fold |
| `palette` | none on the Mac (`animationBehavior = .none`); `standard` on touch | | command palette in and out |

Named transitions (`.motionTransition(_:)`), each only opacity, scale and offset, each on its
own role so it never pops even when the change is not animated:

| Transition | Away from rest | Role | Use |
|---|---|---|---|
| `fade` | opacity 0 | the change's own | anything that should only fade |
| `pill(anchor:)` | opacity 0, scale 0.86 | `micro` | pills, badges, small buttons, a program mark changing |
| `toast(from:)` | opacity 0, scale 0.96, 16 pt toward the edge | `standard` | banners, agent toasts (from the leading edge), notices, secret prompts, knocks, presence cards, the update card |
| `row` | opacity 0, scale 0.97 from the top, 4 pt up | `standard` | a sidebar row arriving or leaving |
| `panel(from:)` | opacity 0, scale 0.98, 10 pt toward the edge | `standard` | the tab strip, bottom bars, the exit bar, the browser's address panel |
| `card(anchor:)` | opacity 0, scale 0.96 | `standard` | the reconnect card, cards under an avatar, picture in picture |
| `tab` | opacity 0, scale 0.985 | `standard` | a tab arriving in the strip |
| `arriving` | opacity 0, after `arrivalDelay` (0.16 s) | `micro` | what lands where a structural move is heading: a new divider, the minimize button once the header has made room, the exit control's label |

Under Reduce Motion every named transition only fades, and a highlight that would slide between
rows (the switchers) or a banner settling back after a drag changes in place
(`ChromeAccessibility.travel`). `attentionCue(trigger:)` is the one beat
that draws the eye to something that changed (it grows to 1.08 on `micro` and settles back on
`standard`); it does nothing under Reduce Motion. A tab whose agent turns blocked while the tab is
out of sight plays it once on its mark, in the sidebar and the strip
(`attentionWhenBlocked(_:isVisible:)`); it never takes focus.

| Timing | Value | Use |
|---|---|---|
| layout motion | every terminal a layout change moves | travels as its last frame, anchored top-left (cropped as it shrinks, on its background as it grows); its grid changes once, for where it is going, before it moves (one SIGWINCH), and it draws again when it is there and the program's redraw has come in (quiet 30 ms, 150 ms at most). Nothing reflows on the way, nothing jumps at rest, no cols × rows overlay. The sidebar's animation holds frames the same way and changes the grids once it settles (`TerminalSurface.prepareResize`, `holdFrames`, `structuralSettle`) |
| lift beat | 1.03 floating, 0.985 docking, on `micro` until `arrivalDelay`, back to 1 on `structural` by `structuralSettle` | the pane coming towards you as it lifts, pressed in as it docks; off under Reduce Motion |
| resize overlay | visible 750 ms after the last change | cols × rows (Ghostty `resize-overlay-duration`) |
| toast | 2.4 s; failures 4 s; with an action 5 s | |
| agent toast | 8 s, held while the pointer or a finger is on the stack, +0.5 s after | needs you / finished / failed, max 3, newest at the bottom |
| shimmer | `Loop.shimmerPeriod` 3 s sweep, 6-glyph cosine band, secondary → full ink | a working agent's title (sidebar, Agents); plain text under Reduce Motion |
| feedback delay | 200 ms before any progress UI | |

Only the working spinner (`Loop.spinnerPeriod`), the working shimmer and the secure-input
gradient (`Loop.secureInput`) loop, with the typing dots and a knock's waiting dot, which only
pulse opacity; under Reduce Motion they all stand still (and still read as "working"). The spinner and shimmer are Core Animation on a layer (`LayerAnimations.swift`): the
render server draws them, no view body runs per frame, they stop off screen, and the app reaches
idle. UIKit and layer animations use the same springs (`Role.layerAnimation(keyPath:)`,
`Role.timingParameters`, `UIView.animate(DS.Motion.standard)`).

`MotionLintTests` (DesignSystem) fails on any literal curve, spring, duration or delay outside
`DS.Motion`, and on `.transition` used directly instead of a named one; a line may opt out with
`motion-lint-allow:` and its reason (the keyboard following the system's own duration, TerminalKit
below DesignSystem, the Duo's deck rising its full height). `MotionTests` checks every role is
critically damped, never reverses and settles within its budget, and drives each named transition
on a sampled clock to check it only fades, grows and travels, settles in time and never changes
layout.

### Haptics (iPhone/iPad, touch only)

| Token | Feedback | When |
|---|---|---|
| `select` | selection | tab/pane change by touch |
| `structure` | light impact | split, close, divider snap |
| `success` | success | approve, pair, toast success |
| `attention` | warning | deny; an agent becomes blocked while visible |
| `failure` | error | connection failed, toast failure |
| `armed` | rigid impact 0.6 | a full swipe armed (letting go runs it) | iOS Mail |

### Shadows and edges

Two shadows (`.float`: r 16, y 6, 12 % light / 35 % dark; `.panel`: r 28, y 12, 16 % / 45 %),
never a third, and only through a surface (below). Edges are one physical pixel: `edge` inside
(as Ghostty's key pill), `outline` outside.

### Surfaces

Depth comes from one recipe, `Surface` (`Tokens/Surface.swift`), applied with
`.surface(_:in:)`: a fill, one physical pixel of `edge` inside the shape, one of `outline` just
outside it, a faint `topLight` along its top (a stroke masked to fade out within 24 pt, not
another shadow) and at most one of the two shadows, on continuous corners. No surface draws its
own stroke or shadow (`StyleLintTests`).

| Surface | Fill | Inner edge | Outer edge | Top light | Shadow | Use |
|---|---|---|---|---|---|---|
| `tile` | the terminal | - | - | - | - | a compact pane (its boundary is the split's line), a docked pane |
| `pane` | the terminal | ✓ | ✓ | ✓ | - | a comfortable pane: opaque, never glass |
| `window` | the terminal | ✓ | ✓ | ✓ | `panel` | a floating pane and the card under a window of several, picture in picture |
| `card` | glass | ✓ | ✓ | ✓ | `float` | `floatingCapsule`, `floatingPanel`: toasts, notices, the update card, reconnect, control-request, knock and secret cards, a sidebar row being dragged |
| `panel` | glass | ✓ | ✓ | ✓ | `panel` | `floatingPanel(elevated:)`: the command palette, workflow forms |
| `selection` | `selectedFill` | ✓ | - | ✓ | - | the selected tab's pill in the strip |
| `mark` | `tile` (`text` when selected) | ✓ | - | ✓ | - | a program mark's tile, everywhere marks are drawn |

- **Light and dark.** On dark chrome the edge and the top light add light (plus-lighter: the ink
  at 16 % and 14 %); on light chrome the edge is the ink at 8 % and the top light white at 60 %,
  a bevel that only shows on a surface darker than paper, so light themes get the subtler one.
  `outline` is the scrim's darker ink at 10 % (light) / 50 % (dark).
- **Increase Contrast.** The inner edge is `border` (the ink at 20 %) at full strength, even in an
  inactive window, and the top light goes: firm, flat edges.
- **Reduce Transparency.** Glass is the chrome's paper, opaque (`GlassSurface`); edges, light and
  shadow stay.
- **Inactive window.** A window that is not key (`appearsActive`: the Mac's key window, the iPad
  scene that is not foreground active) recedes: edges at half strength, no top light, `panel`
  becomes `float`, the selected tab's pill drops to the hover fill, the selected sidebar row to
  the soft accent, and unfocused panes dim further (their opacity × 0.85). The terminal grid's
  own colours never change.

### Checks

- `StyleLintTests` (DesignSystem) reads every source file of the app and the packages and fails on
  a raw or system colour, a literal opacity on a colour, a literal corner radius, a corner that
  is not continuous or a half-point line outside the token files, and on a shadow, glass or a
  surface edge drawn outside `Surface` (the recipe's own files); `everyNamedSurfaceIsBuiltByTheRecipe`
  checks that each surface named in Surfaces is built with `.surface` (or `floatingPanel` and
  `floatingCapsule`, which are surfaces). Content that is not chrome
  (the camera, a QR code, the pencil's ink, the system keyboard's keys, masks) says why on the
  line: `// style-exempt: <reason>`.
- `ThemeStressTests` holds the colour guarantees above over every Ghostty theme.
- `SurfaceTests` holds the recipe: which surfaces are edged, lit, opaque or glass, the two
  shadows, and the inactive, Increase Contrast and Reduce Transparency variants.
- `DesignGalleryTests` (AppTests, Mac) renders the tokens, every surface of the recipe, every
  control state, chips, toasts, the update and reconnect cards and the palette, and the window
  (with a floating pane too) in the compact and comfortable pane styles,
  dark and light, active and inactive, with and without Increase Contrast:
  `TEST_RUNNER_GUDO_DESIGN_GALLERY_DIR=<dir> TEST_RUNNER_GUDO_MOCK=1`.
- `InteractionGalleryTests` (AppTests, Mac) renders the palette, the switchers, toasts (each
  position) and the Appearance and Terminal Settings panes, dark and light, under each of
  Increase Contrast, Reduce Transparency, Differentiate Without Color and Reduce Motion, and split
  windows with each pane emphasis: `TEST_RUNNER_GUDO_INTERACTION_GALLERY_DIR=<dir>`. An offscreen
  window cannot draw Liquid Glass, so the palette's contents show in the Reduce Transparency
  captures. Every gallery skips unless its folder is set.

## Components (DesignSystem)

| Component | File | Notes / reference |
|---|---|---|
| `StatusIndicator`, `Spinner`, `StatusPill`, `CountBadge`, `AgentState` | `Components/AgentStatus.swift` | OSC 7501 states: idle ring, working spinner, blocked `!`, done ✓, error ✕, no contact dashed ring. Shape carries meaning, not only color. `AgentState.mostUrgent` orders blocked, failed, working, done, no contact, idle |
| `StatePill`, `StateDot`, `StateMark`, `.stateDot(_:tileSize:)`, `.attentionWhenBlocked(_:isVisible:)` | `Components/StatusMarks.swift` | the state language (Program marks and status, below) |
| `ProgramMark`, `ProgramTile`, `TileArtwork`, `ProgramTileTint`, `ProgramCatalog` | `Programs/` | a program's mark, its tile, the tint setting, and process names to programs |
| `ListRow`, `SectionTitle`, `EmptyState`, `Hairline` | `Components/Rows.swift` | dense rows with fixed leading slot; empty states (glyph `title` large, 12, `title3` semibold + `subheadline` 4 apart, then the next step); one-physical-pixel lines |
| `.rounded(_:)`, `hairlineBorder(_:style:)` | `Tokens/Shapes.swift` | the one continuous rounded rectangle; a one-physical-pixel edge inside any shape |
| `HoverPopover`, `hoverPopoverFrame()` | `Components/HoverPopover.swift` | opens on pointer hover, closes 150 ms after the pointer leaves anchor and popover, tap toggles, a medium sheet on iPhone; system padding, 260-480 × ≤ 400 |
| `.lit(_:)` | `Components/Glass.swift` | a toolbar toggle that is on: the selected state (the ink at 10 %) behind the glyph |
| `BarButtonStyle` (`.bar`), `RowButtonStyle` (`.row`) | `Components/Glass.swift` | hover/press fills from `ControlState` (rows in its accent variant); iPad pointer highlight |
| `QuietButtonStyle` (`.quiet`, `.quietProminent`) | `Components/Glass.swift` | verbs inside rows, banners and cards: no chrome, secondary ink (accent for `.quietProminent`), hover and press from `ControlState`, radius `field`. Glass stays on bars and floating surfaces |
| `ControlState`, `controlFill(_:in:)`, `ControlFillShape`, `ChromeStyle.disabled` | `Components/ControlStates.swift` | the one interaction scale every button style and hand-drawn control uses: rest clear, hover / selected / pressed the ink at 5 / 10 / 15 % easing with `micro`. The accent variant (`tint: .accent`) keeps hover neutral, presses with `accentDim` and selects with `selection`. A push button's bezel is its selected state. Disabled drops the fill (keeping a selection) and steps the ink down once (never below `textTertiary`, never by opacity) and its tooltip says why. No component has its own alphas |
| `fieldSurface(isFocused:)` | `Components/Fields.swift` | a text field on a page (Hosts quick connect): the raised surface, a hairline edge, the accent's edge and the `accentRing` halo while focused; typed literals in SF Mono, the prompt in prose |
| `Surface`, `.surface(_:in:fill:interactive:)` | `Tokens/Surface.swift` | the one recipe for depth; see Surfaces |
| `SwipeAction`, `SwipeActionTray` | `Components/SwipeActions.swift` | swipe actions beside hand-drawn rows, as `List` draws its own since iOS 26: a tinted circle per action (28-48 pt, as the row allows) with the symbol in the label that reads on it (`on(_:)`), the word under it on tall rows, the theme's signals in Mail's vocabulary (red ends, amber stops, blue goes, green completes, violet edits, bright yellow pins; never grey), scaling in with the reveal; armed, the outermost stretches into a capsule |
| `HostSwitcher`, `HostSwitcherLabel`, `HostSwitcherHost`, `HostSwitcherCommand` | `Components/HostSwitcher.swift` | a session popup for hosts: "Filter or connect…", hosts with ⌃⌘N and ✓, a highlight that follows ↑/↓ and the pointer, then commands with their shortcuts; typing an unknown address offers Connect to it; ↩ chooses, esc closes, the key hint bar at its foot; a host that needs you carries an amber dot, an amber ! under Differentiate Without Color |
| `floatingPanel`, `floatingCapsule`, `phoneDetents` | `Components/Glass.swift`, `Sheets.swift` | glass `Surface.card` (`Surface.panel` when elevated); bottom sheets only on iPhone |
| `ShortcutLabel`, `KeyCap` | `Components/KeyCaps.swift` | Ghostty `ShortcutSymbolsView`, `KeyCap` |
| `ChromeAccessibility`, `\.chromeAccessibility` | `Components/ChromeAccessibility.swift` | the one reading of Reduce Motion, Reduce Transparency, Increase Contrast and Differentiate Without Color for hand-drawn controls: `transition(_:)` (only the fade under Reduce Motion), `travel(_:)` (no animation for a highlight sliding between rows under Reduce Motion), `surface(for:)` (opaque under Reduce Transparency), `style(_:)`, `ring` and `ringPixels` (the accent at two pixels under Increase Contrast), `marksStateWithShape` (a state in a hue also gets its own shape and word) |
| `KeyHintBar`, `KeyHint` | `Components/KeyHintBar.swift` | the foot of every list popover (palette, host and people switchers): a hairline, then key caps and a caption in `meta`, ↑ ↓ Move and ↩ plus what it does on the highlighted row (Run, Switch, Connect, Open, Follow, Stop Following) leading, esc Close trailing; 30 pt; only where there is a keyboard (always on the Mac, a hardware keyboard on touch); one element for VoiceOver with the keys named |
| `ActivePaneRing` | `Overlays/PaneEmphasis.swift` | the opt-in active-pane ring (Splits, panes) |
| `Toast`, `ToastCenter`, `toastHost`, `Banner`, `ToastPosition` | `Components/Toast.swift` | one at a time; a `person` (joined, left) leads with their avatar instead of the symbol; a glass capsule at the user's `toast-position` (Settings › Appearance › Toasts: bottom left, the default; top right, under the pane headers; bottom centre), 16 pt from the content edges, arriving from and flicked back to its edge; the agent cards stack in the same corner and banners clear them at the top as at the bottom. Reduce Motion: it only fades; Reduce Transparency: opaque; Increase Contrast: a `border` edge; Differentiate Without Color: a success or failure always shows its symbol and a failure's disc is square; VoiceOver hears "Failed:" before a failure. At the bottom leading edge, 16 pt from the content edges (never over a pane's top bar: address bar, editor bar, pane headers; above the dev-server offer, the iPhone tab bar and cards at the bottom of a pane such as someone's draft, `toastObstacle()`), edge and float shadow; the symbol in a 24 pt disc on its container; one line (failures two); the action in accent semibold after a hairline; tap or flick down dismisses; taps beside it pass through |
| `ShimmerMath`, `.shimmering(_:text:)` | `Components/Shimmer.swift` | "working" on a title instead of a spinner |
| `PresenceAvatar`, `PresenceStack`, `Participant` | `Components/Presence.swift` | initials on ANSI hues, typing ring, +N; stacks at any size, each avatar cutting a thin gap out of the one under it so they read on any background |
| `PeopleSwitcher`, `PeopleSwitcherPerson` | `Components/PeopleSwitcher.swift` | the presence button's popover in the host switcher's form: "4 people here", one row per person (avatar, what they are doing, ✓ on the one followed; a tap follows or stops), then Share Session…; ↑ ↓ move, ↩ follows or stops, esc closes, with the key hint bar |
| `.switcherRow(isHighlighted:in:)`, `SwitcherCheck` | `Components/HostSwitcher.swift` | the switchers' shared row: 36 pt, the sliding highlight, the ✓ slot |
| `KeyBarLook` | `Components/KeyBarLook.swift` | the key bar's look (app passes it as `KeyBarStyle.designSystem`) |
| `ResizeOverlay`, `ProcessExitedBar`, `BellBorder`, `UnfocusedDim`, `SecureInputBadge`, `URLHoverBanner` | `Overlays/TerminalOverlays.swift` | Ghostty `SurfaceView.swift` 1:1 |
| `TerminalSearchBar` | `Overlays/SearchBar.swift` | Ghostty `SurfaceSearchOverlay` 1:1 (glass instead of opaque) |
| `CommandPalette`, `PaletteCommand`, `FuzzyMatch` | `Overlays/CommandPalette.swift` | Ghostty `CommandPaletteView` with sections |
| `ConnectionState`, `ConnectionDot`, `connectionOverlay` | `Overlays/ConnectionOverlay.swift` | health in words; never blank |
| `TerminalTheme`, `ThemeCatalog` (463 themes), `TerminalPreferences` | `Terminal/` | Ghostty theme files and config keys |

## Program marks and status

One language for who runs in a tab and what it is doing, the same in the sidebar, the tab strip,
pane headers and the palette.

- **Tiles.** A program's mark sits on a small tile (`ProgramTile`): the `tile` fill, a hairline
  edge, a one-pixel `edge` light along its top, continuous corners (`chip` up to 20 pt, `field`
  above). The mark on it is unchanged: an official logo as its owner publishes it, else our own
  glyph (`ProgramCatalog.glyphs`: pi's π, opencode, Amp; simple drawings, not those programs'
  artwork) or the kind's SF Symbol in the ink. A selected row or chip keeps its tile (the row's
  fill marks it), its mark in full colour where quiet rows mute it. Settings ▸ Appearance ▸
  Program Marks: Original (neutral tile, symbols in the muted ink), Monochrome (symbols in the full
  ink) and Accent (`accentDim` tile, symbols in the accent).
  Marks stay legible on every tile in every tint over all themes (`ChromeContrastTests`).
- **Most urgent first.** A tab shows its panes' most urgent state, a collapsed project or a host
  its tabs': blocked, failed, working, done, idle (`AgentState.mostUrgent`).
- **Dot or pill.** Idle, working and done are a dot cut into the tile's bottom trailing corner (a
  gap around it, so it reads on any row): idle a ring in `textSecondary`, working in `working`,
  done in `done`. Blocked and failed are a compact pill after the title instead, "Needs you" and
  "Failed" in the state colour on its container (radius `chip`); in a narrow strip chip it keeps
  its symbol, `!` or `✕`. With Differentiate Without Colour the dot grows a little and done
  carries a check, so ring, disc and check read by shape alone; the pills are words.
- **Attention.** A tab turning blocked out of sight plays `attentionCue` once on its tile; nothing
  under Reduce Motion, and never focus.
- **Elsewhere.** Agent notifications carry the tile as their picture (`NotificationMark`, drawn in
  the chrome's colours). On the Mac, Settings ▸ Notifications ▸ Agents in the Menu Bar (off by
  default) shows the most urgent state's symbol in the menu bar and lists the agents that need
  you, most urgent and longest waiting first; choosing one opens its pane. Menus that take only
  an image (the iPhone tab switcher) show the state's `AgentState.symbol`.

## Brand

The product name stays a placeholder (`apple/Brand.xcconfig`, `crates/brand`); every visual brand
decision is independent of it, so a rename is one line.

- **Accent**: Ghostty's bright blue, see Color.
- **App icon**: `apple/App/Resources/AppIcon.icon` (Icon Composer, layered Liquid Glass). A
  graphite field (#333840 → #16181D), a white glass window frame split into three panes (the
  product: one session, split), and a solid block cursor in the accent in the first pane, its own
  glass layer so it catches light separately. Original artwork; no Ghostty elements.
- **Launch screen**: the terminal background (`LaunchBackground`), so launch never flashes white
  and the first terminal frame lands on the same color.

## Screens

Each screen can be opened directly for review: `-screen <name> -mock` (see Screenshots).

### Windows and widths

- Layout by window width, never by device (`WidthBucket`): under 600 pt the compact layout (one
  pane, the tab switcher, the floating tab bar), from 600 pt the sidebar with splits; 12 pt of
  hysteresis. An iPhone in portrait, Slide Over, a third or an 11" half of an iPad and narrow
  Stage Manager windows are compact; an iPhone in landscape, the iPhone Duo's inner screen, iPad
  mini and wider windows are regular. Crossing the boundary keeps the tab, the focused pane and
  its scroll position, and never shows the cols × rows overlay. On the iPhone Duo the fold
  arranges a regular window further (Foldable, below).
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
  detail column whose toolbar is the same in both: the sidebar toggle leading (Xcode's: over the
  sidebar a bare glyph beside the traffic lights with the title starting at the detail column;
  with the sidebar hidden a toolbar button before the title); the tab's name
  with a subtitle ("Local · 3 panes", or the host's name); presence avatars; one monochrome glass
  group with Hosts, Find, the pane menu and the command palette; the tab-placement toggle on its
  own. Never accent-tinted. `ChromeUITests.testToolbarIsTheSameInBothTabPlacements` compares the
  buttons' frames in both placements and attaches screenshots.
- The title's subtitle is the tab's context (agent task, program, `repo:branch` or directory)
  when it differs from the title, then "3 panes". Find is lit with the ink at
  20 % while the search bar is open. The host button is a title-bar picker: symbol,
  name and a small chevron; it opens the host switcher (`HostSwitcher`): every host
  with its device symbol, ✓ on the window's and ⌃⌘1…⌃⌘9 (⌘1…⌘9 stay the tabs'), a word only
  when the link is not fine or agents wait (else the address, SF Mono), then New Tab, New Agent…,
  Connect via SSH…, Pair with a Ticket…, Join a Session… and All Hosts; only the hosts scroll.
  Typing an address no host matches offers Connect to it. Every icon control has a tooltip with its shortcut.
- The toolbar background is hidden: the sidebar color runs up behind the traffic lights and the
  terminal background behind the rest. The window title's folder is the proxy icon
  (`navigationDocument`) for local tabs.
- Switching to vertical tabs always shows the sidebar; covered by
  `testSidebarAppearsAfterSwitchingFromTabStrip` and the `toggle` screenshot fixture. The divider
  drags to resize (200-360 pt, double-click restores 248).

### Sidebar (vertical tabs)

- Agents (count badge, red only when something needs you) and Hosts at the top. Under a
  host's tabs, its agents under a quiet "Agents" label with + New Agent on that host (hover on
  the Mac, 0.6 on touch).
- Projects first (like Safari's tab groups; docs/APP-ARCHITECTURE.md
  §23): a header with the project's colour dot (`ProjectColor`, the theme's ANSI hue softened like
  the states), its name as a quiet section label (the section font in the secondary ink) and
  + New Terminal; its tabs under it, each naming its host on the second line. The colour stays in
  the dot: rows carry no stripe of it. Drop a tab
  on another to group them (the row lights in the colour), between rows to place it (the rows
  slide apart with `DS.Motion.standard`; the dragged row leaves a gap, never slides over others).
  A one-tap "Group 3 tabs in app" suggestion when loose tabs share a repository. The strip draws
  a project's colour under its tabs.
- Tab history (APP-ARCHITECTURE §25), in the suggestion's voice at the top of the list: one
  quiet line each, glyph, the verb in secondary ink, a dismiss ×, the meaning in the tooltip.
  "↺ Restore 6 Tabs" while tabs a launch under "A New Terminal" kept aside still run; "Close 6
  Idle Tabs" (`moon.zzz`) for tabs at a prompt untouched for 3 days. Never a card, never
  automatic.
- Several tabs selected (⌘-click toggles, ⇧-click a range, ⌘A, Esc ends; on touch the row
  menu's Select Tabs): the rows take the `selection` tint (the accent at 14/24 %) under their
  own fills; in touch Select mode a trailing check circle (accent when on) replaces the active
  fill. A bar under the list says "3 Tabs" with ⋯ (Close Tabs, New Project from Tabs, Move to
  Project ▸, Select All) and Done. A selected row's context menu is the selection's. Dragging a
  selected row carries the others: they land in a run right after it with the same reorder
  spring. On iPhone the switcher's Select Tabs… opens a sheet with the system's multi-select
  list and the same actions.
- Then one group per host the window shows (its loose tabs), all at once (switching hosts never
  goes through the Hosts screen): This Mac first (macOS only), then each open daemon and plain-SSH
  host in the order it was opened. Group header: `server.rack`
  (`laptopcomputer` for this Mac) in `.secondary`, the host's name in the section font
  (`.primary` when live, `.tertiary` when not), an "SSH" outline badge for plain-SSH hosts, the
  host's most urgent agent state (its dot or pill), a state glyph **only when not live** (§3.3: reconnecting
  `arrow.triangle.2.circlepath` amber, offline `wifi.slash`, can't connect
  `exclamationmark.triangle.fill` red, a mini spinner after 1 s while dialling; each labelled with
  its copy), and + "New Terminal" (quiet until hover on the Mac, always on touch). No dots, no
  status text. Tapping the header collapses the group (a collapsed group shows its tab count).
  Rows of a host that is down stay, at 60 %. Context menu: New Terminal, Collapse, Retry Now
  (only when not live), Show in Hosts, Disconnect.
- A host with no tabs shows one row "New Terminal" (`plus` in `.secondary`) under its header
  (§3.5); the terminal area shows the welcome view with New Terminal ⌘T, never a void.
- One row per tab: its number across all hosts (tertiary, monospaced), a leading slot (16 pt on
  the Mac, 18 on touch), the tab's name (one weight; a path keeps its end). The slot
  holds the focused pane's program tile (Program marks and status: the official logo,
  unmodified, where one ships, else our glyph or a neutral SF Symbol per kind), with the tab's
  most urgent quiet state as a dot on it and "Needs you" or "Failed" as a pill at the row's
  trailing edge. Every row has the slot so titles align. The live context in SF Mono underneath, under the title, ⌘N on the Mac (⌘1-8 index the
  unified list; numbers do not change when a group collapses or a host goes down). Selection is a
  10 % fill of the theme's ink with radius 8 (hover 5 %), never the accent. Drag to reorder or group; context
  menu Rename / Close / New Project from Tab / Move to Project ▸. Under a group's tabs, its agents. Rows touch (no gap); the host's agent
  glyph opens its agents on hover (`HoverPopover`). On iPad the sidebar's bar holds Settings (⌘,)
  and New Tab only: no app name.
- Footer: Settings only (no connection summary, §3.7 rule 1).
- Tab strip: one scrolling row of chips, leading-aligned, each an equal share of the strip
  between 160 and 240 pt. Adding a tab never moves the chips already there: they keep their
  width (the strip scrolls to the new one) until the pointer leaves the strip or the window
  resizes; a close under the pointer keeps the width the same way. The selected chip has its
  own fill (no sliding pill); only the two chips involved change. A tab's terminal replaces
  the shown one once it has drawn its screen (at most 300 ms), never a blank terminal.
- Tab strip: a single-host window shows no host; with tabs from several hosts, each tab gets the
  host's name as a second line (`meta`, `.tertiary`).
- iPhone: the bar shows the tab's title with the host's name as a second line (state glyph after
  it only when not live); the title menu lists every host as a section with its tabs and
  "New Terminal on …".
- New things start from one +, a menu on tap (never a hidden long press): the sidebar's has New
  Terminal ⌘T, New Agent… ⇧⌘N, New Terminal On ▸ (several hosts), Add Host…; a daemon host's
  header + has New Terminal and New Agent… on that host; Agents' + leads with New Agent…. One
  name everywhere (File menu, palette, welcome, sidebar): New Agent. Terminal toolbar: a pencil "Draw"
  button next to the pane menu (⌃⌘D), disabled where the focused pane cannot be drawn on.
- Tab names: every new tab gets a short friendly adjective-noun name ("quiet-otter",
  `Workspace/FriendlyName.swift`, curated lists), stable, and sent to the daemon as a rename so
  every device shows it. A user rename always wins. The context line is the agent's task, else
  the foreground program, else the program's OSC 0/2 title, else `repo:branch` (local), else the
  directory. Settings ▸ "Tab Title from Shell" (`title-from-shell`) lets an OSC title (else the
  directory) replace a generated name. Under shell integration (OSC 133) the OSC title counts
  only while a program holds the alternate screen (`Terminal.shownTitle`): the shell retitles the
  terminal for every command, so a quick `ls` would otherwise flash its name. This follows the
  terminal's state in stream order, never a delay; a long command without a screen of its own
  shows on the running-command line instead.
- A group's agents: every pane of that host whose program reports status, across its tabs:
  glyph, program, tab number, state word right-aligned in its color. Tap
  focuses the pane, switching hosts if needed.

### Tab strip (horizontal tabs): Ghostty native tabs

Equal-width tabs across the row; centered title led by the same slot as the sidebar
(the program tile with its state dot; a pill after the title for
what needs you); ⌘N right-aligned only while ⌘ is held;
close button on hover at the leading edge; one-pixel separators between unselected tabs (none
beside the selected one); one title weight (callout on the Mac, subheadline on touch), inactive
tabs the same ink at 0.7 opacity (0.85 hovered); the selected tab a pill, `Surface.selection`
(the ink at 10 %, its edge and top light, radius `field`; the ink at 5 % in an inactive window), moved with `matchedGeometryEffect` (easeInOut 0.15); + at the end.
After a close under the pointer the tabs keep their width until the pointer leaves the strip;
⌘ hints appear after ⌘ is held 750 ms; a path title keeps its end; the tooltip is the
title, host · directory, and the context line. The strip stays with a single tab (it carries + and the drop target).
The strip sits under the shared toolbar (Mac and iPad alike) on the window base (the terminal
background) with a one-pixel `separator` rule. Drag
tabs to reorder.

### Splits, panes, overlays: Ghostty 1:1

- Dividers 1 pt in the split-divider color, 7 pt hit area with resize pointer on Mac, 20 pt with
  pointer highlight on iPad; double-click/tap equalizes; adjustable for VoiceOver ("Horizontal
  split divider", ±2.5 %). Split sizes snap to whole cells (main's `SplitSnapping`).
- No focus ring by default. Unfocused panes are dimmed with the background at 1 − `unfocused-split-opacity`.
- Pane emphasis, opt-in (Settings › Appearance › Panes): `pane-active-border` draws
  `ActivePaneRing` around the focused pane in a split, one physical pixel of `accentRing` inside
  its edge (the pane's own corner radius), the accent at two pixels under Increase Contrast,
  fading in and out on `micro`. `pane-inactive-fade` sets how an unfocused pane recedes: Dim (the
  default, Ghostty's whole-pane dim), Dim Header Only, or None. Off and Dim are as Ghostty.
- Pane header (only in splits, 24 pt, on the terminal background): program tile with its state
  dot, program's display name, its account ("· ● Work", only when that agent has more than one account
  on the host), "Needs you" or "Failed" as a pill and the program's own words, an "At Limit" mark in the attention colour
  whose menu offers a new tab under another signed-in account, and the pane menu (… on
  hover/focus on the Mac; at 0.6 on touch, where there is no hover). Tap focuses.
- Shell commands (OSC 133, daemon panes): a gutter stripe per command (red when
  it failed), a failed command's rows tinted with the theme's red at 6 %, its ✓ / ✗ exit and run
  time at the right of its prompt row on hover, and the command whose output fills the top of the
  pane pinned there as a small header while you scroll.
- Overlays on the grid: cols × rows centered while the window resizes or a divider moves from
  the keyboard (hidden while a divider is dragged, where the panes moving under the pointer are
  the feedback, and while the software keyboard moves); process-exited bar at the bottom (red 50 % on failure,
  hides under the pointer); secure-input badge top-right; bell border; hovered URL bottom-left;
  scrollback search bar top-right (draggable to any corner).
- Comfortable pane style (Settings → Panes): inset rounded panes on the window's own base surface (no field of its own whose square edges meet the chrome),
  each a `Surface.pane` (opaque, its edges and top light, no shadow). Compact panes are tiles:
  the split's one-pixel line is their only boundary.

### Floating panes, rearranging, zoom

docs/APP-ARCHITECTURE.md §28 has the model. One canvas per tab (`PaneCanvas.swift`): every pane,
tiled or floating, is one view keyed by its id, so floating, docking, zooming, dropping and
minimizing only move and resize views in one `structural` spring, and no terminal is ever rebuilt.

- **Header buttons** (every pane while more than one shows, the zoomed one included): Split
  Right, Split Down, Float/Dock (lit in the accent while floating), Minimize (windows only),
  Zoom (lit while zoomed: the way back), Close, then ⋯ with the pane menu. Quiet: hidden until
  hover or focus on the Mac, 0.6 on touch. Each has its shortcut in the tooltip. Double-click
  the header zooms. Right-click: Reset Terminal, splits, Float/Dock, Minimize, Pin Across Tabs,
  Zoom, Pop Out to Window, Copy Pane ID, Close.
- **Drag to rearrange.** The header is the handle (6 pt to start). The pane dims to 45 %, a
  glass chip with its mark, name and directory follows the hand, and the canvas shows the drop
  before it happens: the other panes make room in the `standard` spring (as pictures of their
  last frame) and the dragged pane sits where it will land, lit by a region in `accentDim`
  with a 1.5 pt accent rim (radius `pane`, inset 4). That region is exactly the frame the drop
  gives (worked out by applying the op to a copy of the session), so a pane dragged out of a
  two-pane split onto its sibling's left half lights the tab's whole left half, as it will be.
  The zones are the panes as they were when the drag began, so panes making room never move
  them: over a pane, the half on the side nearest the pointer by the diagonals; along the tab's
  edge (28 pt), the whole edge, a third deep; on the Float target (a glass capsule at the top
  centre, below the pane headers, prominent while over it) or outside the tab, a window where
  it was let go. Over itself: nothing. A zone holds until the hand is 12 pt past its boundary,
  so it never flickers between two. On drop the preview stays until the host has moved the
  pane, then the region fades; nothing moves, since it is already there.
- **Floating windows.** A `Surface.window` over the tab: corners `pane` (12), opaque, its edges,
  top light and the `panel` shadow, a one-point accent rim while it has the focus; a window of several panes draws its
  panes on a divider-coloured backdrop with a 14 pt grip on top. The header of a one-pane
  window moves it; edges and corners resize it (system resize pointers, 6/14 pt on the Mac,
  14/28 on touch, never under 240 × 140). It snaps (10 pt) to the tab's edges at an 8 pt
  margin, its halves and thirds and other windows' edges (aligned or 8 pt apart), with a 1 pt
  accent guide per snapped edge; a flick carries it as far as a scroll view would and it
  settles in the `structural` spring. Held 0.38 s over a pane's outer quarter, it offers to dock there (the same exact
  region); letting go docks it. Focus raises; new windows cascade 4 % down and right.
- **Float transition.** The pane lifts out of the tree to its window frame while the panes
  beside it expand into its space in the same spring, the lift beat and the shadow growing
  with it. Docking runs it backwards. The pane that changes layer travels as a still of its
  last frame (a platform view neither scales nor fades with SwiftUI), crisp, at its own
  pixel size; the panes making room keep their grids through the motion (their last frame
  stays, clipped or padded). Everything reflows once at rest: no flicker, no cols × rows
  overlay.
- **Tray.** Minimize (⇧⌘M, the header's minimize button) sends a window to a row of glass capsules at the
  tab's bottom right (188 × 28 Mac, 204 × 36 touch, 6 apart, wrapping upwards): its mark, name,
  `+N` for more panes, its live state glyph. Going, the window shrinks onto its chip, solid
  until the end; a click brings it back the same way, growing out of the chip to where it was,
  to the front (macOS's genie, without the bend). A window in the tray keeps its size, so its
  terminals keep their grids: the program, and every other device, sees no resize. ⌥⌘F hides
  every window for a look underneath.
- **Zoom** (⇧⌘↩, the header's button, double-click): the pane grows over its neighbours to
  take the tab (or its window, in a window of several) in the `structural` spring, a picture of its
  last frame on the way, and the windows step aside; zooming out it shrinks back onto them. Its
  header stays,
  with Zoom lit as the way back, and the title's subtitle says "Zoomed".
- **Keys** (Pane menu, palette section "Pane", the ⌘-hold overlay): Float/Dock ⌥⌘↩, Minimize
  ⇧⌘M, Next Window ⌥⌘], Hide/Show Windows ⌥⌘F, Focus Next/Previous Pane ⌘] / ⌘[, Move Pane
  ⌥⇧⌘ arrows (a tiled pane trades places past its neighbour, a window steps a twelfth), Resize
  ⌃⌘ arrows (a window grows a twenty-fourth), Split Best Fit ⌘↩, Zoom ⇧⌘↩.
- **iPhone: picture in picture.** In compact width the focused pane shows alone and each other
  window is a 176 × 120 live miniature (the grid drawn at half size, never resized) resting in
  a corner, radius `pane`, glass edge, `panel` shadow, its mark and state on top. Drag
  or flick it to any corner; tap brings it full screen. On a foldable no corner crosses the
  fold: they sit in the half the window's centre is on.

Screenshots: `MacSnapshotTests.testFloating*` (`floating`, `-multi`, `-tray`, `-zoom`, `-guides`;
`-ipad` at 1024 × 768; frame sequences `floating-{drag,drop,lift,dock,minimize,restore,split}-N`,
the last of each at rest after the reflow) and `TouchSnapshotTests.testFloating` (iPad, iPhone
picture in picture), fixtures `-screen floating|floating-tiled|floating-multi|floating-tray|
floating-zoom` (`Model/FloatingFixtures.swift`). Layout motion: `MacSnapshotTests.testTransitions`
(`zoom-{columns,rows}-{in,out}-N`, `split-columns-N`, `close-columns-N`, each ending `-rest`;
two shells at a prompt with a right-aligned clock, `-screen transitions-columns|transitions-rows`,
`Model/TransitionFixtures.swift`) and `testDragPreview` (`drag-preview-N`, `drag-drop-N`: two
stacked panes, the lower dragged onto the upper's left half). Off a display (a locked Mac) the sequences are
drawn at points along the `structural` spring (`CanvasLayout.blended`) and each terminal is drawn into
the capture from its own frame, since such a window gets no animation or display-link frames.

### Key bar (iPad, iPhone)

Keys read as part of the iOS 26 keyboard: no strip behind them, glass rounded rects at the
keyboard's key height and radius, SF Pro labels at its size, wider gaps between groups (esc tab ·
ctrl · arrows · symbols · profile), the latched Ctrl as prominent glass. Always dark, like the
terminal's keyboard. With a hardware keyboard, the 28 pt strip (main's behaviour). Profiles,
composer and snippets are main's (`App/Sources/KeyBar`), skinned through `KeyBarStyle`.

### iPhone

A Liquid Glass tab bar: Terminal · Agents (badge) · Hosts; it minimizes on scroll. The terminal tab
is one pane full screen under a 36 pt bar on the terminal background: connection dot, tab title
with ▾ (switcher menu with tab count), pane switcher when the tab is split, palette, new tab.
Settings is in Hosts' toolbar.

### Foldable (iPhone Duo)

Each posture has a job. The posture is read from the hinge and the fold's division region
(APP-ARCHITECTURE §24), never guessed from size. Apple's own rule leads: small
adjustments over rearrangement, nothing interactive under the fold.

| Posture | Screen | Job | Layout |
|---|---|---|---|
| **Closed** | cover, 466 × 678 | glance and act: which agent needs you, approve, a quick reply, a key or two | the iPhone layout. The system's vertical bar on the trailing edge carries Terminal · Agents (badge) · Hosts; the terminal keeps the rest of the width. |
| **Open flat, wide** | inner, 951 × 669 | the iPad-class workspace | pages: the sidebar is the left page (projects, agents, tabs; rows get the room for their second lines), the tab the right. With the sidebar hidden, two tabs, one per page (Two Columns). A 12 pt band with a split divider down its middle sits over the fold. |
| **Book** (partly open, fold top to bottom) | inner, held wide | list or Inbox on one page, the session on the other | the same pages, so opening into a book does not reflow. The band widens to the division's margins and its line goes, since the crease is the divider. Two tabs never share one page across the fold. |
| **Laptop / tabletop** (partly open, fold across) | inner, held tall | read above, act below | the tab fills the upper screen, without the sidebar. The lower screen is the deck: the Agents list with Approve · Deny · Reply under the thumbs, and a Keyboard button. The keyboard and key bar rise over the deck only, so the terminal above never reflows. |
| **Open flat, tall** | inner, 669 × 951 | a tall iPad-mini | the standard sidebar layout. A flat fold is no boundary for scrolling text (HIG); no control sits on it. |

**The fold's band.** Nothing is drawn over it but the window's base colour. Its width is the
division's frame with its margins while partly open (the device's own value), 12 pt over a flat
fold. Splits live inside a page, so no split divider can land on the crease. Pages are the
hardware's halves, not resizable: no divider handle on the fold (HIG: split views settle at
50/50). A page holds at least a phone (320 pt) or the window stays whole.

**Continuity.**
- Folding, unfolding, opening into a book and standing it up keep the tab, the focused pane, its
  scroll position, the cursor and the composer draft.
- The views move rather than being rebuilt: the sidebar's width animates into the page and the
  deck rises from below in one `structural` spring.
- The grids reflow once as it settles. No cols × rows overlay, no blank frame
  (`snaps/duo/transitions`).
- Under Reduce Motion the layout changes at once.

**Input across the fold.**
- Pages: the key bar keeps to the page under the focused terminal, never across the crease, and
  follows focus to the other page.
- Deck: keyboard, key bar, composer and the agents' verbs are all on the lower screen.

**Drag between pages.**
- A page's header is a handle: drag it onto the other page and the two trade places.
- Drop any tab on a page's header to show it there.

**Worth adding, not yet built.** Each needs hardware to tune.
- *Cover glance on folding.* Closing with an agent blocked could bring its request forward on the
  cover. It must never move the pane you were typing in (continuity wins), so it would be the
  existing agent toast, not a switch.
- *Cover actions in the system bar.* Our 36 pt terminal bar is our own, so it stays horizontal on
  the cover. Its actions (switcher, palette, New) could join the system's vertical bar
  (`axisBehavior .verticalPreferred`) and give the terminal those rows back.
- *Deck as a trackpad.* In tabletop, a drag on the deck's empty area could move the terminal's
  cursor and selection above, like the keyboard's own trackpad.

**Rejected.**
- Anything driven by the hinge angle: Apple calls its rate and precision policy.
- Approving by folding: an action no one can see happening.
- Opting out of vertical bars: Apple asks not to, and our bars follow the system.

### Welcome / empty

No tabs: terminal glyph, "No Open Tabs", one sentence, then four rows with shortcuts: New Tab ⌘T,
New Agent… ⇧⌘N, Connect to a Host…, Command Palette ⌘K.

iPhone and iPad have no shell of their own: a fresh install opens here with "Connect a Host",
one sentence, and Connect with SSH…, Paste a Pairing Ticket…, Scan a QR Code…, Command Palette.
New Tab there opens Add Host. The local echo backend is only for UI tests (`-localEcho YES`),
`-mock` and the design fixtures; `ChromeUITests.testFirstLaunchShowsWelcomeNotAShell` guards it.

### Command palette (⌘K, ⇧⌘P)

Spotlight's placement (`spotlightOverlay`): centred on the window, its top a sixth of the way
down, over a light scrim that dims the find bar and everything else beneath. Glass on the theme's
paper (light) or raised surface (dark), a hairline edge and a soft shadow. A magnifier and the
20 pt light query "Execute a command…", a hairline, then compact one-line rows (40 pt touch,
32 pt Mac): the program's mark for tabs and agents (with the agent's state as a small badge) or a
symbol, the title, the subtitle inline in secondary, a badge, and the shortcut as small muted key
caps. Small tertiary section headers. The selected row is the soft `selection` tint, the text
unchanged. Empty query: sections Needs You → Tabs → Terminal → Go → Hosts. With a query: fuzzy
ranked flat list, matched characters bold. ↑↓ / ⌃P ⌃N move, Return runs, Esc or a click outside
closes. A `KeyHintBar` at the foot says so: "↑ ↓ Move", "↩ Run" leading, "esc Close" trailing.
Workflow forms open in the same place. Fixtures: `palette`, `palette-search`, `goto`,
`palette-workflows`.

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

Same surface as Agents (plain list on the base, inline title, hairlines from the text
column). Quick connect is a drawn field (28 pt Mac, 36 pt touch in a 44 pt hit area, radius 6, on
`raised` with a hairline, the accent edge while focused). Rows: kind glyph at 0.6 in a 16/18 pt slot,
name subheadline semibold, address SF Mono footnote tertiary, status footnote with only the state
word coloured ("Reconnecting" amber, "Can't reach" red), counts trailing in monospaced digits.

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

### Agents (`Screens/InboxView.swift`)

The window's own surface, not a stock grouped list: a plain list on the base,
one-pixel separators from the text column, an inline title with "2 need you · 3 new" as its
subtitle, the cross-host feed of every agent (named Agents, not Inbox: it lists agents, not
messages). Dense like a mail list. Filters All / Needs You / Running / Unread / Errors as a
compact track as wide as its words, left-aligned under the bar, never stretched across the
window. A row is two lines, 8 pt above and below:
a 16 pt glyph slot on the title's line (glyphs at 0.6 unless something needs you), what the
agent is on in subheadline (semibold while unread or waiting), a Failed pill for a failure,
right-aligned the unread dot, the age (monospaced, ticking for running) and Reply and Open as
quiet icons on the same line; under it the agent's 12 pt mark and "Claude Code · host · folder"
footnote tertiary. The last message is one more footnote line. Only a request grows the row: the
request block (SF Mono on `raised`, radius 6, hairline edge) and the verbs (Edit and Deny quiet,
Approve the one `.primaryGlass`). Section headers are footnote semibold with their count.

Needs you / Running / Finished. Permission requests show the tool and command with Edit, Deny
(quiet) and Approve (prominent); questions and finished turns offer Reply, an inline composer
that types into the agent. Empty: "No Agents Yet" with New Agent. Finished turns carry the
agent's last message; long commands appear with a check/cross glyph and "Exited 0 · 4m 12s".
The subtitle says "3 new · studio 2, devbox 1"; after 1.5 s on screen the dots fade (seen on
every device). Optimistic: an answered request moves to Running at once. Swipe Mark Done;
context menu Open Pane, Copy Prompt/Summary. New Agent sheet: agent, connected host and its
directory, New Worktree (+ branch), prompt (optional); Start shows "Starting…" and the sheet
closes as soon as the pane exists.

### Share session (`Screens/InviteSheet.swift`) and presence

Toolbar avatars (≤ 3 + N, typing ring; a share glyph when alone) open Share Session
(docs/APP-ARCHITECTURE.md §11), a grouped form on the terminal's background family:

- **Header**: tab name, "You and 3 others · you own this host", the others' avatars.
- **Invite** (owner): a name field; four role tiles (Viewer locked on, Prompter, Driver,
  Approver), each with an SF Symbol, title, one line of what it allows (selected = accent hairline + 10 %
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
read before dialling (inviter avatar, "Alex Kim invites you as Mira", each granted role with
its sentence, scope, expiry, devices, the host key), a display-name field, and "Join as
Driver" (prominent). Refusals say why (expired or used up, revoked, offline).

Mock screens: `-mock`, `-mockPresence YES`, `-mockRole …`, `-shareRoute …`. `MultiplayerUITests`
runs the same flow against a real daemon.

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
the palette's green/red. Side by side on iPad/Mac (empty cells a faint fill), unified on iPhone.
Code never wraps: one native horizontal/vertical scroll surface, 18 pt rows on Mac and scaled
rows on touch. `NativeDiffList` uses reusable `NSCollectionView` / `UICollectionView` items;
`DiffRenderDocument` prepares split pairs, note heights, stable identities and a prefix position
index away from the main actor. Position and pinned-header lookup are binary searches, never
scans from the beginning. Row geometry never feeds application state. Reload, note insertion,
collapse and width changes preserve the visible line and its intra-row offset, falling back to
the file header if that line disappears. Tap a line → an inline note composer; notes
are accent-tinted cards under their line; a floating glass bar "2 notes · Goes to Claude Code as
one prompt" with Copy and Send to Claude Code (⌘↩).

### Git workspace (`App/Sources/Git`)

The daemon's repository snapshot (docs/DAEMON.md §5.12) drives four surfaces.

- **Sidebar**: inside each host group, tabs outside a repository first (as before), then one
  section per repository: the name in the section style, `.secondary`, sentence case, no icon,
  + New Agent in that repository (hover on the Mac, 0.6 on touch), padding top 12 / bottom 4. Under it one row per
  worktree, main first: a 16 pt slot (18 on touch) with the branch glyph, or the pull request's
  glyph in its state colour (open green, merged purple from the palette's magenta, closed red,
  draft grey), at 0.6 with a 10 pt checks badge in the corner; the branch (body 13 on the Mac,
  subheadline 15 on touch, regular weight always) with the worktree's name under it in
  footnote `.tertiary`, hidden when it repeats the branch; then a fixed-size trailing cluster,
  6 pt apart: `+N −M` (caption, monospaced digits, palette green/red), `#PR` (caption
  `.secondary`), the agent glyph (none on the focused tab). Holding ⌘
  cross-fades the cluster to the row's ⌘N (0.15 s, no reflow). Rows: 6 pt vertical insets, title
  and subtitle touching, selection a neutral 10 % fill at radius 8, and on the selected row every
  coloured glyph and count drops to `.secondary`. A worktree with one tab is that tab's row; with
  several, the tabs follow one level in (14 pt); with none it is quiet and a click opens a tab
  there. Context menu: New Tab Here, Open on GitHub, Run ▸, Copy Path, Copy Branch Name,
  Rename/Close Tab, Archive Worktree…, Delete Worktree…. The ⌘1-9 order follows the rows.
- **Needs you**: above the hosts, a highlight section (6 pt amber dot at 60 % with a hairline,
  "Needs you") hoists every tab, on any host, whose agent waits or failed: glyph, tab, "host ·
  branch", the state word in its colour. The rows also stay in place below.
- **Toolbar**: next to the host button, the focused worktree's pull request: its glyph at 0.6
  with the checks badge and `#42` in subheadline `.secondary` (or the branch when there is none).
  Hover opens the popover and it closes 150 ms after the pointer leaves both (tap on touch; a
  sheet on iPhone). Then one glass group: Open In ▾ (VS Code, Files, Diff, GitHub) and Run ▾
  (the default script on click, ⌘R; the repository's scripts with their tinted symbols, then
  Global, then Edit Scripts…).
- **PR popover**: system padding, width 260-480, at most 400 tall, scrolls.
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
- **New Agent** (⇧⌘N; one sheet for agents and worktree tasks): Run (Claude Code · Codex · Shell, segmented), host,
  repository, New Worktree, the name (a friendly generated one, shuffle) and the branch (its
  placeholder is the branch the host derives from the name), "Runs setup first: `pnpm i`", the
  prompt. Start makes the worktree and opens its tab at once; the prompt is typed when the agent
  is ready.
- **Archive and delete** ask only when there is something to lose: "It has 3 uncommitted
  changes. They are kept with the archive and come back when you restore it." Settings ▸ Git:
  merge strategy, Delete Merged Worktrees (Never, 1, 3, 7 (default), 14, 30 days; sent to each
  host), global scripts (name, command, SF Symbol, tint, ⌘R).

`GitUITests` (`apple/scripts/git-ui-test.sh`) drives these on real data: a local daemon on
`git-fixtures.sh` with a stand-in `gh`. `apple/scripts/git-mac-screenshot.sh` has the app draw
the Mac sidebar itself.

### Files (`Screens/FilesBrowserView.swift`) and editor (`Screens/EditorView.swift`)

Files: on the terminal background; directories first (folder glyph in `info`), monochrome SF
Symbols per kind, the change letter in the palette's colour, size and age, symlink badge, push to
descend, filter, pull to refresh; + menu Upload Files… / New Folder; drop files onto the list
(dashed accent outline while targeted); a floating progress capsule for transfers. Context
menu Open in VS Code, Share…/Download, Copy Path, Rename…, Reveal in Terminal, Insert Path, Move
to Trash (confirmed). A file pushes a preview: text with a line-number gutter in SF Mono, images
fit, others a card with size and Download.

Editor: VS Code's own workbench as a pane of the split tree (a tab of its own, or beside a terminal;
APP-ARCHITECTURE §20) under a strip on the terminal background: 36 pt alone in its tab, a pane
header's 24 pt in a split, dimmed like an unfocused split when another pane has the focus: close,
`</>`, folder name, host in SF Mono, Reload, More (Copy Folder Path, Open in Desktop VS Code on the
Mac, Remote Tunnel, Stop Editor on host). Sidebar: a "VS Code" group above Mixed, each row the code
glyph, the folder name and its host. A suspended editor coming back shows its last picture at 55 %
under a "Resuming VS Code" capsule until the workbench is up. While it starts: a centred card of steps (Set up VS Code on
host (first run only) / Start the editor / Open the workbench), each with a check, spinner or
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

### Sheets and tool windows (Mac)

Form sheets use `SheetScaffold` (DesignSystem): on the Mac no bar, the title leading over the
content, which sizes the sheet, and Cancel plus the one default button bottom-right (Esc, Return;
a lone Done also closes on Esc); on iOS a nav stack with the inline title and the bar's
cancellation and confirmation slots. Fields are prompt-only and leading (no label-left,
value-right split), multi-line ones are `TextField(axis: .vertical)`. A form sheet opens as tall
as its form (`macFittedForm`; `fittedForm` also on iPad, where a short notice would otherwise
get a page-tall sheet) and keeps that size: rows a host sends later scroll inside or fill a slot
that was there from the first frame; only the user's own steps (a pasted link, another mode, an
error) resize it. Files, Changes, Ports and
Session Replays are tools you keep beside the terminal, so on the Mac they open as windows of
their own (`Windows/ToolWindows.swift`, ⌘W closes) with the title and actions in the titlebar;
iPad and iPhone keep them as sheets.

### Settings (`Views/SettingsView.swift`)

Ghostty's config as native settings; each control's Ghostty key is in its tooltip, in search
results and, on the Mac, under the label while ⌥ is held (never a permanent second line). Appearance: Theme (463 Ghostty themes, searchable, Dark/Light filter; each theme a
card in its own background with its name in its foreground, a prompt in its colours and four 12 pt
swatches (red, green, blue, yellow), the selected card ringed in the accent; the setting row
shows an "Aa" tile in the theme's colours and four dots), Window (`window-theme`), Sidebar Text
Size, Toasts (where they appear), Program Marks (Original, Monochrome, Accent). Panes: each choice a small card drawn in SwiftUI in the user's
own theme (two panes, the left one active, prompt lines in its ANSI colours), live as the other
settings change: Compact / Comfortable, then Dim / Dim Header Only / None for inactive panes,
then the Ring Around the Active Pane toggle; the chosen card ringed in the accent with a ✓ by its
name (`Views/PanesSettings.swift`).
Follow Light and Dark Mode (Ghostty's `theme = light:X,dark:Y`): a light and a dark
theme, each from the same picker; the system's appearance writes `theme` (`Views/ThemePair.swift`).
Font: JetBrains Mono, size stepper with live sample. Cursor: style, blink. Splits: unfocused
opacity, size overlay. Keyboard: Option sends Meta, ASCII keyboard, key bar profiles (rendered
from the real profiles). Notifications (on the Mac also Agents in the Menu Bar, off by default). Agents: Accounts (each host's Claude Code and Codex sign-ins; per agent a grouped list of rows with the account's colour dot in the project palette, its name, a quiet Default capsule, who it is signed in as on the second line, "Not signed in" in the attention colour, its tightest limit trailing in `meta`; actions in the context menu, Add … Account opens a name-and-colour sheet; APP-ARCHITECTURE §27), Agent Tools. Privacy & Security: App Lock ("Require Face ID", the grace period) and saved passwords; locked, every window shows the app icon, "<App> Is Locked" and one primary Unlock on the theme base (`Security/AppLockScreen.swift`, 1Password and banking apps). About and Acknowledgements. Mac: System Settings' shape (a full-height 220 pt sidebar under the traffic lights with search on
top, the pane's title once in the titlebar, a grouped form beside it, min 720 × 480); iOS: one grouped form. Both on the
theme's chrome. Values reach the renderer through `TerminalAppearance`
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
Return. Canvas panes show the same editor full size on the terminal background.

## Polish checklist

- [x] Terminal frames at the display's rate (ProMotion key set; renderer display link); chrome
      animations are critically damped `DS.Motion` springs, interruptible; only the spinner, shimmer and secure-input badge loop.
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
- [x] Instant start: a window opens on the saved workspace (washed, "Connecting…" in the subtitle) and swaps to live in place (APP-ARCHITECTURE §26).
- [x] One accent, used only for focus/selection/primary; state hues from the terminal palette.
- [x] SF Symbols only; SF Pro chrome; SF Mono literals; JetBrains Mono grid.
- [x] Light and dark everywhere; Dynamic Type through text styles on iOS; VoiceOver labels on
      dividers (adjustable), status glyphs, avatars, badges; Reduce Motion respected.
- [x] Tooltips with the shortcut on every icon control (`.help`), hover-to-peek popovers, hover fills
      on rows and tabs, pointer highlight on bar buttons; hover-only affordances visible at 0.6 on touch.
- [x] Dynamic Type from XS to AX5 without overlap: fixed bands clamp, the sidebar widens.
- [ ] Context menu *previews* (live pane thumbnails): needs the renderer's snapshot API wired
      into `contextMenu(menuItems:preview:)`.

## Screenshots

Mac, without touching the screen: `AppTests/MacSnapshotTests` draws each fixture in-process into
an offscreen window and captures it with the window server's picture of the app's own window
(glass included, no recording permission). The test host opens no window of its own and never
activates. `xcodebuild test -scheme App -destination platform=macOS
-only-testing:AppTests/MacSnapshotTests` with `TEST_RUNNER_SNAPSHOT_DIR=<dir>`,
`TEST_RUNNER_GUDO_MOCK=1`, optionally `TEST_RUNNER_SNAPSHOT_MODE=light` and
`TEST_RUNNER_SNAPSHOT_ONLY=splits,join,…`. The offscreen window is never key, so default buttons
draw inactive.

`apple/scripts/screenshots.sh <udid> <prefix> <dir> [screens]` (simulator) and
`apple/scripts/mac-screenshots.sh <app> <dir> [screens]` (Mac; the Debug app draws its own window
with `-snapshot`, so it works on a locked Mac: glass and the sidebar list are not captured by
`cacheDisplay` and show as white). Screens: `single splits bar hosts inbox palette search
keybar reconnect overlays welcome pairing launchAgent invite links diff files browser editor
settings toggle programs` (`programs`: one tab per program for the marks, `-fixtureTabs N` for
the first N). Also `editor-licence` (with `-mockEditorPhase licence`),
`devices`, `app-lock` (locked, stays so) and `stopped-following` (with `-mockPresence YES`: the
banner above someone's draft). `AppUITests/AccessibilityAuditUITests` runs the system's
accessibility audit at the largest text size over `projects`, `tab-history`, `tab-selection`,
`devices` and `app-lock`.

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
- **Mac snapshots** (`-snapshot`) leave system lists (Inbox, Hosts) and glass grey: the Mac
  theme screenshots show the chrome around them; check lists on a live window.

### Live presence

Someone's draft is a panel with their name tag (first name in white on their colour, Figma's
cursor label), "iPad · writing a prompt" in meta and a thin caret in their colour; no coloured
side bar. "Kim is typing" and tab avatars use the cut-out `PresenceStack`. "Following Kim" is
one glass capsule: their avatar, the words, a hairline, Stop in the accent; no second coloured
edge. The shared approval reuses the Agents request block. Arrivals and departures are banners
with the person's avatar. With people here the toolbar's avatars open `PeopleSwitcher`; alone
the button is Share Session.

### Browser chrome and remaining surfaces

The browser bar's way back names where it goes ("‹ Ports") in the ink, never the accent; Done
stays a word. Page dialogs and agent requests over a page are panels, not capsules (three lines
in a capsule read as a pill-shaped block), with the secondary verb `.quiet` beside the one
`.primaryGlass` (never glass on glass); "Agent · …  Take Over" is one capsule with a hairline
and an accent verb. Text prompts are prose even where the typed value is a literal (Hosts quick
connect, the Ports address). Reviewed without changes: Share Session, Join, Links, Diff, Files,
Add Host, Settings and Theme, the key bar, pane headers, the welcome state and the iPhone tab
layout (they already follow the system's components).
