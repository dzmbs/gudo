# gudo.dev

The static site for Gudo. Plain HTML and one stylesheet, no build step, no trackers, no
cookies. Served by Cloudflare as static assets (`wrangler deploy` from the repo root).

## Deploy

```sh
wrangler pages deploy site --project-name gudo
```

Run it from the repository root. The first time, create the project and attach the domain in the
Cloudflare dashboard (Workers & Pages, gudo, Custom domains: `gudo.dev`).

## Preview

```sh
npx wrangler pages dev site --local-protocol https
```

This serves `_headers`, clean URLs and `404.html` the way Pages does. Use https: the CSP has
`upgrade-insecure-requests`, so over plain http the page asks for https assets and gets none.

## What is here

| Path | What |
|---|---|
| `index.html` | Home |
| `download/` | Mac, iPhone and iPad, and the Linux host |
| `how-it-works/` | The app, the host, pairing and the connection |
| `privacy/` | Privacy policy (linked from App Store Connect) |
| `support/` | Support and contact (GitHub issues) |
| `404.html` | Not found |
| `join/`, `pair/` | Fallbacks for universal links when the app is not installed |
| `.well-known/apple-app-site-association` | Universal links for `8SP2H5J666.dev.gudo.app`: `/join*`, `/pair*` |
| `appcast.xml` | Sparkle feed for the Mac app (empty until the first release) |
| `install.sh` | The Linux host installer behind `curl -fsSL https://gudo.dev/install.sh \| sh` |
| `_headers` | CSP, HSTS, nosniff, no referrer, no framing; content types for AASA, appcast and the script |
| `assets/` | `site.css`, small scripts, JetBrains Mono (subset, SIL OFL 1.1, `assets/fonts/OFL.txt`) |
| `assets/hero.js` | Home page only: the iPad and iPhone demo (a canned shell, Claude Code, the approval card, palette, splits, floating windows and the tray, projects by drag, the Agents and Hosts screens, share, diff review, a web pane, the ⌘-hold shortcuts; on iPhone the key bar, switcher and banner), the scroll tilt fallback and the card spotlight. All local; nothing typed leaves the page |

The home hero is the app drawn in HTML inside an iPad frame (an iPhone under 700 px wide). It
tilts flat on scroll with a CSS scroll-driven animation; `theme.js` marks browsers without one
(`no-sda`) and `hero.js` drives the same tilt from scroll. Under Reduce Motion the device is flat
and the demo shows its final state, still interactive.

The header and footer are repeated in each page. Change them everywhere at once.

## Before launch

- **TestFlight**: replace `https://testflight.apple.com/join/GUDO-BETA` in `index.html` and
  `download/index.html` with the public link.
- **Release assets**: the pages and `install.sh` expect these names on each GitHub release:
  `Gudo.dmg`, `gudo-hostd-x86_64-unknown-linux-musl`, `gudo-hostd-aarch64-unknown-linux-musl`
  and `SHA256SUMS` (`sha256sum` format). Tags look like `v0.1.0`.
- **Homebrew**: the download page shows `brew install --cask dzmbs/tap/gudo`, which needs a
  `dzmbs/homebrew-tap` repository with `Casks/gudo.rb`:

  ```ruby
  cask "gudo" do
    version "0.1.0"
    sha256 "…"

    url "https://github.com/dzmbs/gudo/releases/download/v#{version}/Gudo.dmg"
    name "Gudo"
    desc "Terminal and coding agent manager for your own machines"
    homepage "https://gudo.dev/"

    livecheck do
      url :url
      strategy :github_latest
    end

    auto_updates true
    depends_on macos: ">= :tahoe"
    depends_on arch: :arm64

    app "Gudo.app"

    zap trash: [
      "~/Library/Application Support/gudo",
      "~/Library/Preferences/dev.gudo.app.plist",
    ]
  end
  ```

  Drop `auto_updates` until the app ships Sparkle.
- **App links**: `join/` and `pair/` open `gudo://join/<fragment>` and `gudo://pair/<fragment>`.
  The app should accept the same payload from `https://gudo.dev/join#<invite>` and
  `https://gudo.dev/pair#<ticket>`. The fragment never reaches the server.
- **Sparkle**: set `SUFeedURL` to `https://gudo.dev/appcast.xml` and add `SUPublicEDKey`; each
  release appends an item made by `generate_appcast`. The file explains the format.
- **Apple**: App Store Connect wants the privacy policy URL (`https://gudo.dev/privacy/`) and a
  support URL (`https://gudo.dev/support/`).

## Writing

Short, plain sentences. No long dashes, no hype words, no exclamation marks. Say what the
product does and what it doesn't. Claims about security and privacy must match
`docs/security/` and `docs/PUSH.md`.
