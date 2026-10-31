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
  (`83fb956…`). We carry our own fixes as `patches/ghostty/*.patch` (until upstream ships
  them, see Residual risk). Every build compiles the same tree: `scripts/ghostty-source.sh`
  exports the pinned commit (`git archive`, so local edits in the submodule never leak in),
  applies the patches with `git apply` and fails the build if one does not apply.
  `ghostty-vt-sys` (cargo, xtask, the helpers) and `apple/scripts/build-libghostty-vt.sh`
  (TerminalKit) both use it. CI checks the submodule commit.

### CI (`.github/workflows/security.yml`)

Actions pinned by full commit SHA, `permissions: contents: read`, checkouts without stored
credentials, no `pull_request_target`, no secrets. Jobs: gitleaks over the whole history
(binary pinned by SHA-256), a check for bidirectional/invisible Unicode in tracked files
(`scripts/check-invisible-unicode.py`), `cargo fmt`, `cargo clippy -D warnings`,
`cargo deny`, `ghostty-vt`'s tests with libghostty-vt's safety checks on
(`LIBGHOSTTY_VT_OPTIMIZE=safe`), `cargo xtask notices --check`, `npm audit` of both app JS
bundles, and the push relay's `npm ci --ignore-scripts`, `npm audit`, tests. A weekly
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
- **No silent rollback.** The daemon refuses a build older than itself (lower protocol
  level, or the same level from earlier source; `UpgradeFailure::Older`). Only an explicit
  downgrade from the owner (`StreamHeader::Downgrade`, `un daemon upgrade --allow-downgrade`)
  installs one; the app never sends it. The SSH bootstrap stages a new build next to an
  installed one that reports its version and keeps the installed build if it is newer
  (`InstallAction::KeptNewer`), so an older app on another device cannot reinstate an old
  helper with known bugs (`BootstrapOptions::allow_downgrade` overrides).
- **Editor servers** (openvscode-server on Linux, VSCodium): downloaded on demand from the
  projects' GitHub releases and checked against SHA-256 values compiled into the daemon
  before unpacking (`crates/daemon/src/ws/editor.rs`). On macOS VS Code's own `code` CLI
  fetches its server, verified by Microsoft's tooling.
- The `curl … | sh` lines the app shows for installing agent CLIs (Claude Code, Codex) are
  the vendors' own official installers, shown for the user to run; we never run them.

### Release builds

- Rust `release`: thin LTO, line tables only; the shipped static library is stripped by
  xtask (`strip -S`). `dist`: fat LTO, one codegen unit, debug info stripped. Panics unwind
  (tokio contains a panicking task). Overflow checks stay on in `release` (and `dist`), so an
  overflow panics instead of wrapping into a wrong length; the flood and forward throughput
  tests showed no measurable cost.
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
crashed. It now refuses images over 10,000 px a side or, as RGBA, over the 64 MiB image
storage before allocating, and a panic in the decoder can no longer unwind into C. Tests:
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

- **Ghostty 1.4.0 bugs we patch locally until upstream fixes them** (`patches/ghostty`):
  1. `BitmapAllocator.findFreeChunks` read, and could write, one bitmap word past the end
     when a request over 64 chunks started in the last word; a snapshot page with a small
     string capacity and a long hyperlink reached it (memory corruption in `ReleaseFast`).
  2. The snapshot decoder accepted GR = G0, which the formatter treats as `unreachable`.
  3. The decoder accepted clear-at-EOL on output content, which `Terminal.index` asserts
     against.
  4. A kitty graphics load could hold ~400 MB at each step whatever the image storage limit
     (~380 KiB of `o=z` data, or endless chunked loads, from any program's output).
  Fixes 2–3 degrade the invalid state on decode, as Ghostty's snapshot code does for other
  ghostty-org; drop each patch when the pinned release contains it (`ghostty-source.sh`
  fails loudly once a patch no longer applies).
- The Excalidraw lockfile pins fixed nanoid, lodash-es and katex through npm `overrides`
  (`npm audit` clean, checked in CI). The rebuilt `canvas.js` is byte-identical: the bundle
  only calls `nanoid()`, which the fixes did not touch, and the other two sit in the Mermaid
  chain that is aliased out.
- The helpers are not signed with a release key separate from the app. That is fine while
  the app is the only way they travel. The planned Linux `curl | sh` installer (ARCHITECTURE
  D19) must not ship without one: publish an Ed25519 (minisign-style) signature made with an
  offline key that is not on the download server, have the script verify it with the public
  key embedded in the script before anything is executed, and pin the version.
- Dependencies are reviewed by advisories and licences, not by reading their code
  (`cargo vet` would add that). New crates still need a human look at the publisher and the
  name (typosquats).
- Licence notices: `cargo xtask notices` generates them for every Rust crate in the app core
  and the helpers (cargo-about), the npm packages in both JS bundles and the native code
  (`scripts/notices/native.txt`, kept by hand: libghostty-vt and its Zig/C dependencies,
  musl, Rust's standard library). The app shows them in Settings ▸ Acknowledgements ▸
  Open-Source Licenses, the helper prints its own with `unnamed-hostd licenses`, and CI fails
  when they are stale. The native list must be updated by hand when Ghostty's linked
  dependencies change.

## Validation

Each fix was mutation-checked: the fix was removed or weakened, its test had to fail, then
the fix was restored.

| Claim | Exploit / regression test | Mutation result |
| --- | --- | --- |
| PNG side limit (10,000 px) | `kitty::tests::oversized_pngs_are_refused_before_allocating` (10,001×1 image) | fails without the side check |
| PNG RGBA size within the 64 MiB storage | `kitty::tests::oversized_pngs_are_refused` (5,000² grey PNG under 1 MiB) | fails without the area check |
| PNG output-buffer check | none possible: implied by the two checks above (≤ 4 bytes a pixel after `normalize_to_color8`) | no test fails, as expected; kept as defence in depth |
| Decoder panic cannot unwind into C | none: no input known to panic the `png` crate | not testable |
| Ghostty `findFreeChunks` out of bounds (patch 0001) | Zig test "findFreeChunks larger than 64 chunks starting in the last bitmap"; `corrupt::upstream_decoder_bugs` with `LIBGHOSTTY_VT_OPTIMIZE=safe` | both fail without the patch (index out of bounds) |
| GR = G0 and clear-at-EOL degraded on decode (patch 0002) | Zig tests "cursor flags decoding keeps clear-at-EOL only off output", "header decoding normalizes…", "saved cursor … normalizes…"; `corrupt::upstream_decoder_bugs` | fail without each half of the patch |
| Kitty loads bounded by the storage limit (patch 0003) | `image_bombs::transmissions_stay_within_the_image_storage` | fails without the patch |
| Patches apply deterministically or the build fails | `scripts/ghostty-source.sh` run twice (same tree), and with a patch that does not apply | exit 1 naming the patch |
| No silent self-upgrade rollback | `upgrade::an_older_build_needs_the_owners_explicit_downgrade` (real daemon over QUIC; a guest's downgrade is refused, the owner's explicit one installs) | fails without the version check |
| SSH install keeps a newer helper | `bootstrap::an_older_helper_never_replaces_a_newer_install` (real OpenSSH in a VM) | fails without the check |
| SSH upload refuses bytes changed in transit | `bootstrap::a_tampered_upload_is_refused_and_installs_nothing` (a hostile remote `gzip` corrupts the stream; nothing installed, no temp file left) | fails without the remote SHA-256 comparison |

Also run for this pass: `cargo deny check` and `cargo audit` (clean), gitleaks over all 361
commits (no leaks), `scripts/check-invisible-unicode.py` (clean), `npm audit` of the push
relay and both app bundles (clean), each CI step by hand (`act` is not installed), and a
20,000-seed corrupt-snapshot soak with libghostty-vt's safety checks on and all patches
applied (clean).
