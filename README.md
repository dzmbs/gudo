# Gudo

Gudo is a terminal and coding-agent workspace for iPhone, iPad and Mac. Your shells, editors and
agents (Claude Code, Codex and others) keep running on your own Mac or Linux machine. Gudo
connects to them from anywhere, end to end encrypted, with no account. Every pane, split and
agent stays where you left it, even after your phone sleeps or switches networks.

<!-- Screenshots go here. -->

## Install

Download the app at [gudo.dev/download](https://gudo.dev/download). Connect to a host with
`user@host`; one tap then installs the host helper there over SSH.

## How it works

A small daemon, `gudo-hostd` (Rust), runs on the host and owns the terminals (Ghostty's
libghostty-vt), agents, files, git, port forwards and the editor. The apps (SwiftUI, with a Metal
terminal renderer) dial it by key over [iroh](https://iroh.computer) (QUIC), directly when they
can and through a relay when they can't. Pairing is a one-time QR code or ticket. Plain SSH works
too. More in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/DAEMON.md](docs/DAEMON.md) and
[docs/APP-ARCHITECTURE.md](docs/APP-ARCHITECTURE.md).

| Path | What |
|---|---|
| `crates/` | Rust: the daemon (`daemon`, `hostd`), the client core (`client-core`, `apple-ffi`), wire types (`proto`), SSH, push, grants, the terminal engine bindings, the `gudo` CLI |
| `apple/` | The Apple apps and their Swift packages ([apple/README.md](apple/README.md)) |
| `services/` | The push relay (Cloudflare Worker) and a self-hosted iroh relay setup |
| `sdk/typescript/` | A typed client for scripts that drive the terminal from a pane |
| `docs/` | Architecture, protocol, security and design notes |
| `vendor/ghostty` | Ghostty, pinned (git submodule) |

## Build from source

You need Rust (the toolchain in `rust-toolchain.toml` installs itself through rustup), Zig 0.17
(builds libghostty-vt), and for the apps Xcode 27 and XcodeGen.

```sh
brew install zig xcodegen
git submodule update --init vendor/ghostty
```

The host daemon:

```sh
cargo build -p hostd              # gudo-hostd and gudo-hook
cargo test -p daemon
```

The apps:

```sh
cargo xtask build-xcframework     # the Rust core as GudoCore.xcframework
cargo xtask build-hostd-linux     # the helpers the app installs on Linux hosts (needs cargo-zigbuild)
cargo xtask build-hostd-macos     # the helper for this Mac
apple/scripts/build-libghostty-vt.sh
cd apple && xcodegen
xcodebuild -project App.xcodeproj -scheme App -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build
```

iOS simulators, tests and signing are covered in [apple/README.md](apple/README.md) and
[docs/APPLE-FFI.md](docs/APPLE-FFI.md).

## Security

Please report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md). The threat
model is in [docs/security/](docs/security/).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

Apache License 2.0 ([LICENSE](LICENSE)). Third-party code and its licences are listed in
[NOTICE](NOTICE) and the `THIRD_PARTY_NOTICES` files it points to.
