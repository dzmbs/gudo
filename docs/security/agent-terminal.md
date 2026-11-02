# Agents driving the terminal

Coding agents (and scripts) in a pane can drive other panes through the terminal tools: MCP via
`gudo-hook mcp`, `gudo-hook term`, the TypeScript client, all on the hook socket
(docs/DAEMON.md, "Terminal tools", "Scripting"). An agent is a program that reads untrusted
text (repos, web pages, tool output) and can be talked into anything, so the tools treat it as
a capable but untrusted user of the user's own account.

## Assets

- **The user's shells.** Text typed into a user's pane runs as the user, often with credentials,
  SSH sessions, cloud CLIs and production access already open.
- **Secrets typed at prompts.** Passwords and passphrases a program asks for in a pane.
- **The user's attention and focus.** What is on screen, and the approval cards they trust.
- **The audit trail.** Who allowed which action.

## Attackers

- A prompt-injected or misbehaving agent in one of the user's panes (the main one).
- Another local program of the same user pretending to be a pane (it can read files the user
  can, but not other panes' tokens unless it runs in them).
- A multiplayer guest, including one with the Approver role.
- Someone with a stolen lock-screen notification, or replaying an old answer.

Out of scope: another local process running as the same user with full access to the state
directory (it holds `hook.token` and can do anything the user can anyway).

## What we defend, and how

- **Identity.** Each pane's helpers get a token that speaks for that pane only (an HMAC of its
  id); the socket refuses other uids before reading. An agent acts as its own pane, never as
  another.
- **Own panes only, without asking.** An agent types into, runs in and closes the panes it (or
  its workers) opened; never its own pane (it would type into its own prompt), never another
  session's. Ownership survives a restart (`layout.json`) and is dropped with the pane, so an id
  cannot leave a stale claim behind.
- **The user's panes need the owner's yes, for one exact action.** A request carries the exact
  text, keys, command line or prompt, shown with every control, line-break and bidi character
  made visible. The owner's signed answer releases only the waiting call, which does exactly
  that; a replayed answer, a second device, or a different action finds nothing to approve.
  "For this pane" is the one wider answer, named as such, never what Approve picks on old apps,
  and it ends when either pane closes or the daemon restarts.
- **Only the owner answers.** Guests never get the request and their `Decide` is refused and
  audited, whatever roles they hold; approval policies cannot delegate it.
- **Lock screen.** Approve there is "Allow once" only, needs Face ID or the passcode, uses a
  token bound to the device, the pane and the request's content, valid 15 minutes. An action too
  long to show whole is pushed without Approve.
- **Passwords are the user's.** Input is refused at a password prompt before asking and again
  right before typing, whatever was allowed.
- **No focus stealing.** Panes and tabs an agent opens never take focus.
- **Bounded.** Requests lapse after two minutes; a caller that hangs up withdraws its request;
  one agent tree may have 32 panes open.
- **Audit.** Every answer (allow once, for this pane, deny) is a signed `Approval` record in
  the hash-chained audit log.
- **Event stream.** Agents see only their own session's events; `gudo events` sees what its
  connection's grant shows. Neither leaks another session's panes, commands or exit codes.

## Residual risk

- **The owner approves something harmful.** The card shows exactly what will be typed, but a
  long command or a clever one can still fool a person in a hurry. "For this pane" hands the
  agent that shell until it closes: anything it types afterwards is not shown first.
- **What a command does is not what it says.** Approving `make deploy` approves whatever the
  Makefile does now.
- **Raw-mode password prompts** (most TUIs, `pinentry-curses`) are not detected as secret
  prompts; a "for this pane" grant could type into them.
- **Events reveal timing.** An agent in a session learns when the user's commands start and
  finish, and their exit codes (it could already read the panes).
- **Same-user processes.** Anything that can read the state directory can speak for any pane.


- Requests wait 120 s; a shorter wait is safer for unattended agents, a longer one kinder on a
  phone in a pocket.
- "For this pane" grants are memory only: a daemon restart ends them (safest default).
- Approval policies (two-person, claims) do not apply to drive requests: only the owner answers.
