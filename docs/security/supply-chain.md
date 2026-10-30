# Supply chain, builds, helper distribution and unsafe code

What could put someone else's code in our binaries, or let bytes from the outside corrupt
memory in them, and what stops that.

## Assets

- The code users run: the iOS/iPadOS/macOS app (with `UnnamedCore`, libghostty-vt and the
  bundled Linux and macOS helpers), and `unnamed-hostd` on their hosts. The helper runs as the
  user with their shell, files, SSH agent and agent credentials, so whoever controls its code
  controls the host.
- The signing identity (Developer ID, App Store), the notarization credentials, the Cloudflare
  token that deploys the push relay, and the APNs key it holds.
- The repository and its history.

## Attackers

1. **A compromised dependency**: a malicious crate or npm package (typosquats like
   `faster_log`, account takeovers like the 2025 chalk/debug compromise and the Shai-Hulud
   worm, which ran in `postinstall` and stole tokens), or a backdoored upstream release
   (xz-utils 2024).
2. **A compromised build tool or CI action** (tj-actions/changed-files 2025: tags moved to a
   commit that dumped CI secrets).
3. **A network attacker or a hostile mirror** on any download: helper installs, editor
   servers, build-time fetches.
4. **A hostile terminal program or host**: bytes a program prints (`cat` of a crafted file,
   output over SSH), and snapshots/history a host sends to a client. For a guest in
   multiplayer the host is someone else's machine.
5. **Someone reading the public repository** for leaked keys.

## What we defend, and how

### Dependencies

- `deny.toml` (`cargo deny check`): RustSec advisories (vulnerable and yanked crates fail;
  unmaintained ones are reported), licences limited to permissive ones (MIT, Apache-2.0, BSD,
  ISC, Zlib, Unicode, CC0, … — GPL/LGPL/AGPL and unknown licences fail; MPL-2.0 is allowed
  only for UniFFI, unmodified), crates.io as the only source (no git dependencies, no other
  registries), no wildcard versions, and no OpenSSL / aws-lc / native-tls (ring and rustls are
  the only crypto). `cargo audit` reads the same ignores from `.cargo/audit.toml`.
- Accepted advisories, each with its reason in `deny.toml`: RUSTSEC-2023-0071 (RSA Marvin
  timing; russh only signs and verifies with RSA, the attack needs decryption) and two
  unmaintained build-time-only crates (`basic-toml` under uniffi_bindgen, `paste` under iroh's
  netlink crates).
- `Cargo.lock` is committed and CI builds with `--locked`.
- npm: the push relay has no runtime dependencies (the Worker bundles only our code); its dev
  tools are pinned to exact versions with a lockfile, installed with `ignore-scripts=true`
  (`services/push-relay/.npmrc`), and `npm audit` must be clean. The app's two JS bundles
  (Excalidraw, the agent browser's Playwright/rrweb scripts) are built from lockfiles with
  `npm ci --ignore-scripts`; Playwright's sources are additionally pinned by commit and a
  SHA-256 over the extracted tree.
- Swift: the app has no remote Swift packages; every package is local.
- libghostty-vt: `vendor/ghostty` is a submodule at Ghostty's `v1.4.0` tag
  (`83fb956…`), built from source by `ghostty-vt-sys` and `cargo xtask build-xcframework`.
  CI checks the commit.

### CI (`.github/workflows/security.yml`)

Actions pinned by full commit SHA, `permissions: contents: read`, checkouts without stored
credentials, no `pull_request_target`, no secrets. Jobs: gitleaks over the whole history
(binary pinned by SHA-256), a check for bidirectional/invisible Unicode in tracked files
(`scripts/check-invisible-unicode.py`), `cargo fmt`, `cargo clippy -D warnings`,
`cargo deny`, and the push relay's `npm ci --ignore-scripts`, `npm audit`, tests. A weekly
run catches new advisories against unchanged dependencies. Release signing must never run in
a workflow that pull requests can trigger.

### Secrets

gitleaks over all 323 commits found no real secret. The seven hits are reviewed false
positives listed in `.gitleaksignore` (RFC 6455's sample WebSocket key in a test, a truncated
test PEM, Swift parameters named `deviceKey`, and the public Firebase web config inside
Excalidraw's upstream bundle). `.gitignore` excludes `.dev.vars` (the relay's local secrets);
signing and notarization credentials live only in the developer's keychain
(docs/MAC-DISTRIBUTION.md).

### Helper distribution and updates

There is no download server and no update channel to hijack:

- **Install over SSH** (`ssh::bootstrap`, docs/SSH.md §3): the helper binaries are inside the
  signed app bundle, so the app's code signature is their integrity root. The app uploads the
  bytes over the authenticated SSH channel (host key checked first); the remote writes them to
  a temp file with `umask 077`, computes SHA-256 and compares it with the hash the app
  computed, and only then `chmod`s and renames the file into place and runs it. Nothing in
  the scripts comes from the user or the remote: paths are constants, quoted, and the only
  numbers are ours (Teleport CVE-2022-36633 and JetBrains Toolbox CVE-2025-42921 were
  injection into exactly this kind of script).
- **Self-upgrade over iroh** (`crates/daemon/src/upgrade.rs`): only the owner can stream a
  build; the daemon checks the size, the SHA-256 from the header, and that the new file runs
  and reports this OS and CPU before it atomically replaces itself. The owner already has a
  shell on the host, so this grants nothing new.
- **Editor servers** (openvscode-server on Linux, VSCodium): downloaded on demand from the
  projects' GitHub releases and checked against SHA-256 values compiled into the daemon
  before unpacking (`crates/daemon/src/ws/editor.rs`). On macOS VS Code's own `code` CLI
  fetches its server, verified by Microsoft's tooling.
- The `curl … | sh` lines the app shows for installing agent CLIs (Claude Code, Codex) are
  the vendors' own official installers, shown for the user to run; we never run them.

### Release builds

- Rust `release`: thin LTO, line tables only; the shipped static library is stripped by
  xtask (`strip -S`). `dist`: fat LTO, one codegen unit, debug info stripped. Panics unwind
  (tokio contains a panicking task); overflow checks are off as is Rust's default.
- Mac: Developer ID, hardened runtime with one exception (microphone), no
  `com.apple.security.cs.*` exceptions (no JIT, no unsigned memory, no dyld environment, no
  disabled library validation), no `get-task-allow` in Release, notarized and stapled
  (docs/MAC-DISTRIBUTION.md). The bundled helper is signed with the same team and runtime.
- Everything ships built from source in this repository: the xcframework from the Rust
  crates and the pinned Ghostty source, the helpers with cargo/cargo-zigbuild.

### Unsafe code and untrusted bytes

`unsafe` lives in `ghostty-vt` (the libghostty-vt wrapper), `pty`, `daemon/procinfo.rs` and
small libc calls. The wrapper's blocks have `SAFETY` comments and own their handles; the
review focused on what untrusted bytes reach: terminal output (including kitty graphics
images) and snapshot / history records.

Found and fixed: **a few bytes of program output could abort the daemon or the app.** The
PNG decoder we give libghostty-vt for kitty graphics (`f=100`) allocated whatever size the
PNG header claimed before decoding. A ~100-byte escape sequence claiming a 16M×16M image made
it request a petabyte and abort the process: every pane on the host gone, or the client app
crashed. It now refuses images over libghostty-vt's own limits (10,000 px a side, 400 MiB
decoded) before allocating, and a panic in the decoder can no longer unwind into C. Tests:
`kitty::tests::oversized_pngs_are_refused_before_allocating` and
`programs_cannot_crash_the_terminal_with_a_png_header` (both abort without the fix).

Robustness test for decoding: `crates/ghostty-vt/tests/it/corrupt.rs` mutates a real snapshot
(bit flips, byte runs, extreme length fields, truncation, splices, then recomputed record
CRCs so the damage reaches the payload decoders) and runs every decode path: full decode,
READY + pages, streaming history restore, then renders, re-encodes and keeps writing. For a
soak with libghostty-vt's safety checks on:

```sh
LIBGHOSTTY_VT_OPTIMIZE=safe CORRUPT_SEEDS=100000 CARGO_TARGET_DIR=target/safe \
  cargo test -p ghostty-vt --test it corrupt
```

## Residual risk

- **Ghostty 1.4.0's snapshot decoder trusts invariants a crafted snapshot can break.** The
  soak above (safety checks on) found, in upstream code that is unchanged on Ghostty `main`:
  1. `BitmapAllocator.findFreeChunks` (`src/terminal/bitmap_allocator.zig`) reads, and can
     then write, one bitmap word past the end when a request over 64 chunks starts in the last
     word. A snapshot page with a small string capacity and a long hyperlink reaches it. In our
     shipped builds (`ReleaseFast`, no bounds checks) that is an out-of-bounds read and write
     in page memory: memory corruption driven by the snapshot. One-line fix: return `null`
     when `i >= bitmaps.len` after the loop. Live terminal output did not reach it in our
     probes (OSC strings are capped at 2 KiB, one bitmap word's worth).
  2. The formatter hits `unreachable` for a decoded charset state with GR = G0, which
     snapshots may carry (`src/terminal/formatter.zig`).
  3. `Terminal.index` asserts that a cursor in output mode has no clear-at-EOL flag; a
     snapshot can set both.
  Items 2 and 3 are undefined behaviour in `ReleaseFast` but unlikely to be exploitable.
  Who can send a snapshot: the daemon (to its own clients; for a multiplayer guest that is
  someone else's host) and the daemon's own state directory. The ignored test
  `corrupt::upstream_decoder_bugs` reproduces all three with `LIBGHOSTTY_VT_OPTIMIZE=safe`;
  with local patches for the three, 150,000 further mutated snapshots decoded cleanly. Fix:
  report upstream with the reproducers, then pin the fixed release. Until then, either carry
  the patches on a fork of the submodule, or build libghostty-vt with `ReleaseSafe`, which
  turns these into a clean abort instead of corruption. The owner has to choose between them.
- The Excalidraw bundle's lockfile has known advisories (nanoid, lodash-es and Mermaid's
  parser chain). The Mermaid chain is aliased out of the bundle; nanoid and lodash-es are
  not reachable with attacker input in the canvas. Fix them when the bundle is next rebuilt
  (npm `overrides`), then re-verify the canvas.
- The helpers are not signed with a release key separate from the app. That is fine while
  the app is the only way they travel. The planned Linux `curl | sh` installer (ARCHITECTURE
  D19) must not ship without one: publish an Ed25519 (minisign-style) signature made with an
  offline key that is not on the download server, have the script verify it with the public
  key embedded in the script before anything is executed, and pin the version.
- Self-upgrade accepts any build the owner sends, including an older one. An owner is
  already trusted with a shell on the host, so this is a rollback risk only if an owner
  device is compromised.
- Dependencies are reviewed by advisories and licences, not by reading their code
  (`cargo vet` would add that). New crates still need a human look at the publisher and the
  name (typosquats).
- The shipped Rust crates' and the Linux helper's licence notices are not yet collected into
  THIRD_PARTY_NOTICES (MIT/BSD require the notice to travel with binaries). `cargo about`
  can generate them.
