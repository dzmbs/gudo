# Development builds

Debug Apple builds are a separate product. Names come from `apple/Brand.xcconfig`; Rust reads
`GUDO_FLAVOR=dev` at compile time through `crates/brand`. Release identities are unchanged.

| Surface | Release | Debug / dev |
|---|---|---|
| App | Gudo | Gudo Dev |
| Bundle prefix | `dev.gudo` | `dev.gudo.dev` |
| macOS state | `Application Support/Gudo` | `Application Support/Gudo Dev` |
| XDG state | `gudo` | `gudo-dev` |
| Helper | `gudo-hostd` | `gudo-dev-hostd` |
| CLI | `gudo` | `gudo-dev` |
| Service label | `dev.gudo.hostd` | `dev.gudo.dev.hostd` |
| URL scheme | `gudo` | `gudo-dev` |
| Pane environment prefix | `GUDO_` | `GUDO_DEV_` |

Bundle IDs also separate preferences, saved hosts, device identities, replay caches and Keychain
services. Push and Files extension bundle IDs, shared Keychain groups and App Groups derive from
the bundle prefix. The Debug icon carries a DEV badge. Debug builds do not start Sparkle.

## Build

```sh
GUDO_FLAVOR=dev cargo xtask build-hostd-macos
cargo xtask build-xcframework
cd apple
xcodegen generate
xcodebuild -project App.xcodeproj -scheme App -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd-dev build
```

The dev helper is packaged at `apple/build/hostd/macos/dev/gudo-dev-hostd`. Its recursive Cargo
builds use `target/dev`, not the release helper's build directory. A Debug app never falls back to
bundling the release helper. Do not overwrite a helper that a running installation uses.

For direct Rust builds, use `GUDO_FLAVOR=dev CARGO_TARGET_DIR=target/dev cargo build -p hostd`.
Cargo's executable target retains its declared filename; the xtask packages it with the dev name.

The Rust core in the app can pair with either flavor's helper. Pasteable pairing tickets and
invites accept both URL schemes; the app registers only its own scheme with the operating system.

## Isolation rules

Dev helpers do not migrate earlier installations or retire earlier services. The app's legacy
helper migration is also disabled in Debug. Dev panes remove inherited release pane credentials
before setting their own environment.

Dev startup does not register global Claude Code or Codex hooks or MCP tools. Those configurations
belong to the daily installation and must not point at disposable dev binaries. Agents launched
through New Agent still receive the dev pane's launch settings and tools. Manually started agents
in dev panes do not receive automatic dev registration. Use an isolated agent account when testing
configuration changes; never replace the daily agent configuration with dev launcher paths.

Tests use temporary state and HOME directories. Never install a test helper as a service, never
pair or restart the daily helper, and never use macOS UI automation or foreground app launches for
validation. In-process AppTests and offscreen captures do not require switching away from work.

## Real-agent sizing acceptance

`AGENT_TUI_MIRROR=1 scripts/agent-tui-parity.sh /tmp/gudo-sizing` runs the normal startup parity
checks, then a separate direct-PTY fixture for each installed agent. Both clients observe the
same running process. It checks focus reports, activation/background handoff, non-driver resize
bursts, trailing debounce, pixel-only changes, explicit takeover and a preserved unsubmitted
draft. Homes, config, project and placeholder credentials are private; model URLs are loopback.

Sizing must not run through the startup recorder's nested `script` PTY: it can hide the real
resize/input behavior. The sizing fixture saves ten VT snapshots when both agents are installed.
Run `AppTests/AgentSizingCaptureTests` with
`TEST_RUNNER_GUDO_AGENT_SIZING_CAPTURE_DIR=/tmp/gudo-sizing` and `TEST_RUNNER_GUDO_MOCK=1` on
Mac and iOS Simulator, using `-collect-test-diagnostics never`. It verifies geometry and renders
each snapshot at desktop and phone viewports into `native/`. These are native offscreen Debug
captures, not live paired hardware or physical-device Release measurements.
