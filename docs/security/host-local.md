# Host-local surfaces

What the daemon exposes on the host itself: the hook socket and its callers (agent hooks,
askpass, the app's browser, the MCP server, terminal tools), files and git, port forwarding,
the editor servers, the state directory, logs, the service and self-upgrade, and the `gudo` CLI.

## Assets

- **The state directory** (`~/Library/Application Support/gudo`, `~/.local/state/gudo`):
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
4. **A hostile repository.** A `.git` directory or `.gudo.json` from an unpacked archive or a
   clone.
5. **A multiplayer guest** with Viewer, Prompter, Driver or Approver on some scope.

## What we defend, and how

**Hook socket.** The socket is mode 0600. It lives in the 0700 state directory or, when that
path is too long for `sun_path`, in a new 0700 directory with a random name under the
temporary directory, never a predictable `/tmp` name. Every connection is checked with
`SO_PEERCRED`/`getpeereid`. A peer whose uid differs from ours, or whose uid cannot be read, is
dropped before a byte is read. Every call carries a token checked in constant time.

**Tokens.** A pane's environment holds only its own token (`GUDO_TOKEN`), never `hook.token`. The
MCP server uses the pane's own token whenever its environment, or the agent's, belongs to the
pane it serves. It reads `hook.token` only as a fallback, and never takes it from argv.

What a pane token unlocks: hook events for that pane, askpass prompts for that pane, the
browser calls described next, the session's drawings, and the terminal tools. The terminal
tools read the session's panes and type into or close only panes the caller opened.

**Browser.** URLs and browser tools go only to the owner's devices, never a guest's. A guest's
browser holds the guest's own sign-ins, which the host's programs must not drive or read. When
no app takes a URL, the system opener gets `http(s)` URLs only. `open`/`xdg-open` would also
launch apps and run `file://…/x.command` (compare mcp-remote CVE-2025-6514).

Browser tool calls are refused while a guest holds the pane's lease. Anything the guest types
can use the pane's token, and the tools drive the owner's signed-in browser.

**Password prompts (askpass).** Prompts go to the owner's devices only, never a guest's: a
host that is not the guest's own must not ask for the guest's passwords. The daemon checks
this when it pushes a prompt, when it counts who could answer, and when an answer or cancel
arrives. The client also never offers the capability on a guest connection, and drops prompts
a host sends there anyway. While a guest holds the pane's lease, the owner's sheet says "Asked
while bob is driving", and the saved password is not offered with one tap: the guest may have
typed the command that asks.

**Repository commands.** A repository's `.gudo.json` `setup` and `teardown` run only once
the owner trusts them, like VS Code's workspace trust or `direnv allow`. Trust is kept per
repository (its main worktree) and SHA-256 of both commands, in `<state>/repo-trust.json`. New
or changed commands do not run. The app first asks "Run Setup Commands for repo?" (or
Teardown, before archive or delete) and lists every command. Declining opens the task, or
archives the worktree, without them. A new task asks about the file committed at its base,
which is the file the new worktree gets. Only an owner device can trust: a guest, even one
holding the owner role, is refused, and the commands do not run for it. Daemon-run teardowns
(auto-delete of merged worktrees) follow the same rule.

**Terminal tools.** The pane ids in calls are typed integers, and no shell is built from tool
arguments: `cmd_run` types into a pane the agent owns, which is its purpose. One agent,
together with every worker it starts, may have at most 32 panes open. A wait holds at most
1 MiB of output, and results are capped at 256 KiB.

**Files and git.** Path policy (DAEMON.md §5.0): paths must be absolute, with no `..`, and their
real path must lie inside `$HOME` or `files.allow`. Symlinks are checked through their real
targets.

- **State directory.** It is refused even inside a root, so a host-scope Driver cannot silently
  read keys or rewrite the grant store through the Files API. That holds for any spelling of
  it (case on macOS), through symlinks, and for moving or deleting a directory that holds it,
  which would otherwise carry it to an unrefused name or into the trash.
- **File modes.** Writes never get setuid, setgid or sticky bits from a client.
- **Daemon-run git.** Every call disables the following (the Zed CVE-2026-44465 class):
  - `core.fsmonitor`
  - automatic gc and maintenance
  - the pager and editor
  - hooks (except a user-initiated `push`)
  - the repository's own clean, smudge and process filters (LFS's own excepted), wherever
    they are defined: `.git/config`, files it includes (`include`, `includeIf`) and the
    worktree's `config.worktree`
  - filters of nested repositories and submodules: status and diff do not look inside them
    (`--ignore-submodules=dirty`), and a worktree snapshot records them at their HEAD instead
    of letting `git add` run `git status` inside them

  Porcelain diffs pass `--no-ext-diff --no-textconv`. Branch and base names that start with `-`
  are refused, and paths come after `--`. `gh` gets the same config through `GIT_CONFIG_*`,
  filters included. The throwaway index lives in a private temporary directory.

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
- `gudo` keeps its device key, tickets and invites as 0600 files in a 0700 directory.

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
- **Askpass phishing by a guest.** A Driver guest can run `gudo-askpass "[sudo] password:"` in a
  shared pane. The owner's sheet now says the guest is driving, and offers no one-tap saved
  password, but the owner can still type one. A guest who released the lease or left before
  the program asked (a delayed `sleep 60; sudo …`) is not named.
- **Repository scripts.** The `scripts` menu entries of `.gudo.json` run only when the user
  picks one, without a trust prompt. The menu shows the script's name, which need not match its
  command.
- **Trust is the same user's file.** `repo-trust.json` is in the state directory: a process
  running as the user can add a hash to it.
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

## Decisions

Made:

- **Browser for guests.** Browser calls reach the owner's devices only, with no opt-in, and
  tool calls are refused while a guest holds the pane's lease.
- **Askpass and guests.** Prompts never reach a guest's device. While a guest holds the lease
  the owner's prompt names them.
- **Repository commands.** Trust-on-first-use for `setup` and `teardown`, per repository and
  hash, granted from the app by the owner only.
- **Pane limit.** 32 panes per agent tree stays a constant.

Open:

1. **Headless pairing.** With a service install, the first ticket now comes only from
   `gudo-hostd pair`; it is no longer printed into the log.

## Validation

Each test runs the attack against the real code (real git, real sockets, a real daemon in
`tests/it`), and each was checked to fail with its fix removed.

- `ws::git::tests::a_repositorys_own_config_runs_nothing`: fsmonitor, filters and hooks in
  `.git/config` during status and a worktree snapshot.
- `ws::git::tests::config_from_elsewhere_runs_nothing`: filters from an `include`, an
  `includeIf`, `config.worktree` and a nested repository's own config, plus `gpg.program`,
  through status, the repository list's diff, a worktree snapshot, `commit-tree`, diffs with
  hunks and `worktree add`.
- `ws::gh::tests::the_git_gh_runs_is_guarded_too`: a stand-in `gh` running `git status` and
  `git checkout` in a hostile repository.
- `ws::paths::tests::the_state_dir_is_never_served`, `…_is_refused_in_any_case`,
  `what_holds_the_state_dir_is_not_moved`, and
  `workspace::the_state_dir_stays_out_of_reach_inside_an_allowed_root` (it): reads, listings
  and writes by path, `.`, `//`, symlink and other case; renaming or deleting its parents;
  a Unix forward to the hook socket.
- `ws::files::tests::a_client_cannot_create_setuid_files`. On macOS the kernel already drops
  setuid on create, so this test can only fail on Linux.
- `ws::editor_proxy::http_tests::refuses_hosts_that_are_not_loopback` and
  `ws::editor_proxy::tests::only_loopback_names_pass_the_host_check`: `localhost.evil.com`,
  `127.0.0.1.nip.io`, trailing dots, IPv4-mapped IPv6, decimal and hex IPs, userinfo tricks.
- `term::a_panes_environment_reaches_only_that_pane` (it): a pane's environment holds no
  `hook.token`; its own token cannot speak for the pane that opened it on the pull or browser
  channels; the agent tree stops at 32 panes, workers included.
- `term::an_agent_runs_waits_reads_and_stays_in_its_lane` (it): term tools with another
  pane's token, and driving a pane the caller did not open.
- `browser::a_driving_guest_never_gets_the_hosts_browser_calls` (it): browser calls never
  reach a guest's device, and once the guest types in the pane, a tool call is refused.
- `askpass::guests_never_see_prompts_and_the_owner_is_told_who_drives` (it): a viewer and a
  driver guest whose clients offer to answer anyway get no prompt, and their answers and
  cancels are refused. Once the driver types, the owner's prompt names them. The client side:
  `client-core askpass::tests` (pushes on a connection that did not offer are dropped, guests
  never offer), `apple-ffi askpass::tests`, `AppTests/SecretEntryTests`
  `testAPromptAskedWhileAGuestDrivesSaysSoAndOffersNoSavedPassword`.
- `repos::repository_commands_run_only_once_the_owner_trusts_them` (it): untrusted setup and
  teardown do not run (task and archive go ahead), a guest with the owner role cannot trust,
  trusted commands run, and changed committed commands are untrusted again.
  `ws::trust::tests::only_the_trusted_commands_of_that_repository_run`: per repository, per
  command, kept across restarts.
- `agent::tests::only_this_user_may_use_the_hook_socket`: the peer-uid check, unit level (a
  second uid is not available to the tests); `a_long_state_dir_puts_the_socket_in_a_private_dir`.
- `pty foreground::tests::a_terminal_with_no_program_has_no_foreground`: macOS reports a
  foreground group of 0 once a pane's program exits. `rustix` turned that into an invalid pid
  (a panic in debug builds, undefined behaviour in release), which a pane could trigger.
