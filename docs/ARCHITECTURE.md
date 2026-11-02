# Architecture

Gudo has two halves. A host daemon (`gudo-hostd`, Rust) runs on your Mac or Linux machine and owns
the terminals, agents, files and editor. The apps (Swift) on iPhone, iPad and Mac connect to it,
render the terminals locally and send input back. Details live in [DAEMON.md](DAEMON.md) (host
side), [APP-ARCHITECTURE.md](APP-ARCHITECTURE.md) (apps), [APPLE-FFI.md](APPLE-FFI.md) (the Rust
core inside the apps) and [security/](security/) (threat model).

## 1. Goals

- Coding on iPad and iPhone should feel like a laptop, and managing several agents should work
  well on a phone.
- Sessions survive the phone sleeping, switching networks or losing signal. The daemon owns the
  sessions; a client resumes from a snapshot in one round trip.
- Connecting needs only `user@host`. No account, no login, no VPN.
- macOS ships from the same code.

## 2. System overview

```
┌──────────── iPhone / iPad / Mac app (Swift) ────────────┐        ┌──────── Host (macOS / Linux) ────────┐
│ UIKit/SwiftUI shell · Agent Inbox · Key bar · Gestures  │        │ gudo-hostd (Rust, tokio)             │
│ Metal renderer (port of Ghostty shaders + atlas)        │        │  ├ PTY actor per pane                │
│ libghostty-vt (client copy, fed raw bytes / snapshots)  │        │  ├ libghostty-vt per pane (truth)    │
│ Secure Enclave signer · APNs · Live Activities · NSE    │        │  ├ ring buffer ~1 MB raw bytes/pane  │
│ ┌──────── GudoCore.xcframework (Rust, UniFFI) ────────┐ │  QUIC  │  ├ agent harness (hooks, OSC 7501,   │
│ │ iroh endpoint · protocol codec · seq/ack · resume   │◄├────────┤  │   screen manifests, resume)        │
│ │ echo prediction · russh fallback · daemon bootstrap │ │ iroh   │  ├ socket API                        │
│ └─────────────────────────────────────────────────────┘ │ direct │  └ persistence (layout, agent ids)   │
└─────────────────────────────────────────────────────────┘ /relay └──────────────────────────────────────┘
                                   │                                     │
                                   └──── push relay (sealed payloads) ───┘──► APNs
```

## 3. Decisions

| # | Decision | Choice | Why |
|---|---|---|---|
| D1 | Platforms | iOS and iPadOS first, macOS from the same Swift code. **Minimum iOS 26 / macOS 26** | Enables `BGContinuedProcessingTask` and current SwiftUI |
| D2 | Daemon language | **Rust, stable toolchain** | iroh is Rust; one language for daemon and client core |
| D3 | Terminal engine | **libghostty-vt at a pinned Ghostty commit**, on both daemon and client, with our own Rust `-sys` crate, safe wrapper and snapshot API | One VT implementation on both ends gives exact fidelity |
| D4 | Output model | **Raw PTY bytes while the client keeps up; a libghostty snapshot when it falls behind or resumes** | Exact fidelity, no diff protocol, less daemon CPU than server-rendered grids |
| D5 | Transport | **iroh (QUIC)**: dial by key, hole punching, relay fallback over HTTPS; our own relays in production | No inbound ports, survives network changes |
| D6 | Client networking | **Rust core in the app as a UniFFI xcframework** (iroh, protocol, resume, prediction, SSH fallback). Swift owns UI, rendering, lifecycle, keys and push | The iroh Swift bindings are not first-tier |
| D7 | Zero-setup path | Plain SSH (`russh` + Secure Enclave key), then a one-tap "install helper" bootstrap (static binary, SHA-256 pinned), then upgrade to iroh | Works on any host that has SSH |
| D8 | Tailscale | **Interoperate, don't embed** (100.x / MagicDNS used as address hints) | No VPN slot or Go runtime on the phone |
| D9 | Agent status | Three merged signal sources: **hooks > OSC 7501 / OSC 9 / title > screen manifests**, one `AgentEvent` schema, explicit arbitration | Hooks are exact when present; the screen is the fallback |
| D10 | Agent integration | **Launch-owned agents, no edits to user config by default** (`claude --settings`, `pi -e`, Codex `-c` OSC 9 notifications); opt-in reversible marker-block install for Codex and Kimi hooks | The user's own config stays untouched |
| D11 | Agents | **Claude Code and Codex** first, then pi and Kimi Code CLI. Per-agent adapter trait, manifest and launch recipe, one `AgentEvent` schema | Multi-agent from the start |
| D12 | ACP / structured lanes | Later, as a second lane behind the same schema | |
| D14 | Fonts and look | Ghostty's bundled JetBrains Mono and Symbols Nerd Font, its Nerd Font sizing table and sprite glyphs (box drawing, powerline, braille); Apple Color Emoji on iOS | Same rendering as Ghostty |
| D16 | Hosting | **No accounts, no login.** Relays: a managed iroh relay behind our own hostname, or self-hosted `iroh-relay` ([RELAYS.md](RELAYS.md)). Push: **one Cloudflare Worker** holding our APNs key, end-to-end sealed payloads, stateless signed push tokens, no database ([PUSH.md](PUSH.md)). Also: local-only mode (no relays) and self-hosted relays with webhooks | Nothing to sign up for |
| D17 | Multiplayer | Invite link or QR = iroh ticket + **attenuable signed grant** (scope, role, expiry, uses), bound to the guest's device key on first use; the secret sits in the URL fragment. Roles **Viewer / Prompter / Driver / Approver / Owner** per session or pane; a per-pane control lease; the first valid signed approval wins; a hash-chained audit log. Grants are an Ed25519 chain (`crates/grants`, postcard): verification is one signature per link plus hash lookups. Details in [DAEMON.md](DAEMON.md) §6 | Works over any agent CLI, peer to peer, end to end encrypted, no vendor account |
| D18 | Protocol checks | Principal is separate from device; the grant is checked on every ctl message, input frame, workspace request and stream ([DAEMON.md](DAEMON.md) §6.3); actor ids on input and decisions; single-response approvals; reserved presence messages; grant-filtered pane list; versioned tickets and revocation | |
| D19 | Host platforms | **macOS and headless Linux are equal hosts** (including cloud VMs, x86_64 and aarch64). Static musl daemon binary (cargo-zigbuild), XDG dirs, systemd `--user` / launchd service, headless pairing (terminal QR and ticket text), install via `curl \| sh` or one tap over SSH from the phone. Cloud VMs need no inbound ports | |
| D15 | Licensing | Apache 2.0. Third-party code and its licences are credited in [NOTICE](../NOTICE) | |

## 4. Wire protocol (summary)

One iroh connection per (device, daemon), ALPN `gudo/1`, postcard, every message versioned. The
full protocol is in [DAEMON.md](DAEMON.md).

| Stream | Priority | Content |
|---|---|---|
| `ctl` bidi | 100 | Hello/Welcome/resume, pane meta, agent events, focus and visibility, resize, echo hints |
| `input` c→s | 90 | Keys, paste, mouse, tagged `(pane_id, input_seq)`; never in 0-RTT |
| `pane/<id>` s→c | 80 focused, 50 visible, none for background | `Bytes{seq}` / `Snapshot{seq, gen}` / `InputAck` |
| `bulk` | 1 | Scrollback pages, files, images |

- Background panes send metadata only. Each pane has an unacked byte budget; past it the daemon
  stops sending bytes and sends one snapshot later. Stream priorities alone do not protect
  keystrokes on a bottleneck (p99 +100 ms); the budget does (+9 ms). Size it as **link rate ×
  allowed added delay** (about 32 KB at 20 Mbit/s for about 10 ms), not bandwidth × RTT × 2
  (+39 ms). Snapshots of a flooding pane are rate-limited and zstd-compressed (a worst-case
  200 KB snapshot compresses to 42 KB).
- Resume: the client paints its cached snapshot at once (dimmed), re-dials, and the daemon
  replays from the ring buffer or sends a snapshot, focused pane first.
- Echo prediction uses real PTY facts (`ECHO`/`ICANON`, alt screen, OSC 133) and never predicts
  at password prompts.
- Sizing: each client has its own size; the PTY follows the client that last typed, and the UI
  shows it.
- Client and daemon must use the same Ghostty snapshot format version. The handshake checks it
  and offers a one-tap daemon upgrade.

## 5. Mobile UX

1. **Just SSH**: type `user@host`, saved automatically, one tap to move to a Secure Enclave key.
2. **Agent Inbox** across hosts, "Needs you" first; Approve, Deny and Reply inline; actionable
   notifications and Live Activities; approve from the lock screen.
3. **Context-aware key bar** (shell, Claude, Codex, vim, less), sticky one-shot Ctrl, composer
   mode for agents, hold to repeat.
4. **iPad**: sidebar and up to 4 splits, multiple windows, Stage Manager, external display with
   keyboard focus kept on the iPad, full hardware keyboard shortcuts.
5. **Foldables**: cover, open and half-folded "duo" (output on top, input below), toggled by hand
   until a posture API exists.
6. **Never a blank screen** when the app comes to the foreground.

## 6. Repo layout

```
gudo/
├─ Cargo.toml                 # virtual workspace, shared dependencies and profiles
├─ crates/
│  ├─ proto/                  # wire types and codecs
│  ├─ ghostty-vt-sys/         # zig build of the pinned libghostty-vt, checked-in bindgen
│  ├─ ghostty-vt/             # safe wrapper and snapshot API
│  ├─ agents/                 # manifests, detection, AgentEvent, resume recipes, hook shim
│  ├─ daemon/                 # the daemon as a library
│  ├─ hostd/                  # gudo-hostd and gudo-hook binaries
│  ├─ client-core/            # client core: iroh, seq/ack, resume, prediction
│  ├─ apple-ffi/              # UniFFI surface, built into GudoCore.xcframework
│  ├─ ssh/ pty/ push/ grants/ drawing/ brand/ cli/ stress/
├─ apple/                     # Xcode project (XcodeGen): iOS, iPadOS and macOS apps, Swift packages
├─ services/                  # push relay (Cloudflare Worker), iroh relay setup
├─ sdk/typescript/            # client for scripts that drive the terminal from a pane
├─ xtask/                     # build-xcframework and release tasks
├─ vendor/ghostty             # pinned submodule
└─ docs/
```

Every brand-bearing string (ALPN, bundle ids, the `GUDO_` env prefix, binary names, config dirs,
URL schemes) is defined once: `crates/brand` for Rust and `apple/Brand.xcconfig` for Swift and
Info.plist.

Build settings: stable Rust; `debug = "line-tables-only"`, dependencies at `opt-level = 1` without
debuginfo, crypto and QUIC dependencies at `opt-level = 3`; a `dist` profile with fat LTO; the
Apple default linker on macOS. Zig 0.17 builds libghostty-vt; Ghostty requires the major.minor
version to match exactly.

## 7. Editor

The editor is Microsoft's VS Code, reached only through paths its licence allows, because the app
ships to other people and we may not host or redistribute VS Code Server ourselves:

- Default: Microsoft's VS Code server (`code serve-web`) runs on the user's host and is reached
  over our direct iroh port forward. No Microsoft relay and no sign-in. The app shows Microsoft's
  licence terms once per host and starts nothing until the user accepts.
- On the Mac, "Open in VS Code" opens the user's desktop VS Code with Remote-SSH over our forward.
- Opt-in: the VS Code Remote Tunnel (`code tunnel`) under the user's own GitHub or Microsoft
  account, opened in vscode.dev or desktop VS Code.
- VSCodium is the automatic fallback; openvscode-server is used only when chosen explicitly.

Details in [DAEMON.md](DAEMON.md) §5.3.
