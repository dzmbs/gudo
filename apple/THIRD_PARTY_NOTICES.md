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

## Program logos

`Packages/DesignSystem/Sources/DesignSystem/Resources/ProgramLogos.xcassets` holds the official
logos of six programs, shown at 14 pt next to a tab to say which program runs in it. Each is the
project's own artwork as published (byte-identical unless noted). The names and logos belong to
their owners, who do not endorse this app. Sourcing, terms and the programs that show a neutral
symbol instead: `docs/research/17-program-logos.md`. The same credits appear in Settings ▸
Acknowledgements ▸ Program logos.

| Logo | Source | Licence / terms | Monochrome | Size / clear space | Nominative use in an app UI |
|---|---|---|---|---|---|
| Git (`GitLogo`, `Git-Icon-1788C.svg`) | https://git-scm.com/community/logos | "Git Logo by Jason Long is licensed under the Creative Commons Attribution 3.0 Unported License" (https://creativecommons.org/licenses/by/3.0/); trademark policy https://git-scm.com/about/trademark | Official black/white variants; shipped in colour | None stated | Allowed without permission to refer to Git; no implied endorsement |
| Neovim (`NeovimLogo`, `neovim-mark.svg` from https://neovim.io/logos/neovim-logos.zip) | https://neovim.io | "Neovim logo by Jason Long, CC BY 3.0" | Allowed (1-colour variant published); shipped in colour | None stated | Allowed with attribution; no trademark policy published |
| Helix (`HelixLogo`, `logo.svg`) | https://github.com/helix-editor/helix | Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/); logo by @jakenvac. The file is unmodified; its source form is at the URL above | Allowed; shipped in colour | None stated | Allowed by the licence; no trademark policy |
| tmux (`TmuxLogo`, `logo/tmux-logomark.svg`) | https://github.com/tmux/tmux/tree/master/logo | ISC (notice below) | Allowed; drawn in the label colour (template) | None stated | Allowed with the notice |
| btop (`BtopLogo`, `Img/icon.svg`) | https://github.com/aristocratos/btop | Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0), Copyright Aristocratos; unmodified | Shipped in colour | None stated | Allowed; Apache §6 grants no trademark rights beyond describing the origin, which is this use |
| Ruby (`RubyLogo`, `ruby-mark.pdf`) | https://www.ruby-lang.org/en/about/logo/ (`ruby-logo-kit.zip`, `ruby.pdf`) | "The Ruby Logo is Copyright (c) 2006, Yukihiro Matsumoto. It is licensed under the terms of the Creative Commons Attribution-ShareAlike 2.5 agreement" (https://creativecommons.org/licenses/by-sa/2.5/). Changed: the page is cropped to the gem (artwork unchanged); the cropped file is CC BY-SA 2.5. "We ask that you do not use the logo to represent something other than the Ruby Programming language." | Allowed (adaptations stay BY-SA); shipped in colour | None stated | Allowed with attribution |

tmux logo notice:

```
Copyright (c) 2015, Jason Long <jason@jasonlong.me>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

Not shipped (a neutral SF Symbol shows; their terms forbid this use, need written permission, or
say nothing): Claude Code, OpenAI Codex, Gemini CLI, GitHub Copilot CLI, vim, Emacs, nano, htop,
lazygit, Docker, kubectl, K9s, Python, Node.js, Bun, Deno, Go, Rust/Cargo, PostgreSQL, Redis,
OpenSSH, bash, zsh, fish. No artwork from `reference/rootshell` is included.

Program name normalisation (`ProgramCatalog.normalize`: login-shell dashes, launchers such as
`sudo`/`env`, versioned interpreters, `nvim` → Neovim) follows the rules of rootshell's
`ProgramNameNormalizer` (https://github.com/kitknox/rootshell, MIT License, Copyright (c) 2026
Rootshell LLC, Kit Knox), reimplemented.

## Excalidraw

Source: https://github.com/excalidraw/excalidraw, npm `@excalidraw/excalidraw` 0.18.1 (MIT), with
React and react-dom 19.1.0 (MIT). `App/Resources/Excalidraw/` is a build of it
(`scripts/build-excalidraw.sh` from `scripts/excalidraw/`): the editor of the draw overlay and
canvas panes, bundled offline. Its fonts (Excalifont, Virgil, Nunito, Lilita One, Comic Shanns,
Cascadia Code, Liberation Sans, Assistant) ship under their own open licences (SIL OFL 1.1 /
Apache 2.0); the Xiaolai CJK face is left out. Full text: `App/Resources/Excalidraw/LICENSE-excalidraw.txt`.
