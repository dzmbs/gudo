# Host-local surfaces

What the daemon exposes on the host itself: the hook socket and its callers (agent hooks,
askpass, the app's browser, the MCP server, terminal tools), files and git, port forwarding,
the editor servers, the state directory, logs, the service and self-upgrade, and the `un` CLI.

## Assets

- **The state directory** (`~/Library/Application Support/unnamed`, `~/.local/state/unnamed`):
  the daemon's iroh secret key, paired devices, grants and invites, pairing secrets, the
  audit log, `hook.token`, editor tokens.
- **The hook token** and the per-pane tokens derived from it (HMAC-SHA256 of the pane id).
  With `hook.token`, a caller can act as any pane. With a pane token, only as that pane.
- **The owner's devices**: the app's in-app browser holds the owner's sign-ins, and the askpass
  sheet takes their passwords.
- **The user's account**: everything a shell running as the user can do.

## Attackers

1. **Another local user on a shared Linux host.** They can read the process list and `/tmp`,
   connect to 127.0.0.1 ports, and plant files in shared directories.
2. **A web page in a browser on the host**, or in the in-app browser. It can make requests to
   localhost and rebind its own DNS name to 127.0.0.1.
3. **Hostile content an agent reads**: terminal output, web pages, repository files. This is
   prompt injection, steering an agent's tool calls.
4. **A hostile repository.** A `.git` directory or `.unnamed.json` from an unpacked archive or a
   clone.
5. **A multiplayer guest** with Viewer, Prompter, Driver or Approver on some scope.

## What we defend, and how

**Hook socket.** The socket is mode 0600. It lives in the 0700 state directory or, when that
path is too long for `sun_path`, in a new 0700 directory with a random name under the
temporary directory, never a predictable `/tmp` name. Every connection is checked with
`SO_PEERCRED`/`getpeereid`. A peer whose uid differs from ours, or whose uid cannot be read, is
dropped before a byte is read. Every call carries a token checked in constant time.

**Tokens.** A pane's environment holds only its own token (`UN_TOKEN`), never `hook.token`. The
MCP server uses the pane's own token whenever its environment, or the agent's, belongs to the
pane it serves. It reads `hook.token` only as a fallback, and never takes it from argv.

What a pane token unlocks: hook events for that pane, askpass prompts for that pane, the
browser calls described next, the session's drawings, and the terminal tools. The terminal
tools read the session's panes and type into or close only panes the caller opened.

**Browser.** URLs and browser tools go only to the owner's devices, never a guest's. A guest's
browser holds the guest's own sign-ins, which the host's programs must not drive or read. When
no app takes a URL, the system opener gets `http(s)` URLs only. `open`/`xdg-open` would also
launch apps and run `file://…/x.command` (compare mcp-remote CVE-2025-6514).

**Terminal tools.** The pane ids in calls are typed integers, and no shell is built from tool
arguments: `cmd_run` types into a pane the agent owns, which is its purpose. One agent,
together with every worker it starts, may have at most 32 panes open. A wait holds at most
1 MiB of output, and results are capped at 256 KiB.

**Files and git.** Path policy (DAEMON.md §5.0): paths must be absolute, with no `..`, and their
real path must lie inside `$HOME` or `files.allow`. Symlinks are checked through their real
targets.

- **State directory.** It is refused even inside a root, so a host-scope Driver cannot silently
  read keys or rewrite the grant store through the Files API.
- **File modes.** Writes never get setuid, setgid or sticky bits from a client.
- **Daemon-run git.** Every call disables the following (the Zed CVE-2026-44465 class):
  - `core.fsmonitor`
  - automatic gc and maintenance
  - the pager and editor
  - hooks (except a user-initiated `push`)
  - the repository's own clean, smudge and process filters (LFS's own excepted)

  Porcelain diffs pass `--no-ext-diff --no-textconv`. Branch and base names that start with `-`
  are refused, and paths come after `--`. `gh` gets fsmonitor and hooks disabled through
  `GIT_CONFIG_*`. The throwaway index lives in a private temporary directory.

**Port forwarding.** TCP forwards connect only to `localhost:<port>`: IPv4 loopback, then IPv6.
No hostname is resolved, so there is no path to the LAN or to `169.254.169.254`. Unix-socket
forwards go through the path policy, which now refuses the daemon's own hook socket. All
forwards need Driver with a host-wide grant, so Viewers and pane-scoped guests cannot forward.

**Editor servers.** The editor servers are bound to 127.0.0.1. The connection token is passed
in a 0600 file (`--connection-token-file`), not on the command line. Other users could read it
from the process list and reach the server on the shared loopback (VS Code
GHSA-54p6-6j68-j5vr). The compressing proxy refuses any `Host` that is not loopback, so DNS
rebinding cannot reach the editor (Ollama CVE-2024-28224, Tailscale TS-2022-004).

**State and temporary files.**

- Secrets are written atomically with mode 0600, and the state directory is 0700.
- Browser snapshots and screenshots saved for agents are created as new 0600 files with
  random names: no symlink following, no world-readable page content.
- A self-upgrade is staged with `O_CREAT|O_EXCL`.
- `un` keeps its device key, tickets and invites as 0600 files in a 0700 directory.

**Logs.** No tokens, answers or terminal text are logged at info level. The first-run pairing
ticket (a bearer credential for ownership) is printed only when stderr is a terminal, never
into a launchd log or the journal.

**Service files.** The paths in the systemd unit are quoted and escaped (`%`, `$`, quotes,
control characters refused). Paths in the plist are XML-escaped.

**Upgrade.** Only the owner can upgrade the daemon. The build must have the announced size and
SHA-256, must run here and report this OS and CPU, and is then swapped in atomically.

## Residual risk (by design or not yet built)

- **The same user is fully trusted.** Every process running as the user can read
  `hook.token`, the iroh key and the grant store, and can rewrite them. That includes an agent's
  approved shell commands and anything a Driver types. The state directory protects against
  other users only. An agent tricked into editing `devices.json` or the daemon's files is
  stopped only by the agent's own permission prompt (Copilot CVE-2025-53773 class).
  Auto-approve rules live in memory and are signed per rule, so they cannot be planted on disk.
- **Driver means code execution as the host user.** A Driver guest in a shell pane can run
  `cat hook.token`, read keys, or pair a device of their own. Pane scoping limits what the
  daemon offers, not what a shell can do. Prompters reach the same through the agent, subject
  to its approvals.
- **Askpass phishing by a guest.** A Driver guest can run `un-askpass "[sudo] password:"` in a
  shared pane. The owner's app then shows a native password sheet, and the answer goes to the
  guest's process. The sheet names the program, but it cannot say who typed the command.
- **Repository scripts.** `.unnamed.json` `setup`/`teardown`/`scripts` are repository content.
  New Task runs `setup` without asking first.
- **Pushing from a hostile `.git`.** `push` keeps the repository's hooks and network config
  (`core.sshCommand`, credential helpers), because the person asked for it.
- **Global filters stay.** Filters defined in the user's global git config are left alone.
- **TOCTOU on paths.** Paths are checked, then used. A concurrent same-user process could swap
  a directory for a symlink in between. Other users cannot, unless `files.allow` names a
  directory they can write. Using `openat2(RESOLVE_BENEATH)` on Linux would close this.
- **Agents read panes.** Terminal tools read every pane in the agent's session, including text
  a guest typed or a program printed. That text can carry prompt injection.
- **Cookies on the device.** Cookies are per host, not per port. The editor's in-app data store
  is isolated per host and folder, so other local pages share no token cookie with it. The
  editor server's own Origin check is relied on for websockets.
- **No signature on upgrades.** An upgrade is trusted because the owner's device sent it. There
  is no release signature to check yet.


1. **Browser for guests.** Browser calls now reach the owner's devices only. Should a guest
   ever be able to opt in, for example for a shared `claude /login`?
2. **Askpass and guests.** Should askpass prompts be suppressed, or carry a warning, while a
   guest holds the pane's lease? Should a guest-held pane route askpass to the guest only?
3. **Repository setup scripts.** Trust-on-first-use for `.unnamed.json` commands: show the
   command and record a hash per repository before the first run. This needs a small app
   change.
4. **Headless pairing.** With a service install, the first ticket now comes only from
   `unnamed-hostd pair`; it is no longer printed into the log.
5. **Pane limit.** The limit of 32 panes per agent tree is a constant. It may need to be a
   setting for large agent fleets.
