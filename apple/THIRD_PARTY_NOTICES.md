# Third-party notices (Apple apps)

The Apple apps include code and data derived from the projects below. Each notice applies to the
files listed under it.

## Ghostty

Source: https://github.com/ghostty-org/ghostty.

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

## Program logos

`Packages/DesignSystem/Sources/DesignSystem/Resources/ProgramLogos.xcassets` holds the official
logos of 23 programs, shown at 14-16 pt next to a tab to say which program runs in it (nominative
use). Each file is the owner's own artwork as downloaded (byte-identical unless noted), in its own
colours; where the owner publishes a dark-background variant it is the image set's dark
appearance. Every logo is switched on by one line in `ProgramCatalog.logos`, which records each
file's exact source URL, retrieval date and clearance. The same credits appear in Settings ▸ Acknowledgements ▸ Program logos.

Trademarks: Claude is a trademark of Anthropic, PBC. OpenAI, Codex and the OpenAI logo are
trademarks of OpenAI. Gemini and Go are trademarks of Google LLC. GitHub and Copilot are
trademarks of GitHub, Inc. Docker and the Docker logo are trademarks or registered trademarks of
Docker, Inc. in the United States and/or other countries. Kubernetes is a registered trademark of
The Linux Foundation. "Python" and the Python logos are trademarks or registered trademarks of the
Python Software Foundation. Node.js is a trademark of the OpenJS Foundation. Deno is a registered
trademark of Deno Land Inc. Rust and Cargo are trademarks of the Rust Foundation. Postgres,
PostgreSQL and the Slonik logo are trademarks or registered trademarks of the PostgreSQL Community
Association of Canada. Git, Neovim, Helix, tmux, btop, Ruby, Vim, Emacs, htop and Bun belong to
their owners. Names and logos are used only to identify the program running in a tab; this app is
not affiliated with or endorsed by any of them.

"Permission requested" below marks logos whose owners' terms ask for permission before this use.

| Logo | Source | Licence / terms | Monochrome | Size / clear space | Nominative use in an app UI |
|---|---|---|---|---|---|
| Git (`GitLogo`, `Git-Icon-1788C.svg`) | https://git-scm.com/community/logos | "Git Logo by Jason Long is licensed under the Creative Commons Attribution 3.0 Unported License" (https://creativecommons.org/licenses/by/3.0/); trademark policy https://git-scm.com/about/trademark | Official black/white variants; shipped in colour | None stated | Allowed without permission to refer to Git; no implied endorsement |
| Neovim (`NeovimLogo`, `neovim-mark.svg` from https://neovim.io/logos/neovim-logos.zip) | https://neovim.io | "Neovim logo by Jason Long, CC BY 3.0" | Allowed (1-colour variant published); shipped in colour | None stated | Allowed with attribution; no trademark policy published |
| Helix (`HelixLogo`, `logo.svg`) | https://github.com/helix-editor/helix | Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/); logo by @jakenvac. The file is unmodified; its source form is at the URL above | Allowed; shipped in colour | None stated | Allowed by the licence; no trademark policy |
| tmux (`TmuxLogo`, `logo/tmux-logomark.svg`) | https://github.com/tmux/tmux/tree/master/logo | ISC (notice below) | Allowed; drawn in the label colour (template) | None stated | Allowed with the notice |
| btop (`BtopLogo`, `Img/icon.svg`) | https://github.com/aristocratos/btop | Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0), Copyright Aristocratos; unmodified | Shipped in colour | None stated | Allowed; Apache §6 grants no trademark rights beyond describing the origin, which is this use |
| Ruby (`RubyLogo`, `ruby-mark.pdf`) | https://www.ruby-lang.org/en/about/logo/ (`ruby-logo-kit.zip`, `ruby.pdf`) | "The Ruby Logo is Copyright (c) 2006, Yukihiro Matsumoto. It is licensed under the terms of the Creative Commons Attribution-ShareAlike 2.5 agreement" (https://creativecommons.org/licenses/by-sa/2.5/). Changed: the page is cropped to the gem (artwork unchanged); the cropped file is CC BY-SA 2.5. "We ask that you do not use the logo to represent something other than the Ruby Programming language." | Allowed (adaptations stay BY-SA); shipped in colour | None stated | Allowed with attribution |
| Emacs (`EmacsLogo`, `emacs.svg`) | https://git.savannah.gnu.org/cgit/emacs.git/plain/etc/images/icons/hicolor/scalable/apps/emacs.svg (retrieved 2026-10-21) | "Copyright (C) 2015-2026 Free Software Foundation, Inc."; author Nicolas Petton; GNU General Public License version 3 or later (https://www.gnu.org/licenses/gpl-3.0.html). Unmodified; the SVG is its own source form, available at the URL above | Shipped in colour | None stated | Allowed by the licence |
| htop (`HtopLogo`, `htop.svg`) | https://raw.githubusercontent.com/htop-dev/htop/main/htop.svg (retrieved 2026-10-21) | GNU General Public License version 2 or later (https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), the htop repository's licence. Unmodified; the SVG is its own source form | Shipped in colour | None stated | Allowed by the licence |
| Vim (`VimLogo`, `vimlogo.svg`) | https://www.vim.org/images/vimlogo.svg from https://www.vim.org/logos.php (retrieved 2026-10-21) | No licence or terms published; permission requested | Shipped in colour | None stated | Terms silent |
| Bun (`BunLogo`, `logo.svg`) | https://bun.com/logo.svg from https://bun.com/press-kit (retrieved 2026-10-21) | "Please don't stretch, recolour or put a hat on the bun without asking." Unmodified; permission requested | Not recoloured | None stated (the kit offers `icon.svg` for small sizes; the colour logo was chosen as it reads at 14 pt in both schemes) | Terms silent |
| Deno (`DenoLogo`, `icon-light.svg`, dark appearance `icon-dark.svg`) | https://deno.com/logos/icon-light.svg and https://deno.com/logos/icon-dark.svg from https://deno.com/brand (retrieved 2026-10-21) | Deno Logo Guidelines (in https://deno.com/logos/deno_assets.zip): black and white only; light version on light backgrounds, outlined dark version on dark; "Yes, use logo mark independently". Permission requested | The owner's two versions, per scheme | Clear space "ideally two times" the mark-to-wordmark gap (applies to the full logo) | Terms silent |
| Claude Code (`ClaudeLogo`, `Claude Spark - Clay.svg`) | https://www.anthropic.com/press-kit (the press-kit zip, `Anthropic media resources/Anthropic logos/Claude logos/3 Claude Spark/SVG/Claude Spark - Clay.svg`; retrieved 2026-10-21) | Anthropic trademark guidelines (https://www.anthropic.com/legal/trademark-guidelines): use only as permitted and approved; "No alterations of our trademarks (changes to color, font, proportion, or otherwise)". Unmodified | Shipped in its clay colour | "reasonable space"; sizes supplied on request | Permission requested |
| OpenAI Codex (`CodexLogo`, `OpenAI-black-monoblossom.svg`, dark appearance `OpenAI-white-monoblossom.svg`) | https://cdn.openai.com/brand/OpenAI-Logos-2025.zip, linked from https://openai.com/brand/ (`OpenAI-logos(new)/SVGs/`; retrieved 2026-10-21). OpenAI publishes no Codex-specific mark | OpenAI brand guidelines: "Use the logo exactly as provided"; do not "Use the logo without permission"; permissions via partnercomms@openai.com. Unmodified | The owner's black and white Blossoms, per scheme | "prescribed spacing" | Permission requested |
| Gemini CLI (`GeminiCLILogo`, `gemini-cli-icon_full-color.svg`) | https://geminicli.com/brandassets/gemini-cli-icon_full-color.svg from https://geminicli.com/brand-kit/ (the project's homepage per github.com/google-gemini/gemini-cli; retrieved 2026-10-21) | Gemini CLI logo and icon usage guidelines (in the brand kit): "should not ever be altered"; the icon is for "where the brand has to be separated from the product name". Google brand features need permission. Unmodified | Shipped in full colour | Clear space defined for the logo lockup | Permission requested |
| GitHub Copilot CLI (`CopilotLogo`, `Copilot_Icon_Black.svg`, dark appearance `Copilot_Icon_White.svg`) | https://brand.github.com/GitHub_Logos.zip (`GitHub Logos/SVG/`; retrieved 2026-10-21) | GitHub logo guidelines (https://brand.github.com/foundations/logo): no use without GitHub's prior written permission; do not modify. Unmodified | The owner's black and white icons, per scheme | Clear-space files in the kit | Permission requested |
| Docker (`DockerLogo`, `docker-mark-ocean-blue.svg`) | https://www.docker.com/static/Docker-Logos-1.zip from https://www.docker.com/company/newsroom/media-resources/ (`docker-logos/SVG/`; retrieved 2026-10-21) | Docker trademark guidelines (https://www.docker.com/legal/trademark-guidelines/): logos only "following authorization from us"; must appear in a primary brand colour; "Don't decolorize". Unmodified, Ocean Blue | Ocean Blue in both schemes | "at least 24px": 14 pt is 28 px on Retina Macs, 16 pt is 32-48 px on iPad and iPhone | Permission requested |
| kubectl (`KubernetesLogo`, `kubernetes-icon-color.svg`) | https://raw.githubusercontent.com/cncf/artwork/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg (retrieved 2026-10-21). CNCF publishes no kubectl mark; the Kubernetes icon labels its CLI | Linux Foundation trademark usage (https://www.linuxfoundation.org/legal/trademark-usage): no logos in a commercial context without written permission; no colour variations. Unmodified | Shipped in colour | Not stated | Permission requested |
| Python (`PythonLogo`, `python-logo-only.svg`) | https://s3.dualstack.us-east-2.amazonaws.com/pythondotorg-assets/media/files/python-logo-only.svg, linked from https://www.python.org/community/logos/ (retrieved 2026-10-21) | PSF Trademark Usage Policy (https://www.python.org/psf/trademarks/): other commercial uses need prior written permission. Unmodified | Shipped in colour | Not stated | Permission requested |
| Node.js (`NodeLogo`, `nodejsHex.svg`) | https://nodejs.org/static/logos/nodejsHex.svg from https://nodejs.org/en/about/branding ("Node.js® Hex Logo"; retrieved 2026-10-21) | OpenJS Foundation trademark policy (https://trademark-policy.openjsf.org/): no logos in a commercial context unless expressly permitted. Unmodified | Shipped in colour | Not stated | Permission requested |
| Go (`GoLogo`, `go-logo-blue.svg`, dark appearance `go-logo-white.svg`) | https://go.dev/images/go-logo-blue.svg and https://go.dev/images/go-logo-white.svg from https://go.dev/brand (retrieved 2026-10-21) | Go brand and trademark guidelines: "Do not use the Go Logo or Go as a stylized form without permission"; not "modified in any form". Unmodified | The owner's blue and white logos, per scheme | Not stated (a wide wordmark: fitted to the slot's width) | Permission requested |
| Rust (`RustLogo`, `rust-logo.svg`, dark appearance `rust-logo-white-outline.svg`) | https://raw.githubusercontent.com/rust-lang/rust-artwork/main/logo/rust-logo.svg and `…/logo/rust-logo-white-outline.svg` (the project's version "to make it usable on dark backgrounds"; retrieved 2026-10-21) | Creative Commons Attribution 4.0 (https://creativecommons.org/licenses/by/4.0/), Rust Foundation; also trademarks: "most commercial uses require permission" (https://rustfoundation.org/policy/rust-trademark-policy/). Unmodified | The owner's two versions, per scheme | Not stated | Permission requested |
| Cargo (`CargoLogo`, `Cargo-Logo-Small.png`) | https://raw.githubusercontent.com/rust-lang/cargo/master/doc/book/src/images/Cargo-Logo-Small.png (the only official file; raster, 306×275; retrieved 2026-10-21) | As Rust: CC BY 4.0, Rust Foundation trademark. Unmodified | Shipped in colour | Not stated | Permission requested |
| PostgreSQL (`PostgreSQLLogo`, `PostgreSQL_logo.3colors.svg`) | https://wiki.postgresql.org/images/a/a4/PostgreSQL_logo.3colors.svg from https://wiki.postgresql.org/wiki/Logo (retrieved 2026-10-21) | PostgreSQL trademark policy (https://www.postgresql.org/about/policies/trademarks/): "For pretty much any use not discussed above, you must contact us for permission". Unmodified | Shipped in colour | Not stated | Permission requested |

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

Not shipped (a neutral SF Symbol shows): Redis (its brand kit at https://brand.redis.io/ failed
TLS on 2026-10-21 and its guidelines PDF is gone; the repository has no logo), bash (its logo is
published only in a designer's repository, not by GNU, under the Free Art License), nano, lazygit
and K9s (no graphic mark), OpenSSH, zsh and fish (no licence). No artwork from any icon pack is included.

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

## Playwright

Source: https://github.com/microsoft/playwright at commit 20a2087ea43412b90c172c88faef80786ee18b8b
(Apache License 2.0, Copyright (c) Microsoft Corporation; its NOTICE credits code derived from
Puppeteer, Apache 2.0). `App/Resources/AgentBrowser/playwright-injected.js` is a build of
`packages/injected/src/injectedScript.ts` and `packages/injected/src/webview/webViewInput.ts` with
the `packages/isomorphic` modules they use (`scripts/build-agent-browser.sh`, unmodified sources).
`App/Resources/AgentBrowser/agent.js` follows the event sequence of `webViewInput.ts`. The licence
and NOTICE: `App/Resources/AgentBrowser/LICENSE-playwright.txt`.

## rrweb

Source: https://github.com/rrweb-io/rrweb, npm `@rrweb/record` and `rrweb-player` 2.1.7 (MIT License,
Copyright (c) 2018 Contributors). `App/Resources/AgentBrowser/rrweb-record.js` is a build of
`@rrweb/record`; `rrweb-player.js` and `rrweb-player.css` are the package's own builds. Full text:
`App/Resources/AgentBrowser/LICENSE-rrweb.txt`.

## Warp UI framework (shimmer maths)

Source: https://github.com/warpdotdev/warp, `crates/warpui_core/src/elements/shimmer_math.rs`
(the `warpui_core` crate is MIT; the rest of Warp is AGPL-3.0 and none of it is included). Ported
to Swift in `Packages/DesignSystem/Sources/DesignSystem/Components/Shimmer.swift` (`ShimmerMath`).

```
Copyright (C) 2020-2026 Denver Technologies, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Swift Markdown and cmark-gfm

Source: https://github.com/swiftlang/swift-markdown 0.7.3 and
https://github.com/swiftlang/swift-cmark 0.9.0, linked unmodified for native Chat block parsing.
Swift Markdown is Apache-2.0 with the Swift Runtime Library Exception, Copyright (c) 2021 Apple
Inc. and the Swift project authors. cmark-gfm is BSD-2-Clause with MIT-licensed components.
The complete upstream notice, Apache licence and cmark-gfm `COPYING` are in
`scripts/notices/markdown.txt` and ship in `App/Resources/THIRD_PARTY_NOTICES.txt`.
The CommonMark test specification and test software are not included in the app.

## Codex incremental Markdown partitioning

Source: https://github.com/openai/codex, `codex-rs/tui/src/streaming/render.rs` and
`markdown_render/streaming.rs`. Copyright 2025 OpenAI, Apache License 2.0.
`App/Sources/Chat/RowBuilder.swift` adapts the completed-prefix / mutable-last-block partition
for native rows and Swift Markdown source ranges. No Ratatui rendering code is included.
The complete licence is in `scripts/notices/codex.txt` and ships in
`App/Resources/THIRD_PARTY_NOTICES.txt`.

## Tree-sitter code colours

`Packages/ChatSyntax` links SwiftTreeSitter 0.25.0 (BSD-3-Clause), Tree-sitter 0.25.10 (MIT)
and the pinned upstream grammars and highlight queries listed in its package manifest. The
grammars are MIT licensed; mutable parser state stays on a rendering worker, not in a web view.
Complete upstream copyright and licence notices are in `scripts/notices/tree-sitter.txt`.
Tree-sitter's ICU/Unicode header notices are retained verbatim in
`scripts/notices/tree-sitter-unicode.txt`. Both ship in `App/Resources/THIRD_PARTY_NOTICES.txt`.

## Sparkle

Source: https://github.com/sparkle-project/Sparkle 2.10.1, linked unmodified into the Mac app as
`Sparkle.framework` (a Swift package binary) for its updates (`App/Sources/Model/AppUpdater.swift`).
MIT License, Copyright (c) 2006-2013 Andy Matuschak and the other holders listed in its licence,
which also carries the notices of the code Sparkle includes (bsdiff, sais-lite, ed25519 and
others). Full text: `scripts/notices/mac-app.txt`, shipped in
`App/Resources/THIRD_PARTY_NOTICES.txt`.
