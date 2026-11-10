# SSH client (`crates/ssh`) and plain-SSH panes

Status: working end to end against OpenSSH 9.6 (Ubuntu 24.04 arm64 VM). The
zero-setup path of D7 and rungs (c) and (d) of the 05 §8 ladder: dial any host with plain SSH,
show a terminal right away, and upgrade to the daemon over iroh with one tap.

## 1. API

All types are owned, errors are one `Clone` enum (`SshError`, with `is_fatal()`), callbacks
are `Send + Sync` trait objects, and the async methods are plain `async fn`s: UniFFI can
export them as async functions and callback interfaces without wrappers.

| | |
|---|---|
| `SshConfig::{parse, load, load_default}` → `resolve(alias)`, `target(dest, user)`, `host_aliases()` (for import), `with_home` | `~/.ssh/config` with OpenSSH semantics: `Host` (`*`, `?`, `!`), `Match host/originalhost/user/all`, `Include` (globs, scoped like OpenSSH), first value wins; `HostName` (`%h`), `User`, `Port`, `IdentityFile` (accumulates, `~`/`%d %u %h %r %p`), `ProxyJump` (chains, `none`), `IdentitiesOnly`, `IdentityAgent`, `ServerAliveInterval`, `ServerAliveCountMax`, `ConnectTimeout`, `HostKeyAlias`, `ForwardAgent`, `SetEnv`. Unknown keys are listed in `HostConfig::ignored` |
| `SshConfig::route(dest, proxy_jump, user)` → `Route { target, jump_identity_files }` | the route with an optional `-J` override, and each jump host's own `IdentityFile`s |
| `Destination` | `[ssh://][user@]host[:port]`, `[v6]:port` |
| `HostInput::parse` | the host field: an alias, a destination, or a pasted `ssh -p 2222 -i key -J jump user@host cmd` (options after the host count, `-l`/`-p` win, as in ssh(1)) |
| `local_keys(dir)`, `agent_keys(socket)`, `known_host_names(text)`, `PublicKeyInfo::parse` | what a desktop already has: key pairs in `~/.ssh` (type, comment, fingerprint, encrypted), agent identities, plain known_hosts names. Private keys are only checked for encryption |
| `Target { jumps, host: HostSpec }` | route, outermost jump first |
| `Credentials` of `AuthMethod`s, tried in order (per jump host: `ConnectOptions::jump_credentials`) | `Agent(path or $SSH_AUTH_SOCK)`, `AgentKey { socket, fingerprint }` (one agent identity only, so a full agent cannot hit `MaxAuthTries`), `Key(SecretKey)`, `External(Arc<dyn ExternalSigner>)`, `Password` (then keyboard-interactive answering password prompts: macOS/PAM), `Interactive(responder)` (OTP, Tailscale check mode). `Credentials::openssh_defaults(files)` mimics `ssh` on a desktop |
| `SecretKey::{decode, load, is_encrypted}` | OpenSSH/PKCS#8/PKCS#1/SEC1 PEM; ed25519, ecdsa P-256/384/521, rsa (rsa-sha2-512/256 per server-sig-algs); passphrases |
| `AuthMethod::{key, key_file}` | a passphrase-protected key becomes `EncryptedKey`, decrypted on a blocking thread when first offered (its KDF never runs on the caller's thread); a wrong passphrase fails authentication |
| `generate_key(Ed25519 \| Rsa4096, comment, passphrase)` → `GeneratedKey` | private PEM (encrypted like `ssh-keygen` with a passphrase), `authorized_keys` line, `SHA256:` fingerprint |
| `authorize_key_command(public_key)` | `ssh-copy-id` as one `sh` command: validated, quoted, appended once, `700`/`600` |
| `ExternalSigner` | `public_key()` (OpenSSH line) + `sign(data)` → raw signature (`r‖s` as CryptoKit gives, or DER; 64 bytes for Ed25519). Runs on a blocking thread, so it may wait for Face ID. A failing signer skips that method. For `sk-ecdsa-sha2-nistp256@openssh.com` / `sk-ssh-ed25519@openssh.com` keys, `sign_security_key(data)` returns a CTAP2 assertion (signature, flags, counter) and the crate encodes the PROTOCOL.u2f blob |
| `KnownHosts::{in_memory, from_text, open}` | OpenSSH known_hosts: patterns, `[host]:port`, hashed `\|1\|` entries, `@revoked`; `check`, `add`, `pin`, `replace`, `remove`, `to_text`; `with_listener(KnownHostsListener)` reports every change (the app persists the text) |
| `HostKeyPolicy::{Strict, AcceptNew, Ask(prompt)}` | `Ask` calls `HostKeyPrompt::trust_new_host(HostKeyInfo)` after the key exchange and before any credential is sent; for a changed (unpinned) key it calls `trust_changed_host(info, expected)` (default: refuse, i.e. `HostKeyMismatch`; `true` replaces the record) |
| `Connection::connect(&Target, &ConnectOptions)` | one live, authenticated connection; clones share it |
| `conn.exec / exec_with_input` → `ExecOutput` | stdout, stderr, exit status or signal; `check()` turns failure into `SshError::Remote` |
| `conn.open_shell(&PtyRequest)` → `(Shell, ShellOutput)` | PTY (`TERM`, size, `IUTF8`), env, optional command; `Shell::{write, resize, close}`, `ShellOutput::next()` → `Data`/`Stderr`/`Exit` |
| `conn.upload(path, bytes, mode, Raw\|Gzip)` / `download` | exec-based, no SFTP: temp file, SHA-256 checked on the remote, `chmod`, atomic `mv`; `~/` paths, spaces fine |
| `conn.{ping, probe, note_input, rtt, closed, is_dead}` | liveness (§2) |
| `Session::start(target, options, ReconnectPolicy, listener)` | the self-healing handle views keep (04 R7): `state()`, `subscribe()`, `connected()`, `connection()`, `set_foreground`, `network_changed`, `reconnect_now`, `close` |
| `bootstrap(&conn, &HostdBinaries, &BootstrapOptions)` → `BootstrapReport` | §3 |
| `client_core::SshPane::open(session, SshPaneOptions, listener)` | §4 |

Host keys: a host with keys on record must present one of them, else `HostKeyMismatch {
host, expected: [SHA256:…], actual }` (never retried; prompts only through `HostKeyPrompt::trust_changed_host`, whose default refuses). Connections offer the
key types on record first, so a host with several keys presents the one we know. Pins
(`KnownHosts::pin`, e.g. a key the paired daemon attests over iroh, 05 §6.5) override all
other entries for that host.

## 2. Reliability (fixing 04 B1/B2)

"Connected" means a keepalive was answered recently (04 R2), never a socket flag. Each
`Connection` runs a monitor task; every operation on a dead connection (exec, channel open,
shell write/resize, shell output) fails at once instead of waiting on the socket.

| Setting | Default | Meaning |
|---|---|---|
| `Keepalive::interval` | 15 s (`ServerAliveInterval`) | a `keepalive@openssh.com` request is sent this often and must be answered before the next is due |
| `Keepalive::count_max` | 3 (`ServerAliveCountMax`) | consecutive misses that declare the peer dead; after a miss the next keepalive goes out at once, so an idle silent drop is detected `interval × count_max` after the first unanswered keepalive: **45-60 s** after the drop, ≤ `interval × (count_max + 1)` = 60 s after the last answer |
| `Keepalive::probe_timeout` | 5 s | a *probe* (foreground, network change, or input after ≥ 1 interval without an answer) must be answered within this, else dead at once; a probe also shortens a keepalive already in flight |
| `Timeouts::connect` / `handshake` / `auth` | 10 / 15 / 60 s | per hop; host-key prompts are outside these |
| TCP | `TCP_NODELAY`; addresses raced RFC 8305-style (IPv6 first, next family after 250 ms) | |
| `ReconnectPolicy::initial_delay`, `max_delay` | 250 ms, 8 s | backoff `min(8 s, 250 ms × 2^(n−1))` ± 20 % jitter: 0.25, 0.5, 1, 2, 4, 8, 8 … s |
| `ReconnectPolicy::stable_after` | 10 s | a connection that lived this long is redialled at once when it drops and resets the backoff; a shorter one counts as a failure (no hot loop) |
| `ReconnectPolicy::background_attempts` | 3 | in the background the session goes `Offline` after 3 failures; **in the foreground it never gives up**. `set_foreground(true)`, `network_changed()` and `reconnect_now()` cut any wait short and reset the budget (04 R10) |

States (`SessionListener::on_state`): `Connecting{attempt}` → `Connected{generation}` →
`Reconnecting{attempt, retry_in, reason}` … ; `Offline{reason}` (background, budget spent);
`NeedsAttention{error}` (auth failed, host key changed or refused, bad key: not retried
until `reconnect_now`); `Closed`. A new `generation` means channels were lost.

Measured against the VM (debug build, test keepalive 1 s × 3, probe 1-1.5 s):

| | |
|---|---|
| silent drop (traffic blackholed, sockets open), idle | detected in 3.96-4.00 s (= interval × (count_max + 1)) |
| frozen sshd session process (SIGSTOP) | 3.94-3.96 s |
| fast probe after a silent drop | 1.00 s (= probe timeout) |
| input typed after an interval of silence on a dead link | 1.00 s |
| session: path heals → `Connected` again (handshake timeout 2 s, max backoff 1 s) | 2.7-2.8 s |
| fallback pane: path heals → new shell on screen | 0.34 s |
| keepalive RTT on the LAN VM | 0.4-0.6 ms |
| first PTY command round trip / keystroke echo | 5.7 ms / 0.17 ms |
| connect through 2 jump hosts (3 handshakes) | 176 ms |
| upload 4 MiB raw / gzip (half random) | 68 ms / 82 ms (2.1 MB on the wire) |

With the defaults the same sequence takes ≤ 60 s idle (OpenSSH parity) and ≤ 5 s whenever
the app probes (foreground, path change, typing).

## 3. Daemon bootstrap (`ssh::bootstrap`)

The client
holds the binaries, checks SHA-256, uploads; the remote never downloads. Each step is one
`exec` round trip under `sh -c` (works whatever the login shell is):

1. **Probe**: `uname -s`/`-m`, `$HOME`, gzip present, SHA-256 of an installed
   `gudo-hostd`, `gudo-hostd status`, `loginctl` linger.
2. **Pick** the build: `HostdBinaries { linux_aarch64, linux_x86_64, macos_aarch64,
   macos_x86_64 }` (each `Bytes` or `Path`). Linux builds are static musl:
   `cargo zigbuild --release -p hostd --target {aarch64,x86_64}-unknown-linux-musl`, then
   strip (18.7 MB); macOS: `cargo build --release -p hostd`.
3. **Upload** only if the installed SHA-256 differs: gzip on the wire (18.7 → 7.9 MB),
   to `~/.local/bin/gudo-hostd` (Linux) or `~/Library/Application Support/gudo/bin/`
   (macOS), verified on the remote, then renamed into place.
4. **Start** if uploaded or not running: `gudo-hostd service install` (systemd `--user`,
   now restarting an older daemon; LaunchAgent). If no service manager works (container,
   macOS without a GUI login), the daemon is started detached (`setsid … run`) and the report
   says so. A note suggests `loginctl enable-linger` when lingering is off.
5. **Pair**: `gudo-hostd pair --json --wait 30` (new, backwards compatible) waits for a
   live daemon to record its endpoint and, up to 10 s more, its home relay, then prints
   `{ticket, daemon_id, expires_unix_ms, addrs, relay_url, running, version}`.

Idempotent: same build + running → `Reused`/`AlreadyRunning`, only a new ticket; another
build → `Upgraded` and restarted with its state (daemon id, paired devices, layout) kept.
`BootstrapListener` reports `Probing`, `Uploading{size, sent}`, `Starting`, `Pairing`.

Measured (release, Mac → VM): fresh install 4.2 s = probe 17 ms + upload 0.74 s + service
0.07 s + pairing 3.3 s (mostly the daemon registering with its relay); reuse 43 ms; then
`Client::connect(ticket)` paired over iroh in 33-60 ms. `gudo --ticket <ticket> ls` with a
bootstrap ticket lists the VM's session.

## 4. Plain-SSH fallback panes (`client_core::SshPane`)

For hosts without the daemon (05 §8 rung d). `SshPane::open(session, options, listener)`
opens a PTY channel on a shared `ssh::Session` (one connection per host, one channel per
pane) and emits the same `ClientEvent`s as daemon panes: `PaneBytes{seq}` as one gap-free
stream, `PaneResized{seq}` at the resize point, `Connected{epoch, resumed}`,
`Disconnected{reason}`, `Refused{reason}` (needs attention) and `PaneClosed` when the shell
exits or the pane is closed. After a drop the session redials and the pane opens a new
shell, writing a dim `[connection lost: new shell]` line into the stream (never lose a
session silently). With `tmux_session: Some(name)` the shell runs in `tmux new -A -s name`
when tmux exists, so reconnects re-attach the same session. Input typed while disconnected
is dropped, not replayed into a different shell. `client_core::ssh_runtime()` is a shared
2-thread runtime for driving this from the app.

## 5. Running the tests

Unit tests (config, known_hosts, keys, signature encoding, backoff, session state machine)
run everywhere: `cargo test -p ssh`.

Integration tests need a real sshd. They are compiled always and `#[ignore]`d unless
`GUDO_SSH_TEST_HOST` is set at build time (a `build.rs` cfg):

```sh
scripts/ssh-test-vm.sh            # OrbStack VM `un-linux` (or pass another machine name):
                                  # openssh-server + tmux, user `untest` with a password and
                                  # test keys (ed25519, ecdsa, rsa, encrypted ed25519),
                                  # MaxStartups raised, lingering on, the static hostd build
source target/ssh-test/env        # GUDO_SSH_TEST_{HOST,USER,PASSWORD,KEYS}
cargo test -p ssh --test it       # auth, host keys, PTY, exec, upload, ProxyJump,
                                  # keepalive/dead peer, reconnect, bootstrap
cargo test -p client-core --test it ssh_host   # fallback pane, tmux re-attach,
                                  # fresh bootstrap → pair over iroh → pane echo
```

`GUDO_SSH_TEST_HOSTD` overrides the daemon build the bootstrap tests install. Failures are
injected without root: a test proxy that silently swallows traffic (a dead NAT mapping),
and `kill -STOP` on the connection's own sshd process. ProxyJump uses the VM as the first
hop and its own `127.0.0.1:22` as the next. The external-signer test uses a software P-256
key with the Secure Enclave's output format (raw `r‖s` and DER).

## 6. Not done / follow-ups

- macOS as the bootstrap *target* is implemented (paths, LaunchAgent, detached fallback) but
  not exercised end to end here: it needs a test account on a Mac with Remote Login.
- Security keys: the signature format is done and tested against a software authenticator;
  the apps have no CTAP2 transport yet (planned: Yubico's yubikit-swift, Apache 2.0: USB HID
  on the Mac, NFC and Lightning on iOS), so `sign_security_key` is not implemented there.
- No `ProxyCommand` (no subprocesses on iOS; 10 §4.2), no agent forwarding, no port
  forwarding over SSH yet (the daemon does forwarding over iroh), no host certificates.
- An installed binary whose daemon was not restarted after an interrupted upgrade reads as
  "same build, running"; `status` cannot report the running build's hash yet.
- The fallback pane does not serialize state for iOS suspension; it reconnects instead.
