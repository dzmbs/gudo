# Third-party notices (Apple apps)

The Apple apps include code and data derived from the projects below. Each notice applies to the
files listed under it. Nothing from Rex, iTerm2 or Warp is included: those were studied for layout
and behaviour only (docs/DESIGN.md says which ideas came from where).

## Ghostty

Source: https://github.com/ghostty-org/ghostty (reference/ghostty in this repository).

Ported from `macos/Sources` (Swift, adapted to plain values instead of Ghostty surfaces):

- `Packages/DesignSystem/Sources/DesignSystem/Overlays/TerminalOverlays.swift`: the resize
  overlay (`SurfaceResizeOverlay`), process-exited bar (`ChildExitedMessageBar`), bell border
  (`BellBorderOverlay`), unfocused split dimming, secure input badge (`SecureInputOverlay`) and
  URL hover banner (`URLHoverBanner`).
- `Packages/DesignSystem/Sources/DesignSystem/Overlays/SearchBar.swift`: `SurfaceSearchOverlay`.
- `Packages/DesignSystem/Sources/DesignSystem/Overlays/CommandPalette.swift`: `CommandPaletteView`.
- `Packages/DesignSystem/Sources/DesignSystem/Components/KeyCaps.swift`: `KeyCap`.
- `App/Sources/Views/SplitTreeView.swift`: the split divider (`SplitView.Divider`) and default
  `split-divider-color` / `unfocused-split-opacity` behaviour.

Config names, defaults and the default palette come from `src/config/Config.zig` and
`src/terminal/color.zig`. The Ghostty name and icon are trademarks and are not used.

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Terminal themes (iTerm2-Color-Schemes, as bundled by Ghostty)

`Packages/DesignSystem/Sources/DesignSystem/Resources/ghostty-themes.json` is the theme set
Ghostty 1.3.1 bundles (`Ghostty.app/Contents/Resources/ghostty/themes`), converted to one JSON
file. The themes come from https://github.com/mbadolato/iTerm2-Color-Schemes, published under the
MIT License (Copyright (c) 2011 Mark Badolato and contributors); individual schemes credit their
authors in that repository.

## JetBrains Mono and Nerd Fonts

The terminal font (`Packages/TerminalKit/Sources/TerminalRenderer/Resources/Fonts`) is JetBrains
Mono under the SIL Open Font License 1.1, with Nerd Fonts symbols; the full licence text is
`OFL.txt` next to the fonts.

## Orca

Source: https://github.com/stablyai/orca (reference/orca). MIT License, Copyright (c) 2026
Lovecast Inc. Behavioural patterns (agent state vocabulary, reconnect wording, key bar data
model) were adopted from its mobile app and style guide; no Orca code is included in the
design layer.
