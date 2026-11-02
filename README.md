# Gudo

A native terminal and coding-agent workspace for iPad, iPhone and Mac. Your shells, editors and
agents (Claude Code, Codex and others) keep running on your own machines; Gudo connects to them
from anywhere, end to end encrypted, and keeps every pane, split and agent where you left it.

- **Host daemon** (`gudo-hostd`, Rust): runs on macOS or Linux, owns the terminals (Ghostty's
  libghostty-vt), agents, files, git, port forwards and the editor. Devices dial it by key over
  [iroh](https://iroh.computer) (QUIC); pairing is a one-time ticket or QR code.
- **Apps** (SwiftUI): one multiplatform app with a Metal terminal renderer, plus extensions for
  notifications, Live Activities and the Files app.
- **Plain SSH** works too, and installs the daemon on a host in one tap.

Website: [gudo.dev](https://gudo.dev).

## Layout

| Path | What |
|---|---|
| `crates/` | Rust: the daemon (`daemon`, `hostd`), the client core (`client-core`, `apple-ffi`), wire types (`proto`), SSH, push, grants, the terminal engine bindings, the `gudo` developer CLI |
| `apple/` | The Apple apps and their Swift packages ([apple/README.md](apple/README.md)) |
| `services/` | The push relay (Cloudflare Worker) and a self-hosted iroh relay setup |
| `sdk/typescript/` | A typed client for scripts that drive the terminal from a pane |
| `docs/` | Architecture, protocol, security and design notes ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)) |
| `vendor/ghostty` | Ghostty, pinned (git submodule) |

## Building

```sh
git submodule update --init vendor/ghostty
cargo build -p hostd              # gudo-hostd and gudo-hook
cargo test -p daemon
```

The Apple apps: `cargo xtask build-xcframework`, then `xcodegen` in `apple/` and build the `App`
scheme (details in [apple/README.md](apple/README.md)). Zig 0.17 builds libghostty-vt.

## Licence

Apache License 2.0 ([LICENSE](LICENSE)). Third-party code and its licences are listed in
[NOTICE](NOTICE) and the `THIRD_PARTY_NOTICES` files it points to.
