# Architecture (v0 — draft for decision)


## 1. Product thesis

Coding on iPad/iPhone (and foldables) should feel like a laptop, and managing a fleet of agents should be
*better* on a phone than on a desktop. macOS ships from the same codebase but is not where we compete.

Wins over the references:

| They | Problem | Us |
|---|---|---|

not being on mobile at all.

## 2. System overview

```
┌──────────── iPhone / iPad / Mac app (Swift) ────────────┐        ┌──────── Host (macOS / Linux) ────────┐
│ UIKit/SwiftUI shell · Agent Inbox · Key bar · Gestures  │        │ gudo-hostd (Rust, tokio)          │
│ Metal renderer (port of Ghostty shaders + atlas)        │        │  ├ PTY actor per pane                │
│ libghostty-vt (client copy, fed raw bytes / snapshots)  │        │  ├ libghostty-vt per pane (truth)    │
│ Secure Enclave signer · APNs · Live Activities · NSE    │        │  ├ ring buffer ~1 MB raw bytes/pane   │
│ ┌──────── GudoCore.xcframework (Rust, UniFFI) ─────┐ │  QUIC  │  ├ agent harness (hooks, OSC 7501,   │
│ │ iroh endpoint · protocol codec · seq/ack · resume   │◄├────────┤  │   screen manifests, resume)       │
│ └─────────────────────────────────────────────────────┘ │ direct │  └ persistence (layout, agent ids)   │
└─────────────────────────────────────────────────────────┘ /relay └──────────────────────────────────────┘
                                   │                                     │
                                   └──── push relay (sealed payloads) ───┘──► APNs
```

## 3. Decisions

| # | Decision | Choice | Why / source |
|---|---|---|---|
| D1 | Platforms | iOS + iPadOS first, macOS from same Swift code. **Minimum iOS 26 / macOS 26** (no legacy) | User; enables `BGContinuedProcessingTask`, current SwiftUI/Liquid Glass |
| D19 | Host platforms | **macOS and headless Linux are equal first-class hosts** (incl. AWS/GCP VMs, x86_64 + aarch64). Static musl daemon binary (cargo-zigbuild), XDG dirs, systemd `--user` / launchd service, headless pairing (terminal QR + ticket text), install via `curl \| sh` or one tap over SSH from the phone. Cloud VMs need no inbound ports: outbound UDP hole punching or relay over 443 | Owner |


One iroh connection per (device, daemon), ALPN `gudo/1`, postcard/CBOR, every message versioned.

| Stream | Priority | Content |
|---|---|---|
| `ctl` bidi | 100 | Hello/Welcome/resume, pane meta, agent events, focus/visibility, resize, echo hints |
| `input` c→s | 90 | Keys, paste, mouse, tagged `(pane_id, input_seq)` — never in 0-RTT |
| `pane/<id>` s→c | 80 focused / 50 visible / — background | `Bytes{seq}` / `Snapshot{seq, gen}` / `InputAck` |
| `bulk` | 1 | Scrollback pages, files, images |

- Background panes send metadata only. Per-pane unacked budget; exceeding it → stop bytes, send one snapshot
  the budget does (+9 ms). Size it as **link rate × allowed added delay** (≈32 KB at 20 Mbit/s for ~10 ms),
  not bandwidth × RTT × 2 (+39 ms). Rate-limit snapshots of a flooding pane. Snapshots are zstd-compressed
- Resume: client paints its own cached snapshot instantly (dimmed), re-dials, daemon replays from ring
- Echo prediction from real PTY facts (`ECHO`/`ICANON`, alt screen, OSC 133) — never predicts at password
- Client and daemon must run the same Ghostty snapshot format version → handshake checks it and offers a
  one-tap daemon upgrade.


1. **Just ssh**: type `user@host`, saved automatically, one tap to move to a Secure Enclave key.
2. **Agent Inbox** across hosts, "Needs you" first; Approve/Deny/Reply inline; actionable notifications and
3. **Context-aware key bar** (shell / Claude / Codex / vim / less), sticky one-shot Ctrl, composer mode for
4. **iPad**: sidebar + up to 4 splits, multi-window, Stage Manager, external display with keyboard focus kept
   on iPad, full hardware-keyboard shortcut map.
5. **Foldables**: cover / open / half-folded "duo" (output top, input bottom) — manual toggle until a posture
   API exists.
6. **Never a blank screen** on foreground; the 12 reliability rules R1–R12 from 04 are acceptance criteria.

## 6. Repo layout

```
gudo/
├─ Cargo.toml                 # virtual workspace, [workspace.dependencies], profiles from 07
├─ .cargo/config.toml
├─ crates/
│  ├─ proto/                  # wire types + codecs; tiny, rarely changes
│  ├─ ghostty-vt-sys/         # zig build of pinned libghostty-vt, checked-in bindgen
│  ├─ agents/                 # manifests, detection, AgentEvent, resume recipes, hook shim lib
│  ├─ hostd/                  # daemon as a library
│  ├─ core/                   # client core: iroh, seq/ack, resume, prediction, russh
│  └─ apple-ffi/              # UniFFI surface → GudoCore.xcframework (not in default-members)
├─ bins/  hostd, gudo-hook, gudo (CLI)
├─ apple/                     # Xcode project: iOS, iPadOS, macOS targets; Metal renderer; fonts
├─ xtask/                     # build-xcframework, build-ghostty, release
├─ vendor/ghostty             # pinned
└─ docs/
```

Build settings: stable Rust; `debug = "line-tables-only"`, deps `opt-level = 1` + no debuginfo, crypto/QUIC
deps `opt-level = 3`; `dist` profile = fat LTO; Apple default linker on macOS; terminal registered as a
Developer Tool; bacon + nextest; arm64-only xcframework slices in dev — 07.

## 7. Plan


|---|---|---|
| A. **Render** | libghostty-vt xcframework + minimal Swift Metal renderer on iPad | 120 Hz scrolling of `cat` big file; text identical to Ghostty at same font |
| B. **Snapshot** (05 S5) | encode on daemon → decode on client → continue bytes mid-escape | Byte-identical to never-disconnected client under fuzz; READY < 50 KB |
| C. **iroh on iPhone** (S1, S7) | UniFFI core dials Mac behind home NAT/CGNAT over LTE | ≥ 80 % direct, relay always works; < 12 MB size delta |
| D. **Resume** (S2, S3) | suspend 10 s / 5 min / 1 h; Wi-Fi → LTE walk-out | p50 < 300 ms Wi-Fi, < 800 ms LTE relay; no reconnect on migration |
| E. **Latency** (S4) | keystroke p99 with a 50 MB flood in another pane | ≤ 10 ms degradation |
| F. **Agents** | state detection + resume for Claude Code and Codex via launch recipes (adapter trait proven by adding a stub third agent) | Correct working/blocked/idle on a scripted scenario set; `--settings` hooks confirmed additive |
| G. **Lock-screen approve** (S8) | push → NSE → action → daemon | < 5 s on LTE with app killed |


### Phase 2 — MVP (≈ 6–8 weeks)
Hosts → sessions → panes; just-ssh + bootstrap; pairing by QR; agent inbox + push; key bar; iPad splits +
hardware keyboard; daemon persistence + agent resume; macOS client builds from same code.

### Phase 3
the safe *Prompter* role possible),  kitty graphics, foldable layouts, external display, Files provider, scripting (Lua like

## 8. Open decisions (need owner input)

1. ~~Hosted infra~~ — **decided (D16)**: managed third-party is fine. Est. ~$30/mo at 1k users,
2. ~~Product name~~ — **decided: Gudo** (gudo.dev). Every brand-bearing string (ALPN, bundle ids,
   env prefix `GUDO_`, binary names, config dirs, URL schemes) is defined once — `crates/brand`
   (Rust consts) and `apple/Brand.xcconfig` (Swift/Info.plist). The previous placeholder name
   lives on only in `brand::legacy`, for migrating installs made under it.
   to be written as `docs/TESTING.md` before code.
4. ~~Toolchain~~ — Zig **0.17.0** installed (`brew install zig`). Ghostty requires major.minor to
   match exactly (`src/build/zig.zig:9`), so 0.17 won't work; pin it in CI too.

## 9. Things to verify (claims from research not yet checked)

- iroh 1.0 (2026-06-15) / 1.3.0 versions and the iOS 26 Network.framework migration crash report — 05.
- ~~Claude `--settings` hooks merge with (not replace) user hooks — 06 risk #1.~~ **Verified 2026-10-18** on
  Claude Code 2.1.302: project hooks and `--settings` hooks both fired; `--session-id` honoured. Real payloads
  saved in `crates/agents/tests/fixtures/claude/captured-2.1.302/`.
  (https://code.visualstudio.com/license/server): use "with Microsoft Visual Studio Code" on your
  own devices / internal network is allowed; hosting, sharing, redistributing, or "combine it
  with any of your applications for others to use" is not (§5.4–5.5). **Superseded
  VS Code):
  - Main path: Microsoft's `code tunnel` on the user's host, under the user's own account. The
    user accepts the licence in the app first, and the CLI comes from Microsoft's update
    service with its SHA-256 checked.
  - The editor itself is vscode.dev, top-level in WKWebView, or desktop VS Code via
    `vscode://vscode-remote/tunnel+…` or Remote-SSH over our forward.
  - serve-web is opt-in. openvscode-server is an explicit fallback only.
  - Still needs a legal read, or Microsoft's confirmation, of the Remote FAQ line "cannot build
    a public or commercial service on top of … VS Code Server" before launch.
