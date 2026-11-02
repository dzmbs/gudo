# Gudo brand

Gudo (求道, gudō) means seeking the Way: the long pursuit of mastery. The marks take that idea
quietly: an orb, an orbit, and the split window the app is built around.

Nothing here is wired into the app yet. The app icon is still
`apple/App/Resources/AppIcon.icon`; pick a direction below and it can be moved over.

## Icon: evolutions of today's icon (`evolution/`)

Same graphite field, same white window split into three panes. Only the cursor changes.

| | Idea | Notes |
|---|---|---|
| `a-original` | Split panes, a block cursor | Today's icon, for comparison |
| `b-orb` | The cursor becomes an orb | The smallest change. Reads well at every size |
| `c-orbit` | The orb rides a faint orbit through the panes | **Recommended.** Says "Gudo" at icon sizes; below 32 px it uses B's glyph, since the orbit is too fine there |
| `d-pane-orbs` | An orb in every pane, the focused one lit | Clear at 16 px, but it starts to look like a domino |

Each folder has `icon-dark.svg` and `icon-light.svg` (1024, full bleed; the system applies the
mask), `glyph.svg` (one colour, `currentColor`, for the menu bar and template images), and
`mark-dark.svg` / `mark-light.svg` (two colour, for favicons). `c-orbit/icon-composer/` has the
layers for Icon Composer: `panes.svg` (unchanged), `orbit.svg` and `orb.svg` (the cursor's old
glass layer).

## Icon: new concepts (`concepts/`)

Four earlier, standalone ideas, kept for reference: `orbit` (a ring of orbs, one lit; reads as a
spinner), `split` (one large orb and two small ones, like a split layout), `kernel` (orb, orbit,
satellite) and `enso` (an open Zen circle with the orb in its gap).

## Wordmark (`wordmark/`)

Lowercase "gudo", drawn as a monoline from the same circle as the orb. No typeface involved.

- `gudo.svg` (`currentColor`), `gudo-white.svg`, `gudo-black.svg`
- `lockup.svg`, `lockup-dark.svg`, `lockup-light.svg`: the glyph and the word
- `gudo-kyudo.svg`: the word with a quiet 求道 (Noto Serif JP, SIL OFL 1.1, as outlines)

## Colour

| | Dark | Light |
|---|---|---|
| Field | `#333840` to `#16181D` | `#FBFBFC` to `#E4E7EB` |
| Ink | `#FFFFFF` at 92 % | `#1B1D22` |
| Orb (accent) | `#7AA6DA` | `#2F6DB5` |

The accent is the app's own (`AccentColor`).

## Previews and sources

`previews/` has the comparison sheets: each option as an App Store icon, in a Dock, in the menu
bar and as a favicon, dark and light. `src/` has the scripts that draw every file here:

```sh
python3 branding/src/evolution.py branding/evolution
python3 branding/src/concepts.py branding/concepts
python3 branding/src/wordmark.py branding/wordmark branding/src/kanji-noto-serif-jp.txt
```
