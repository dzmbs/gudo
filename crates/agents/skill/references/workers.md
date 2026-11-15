# Worker agents

A worker is a coding agent you start in a pane of its own. The user watches it in the app and
can type into it. Its states: `starting`, `idle`, `working`, `done`, `blocked` (waiting on the
user: a permission, a question, a sign-in), `error`, `exited`. It is `working` until it ends
its turn itself, and `turns` counts the turns it has finished. A blocked worker's `status` says
what it waits on: `kind` (`permission`, `question`, `auth`, `trust`, `update`, ...) and
`message` (the command to approve, or the dialog on its screen).

Write a worker's prompt so it stands alone. It does not see your conversation. Give it:

- the goal, in one or two sentences;
- where to work (`cwd`, a worktree or branch) and which files are its own;
- the limits (do not push, do not touch other folders, run these tests);
- what done looks like, and what the final message should hold (a short summary, the files it
  changed, the commands it ran and their results).

### `agent_spawn`

Starts `claude` or `codex` in a new pane beside yours (or a floating window), and gives it
`prompt` once it is really ready. `promptDelivery` says where the prompt is: `accepted` (typed),
`queued` or `failed`. A worker stopped on a dialog at start (folder trust, an update) comes back
`blocked` with the prompt `queued`: the user answers it, and the prompt is typed then. A worker
that exits instead (Codex updating itself) and is not run again comes back `failed` with
`promptFailure` saying what happened; start a new one. `timeoutMs` is how long to wait for the
prompt to be typed (60 s by default); after that it stays queued.

Arguments: `kind` (required), `prompt`, `cwd`, `of`, `direction`, `timeoutMs`, `float`, `frame`,
`closeWhenDone`.

### `agent_prompt`

Sends a prompt to a worker you started once it is idle. `wait: true` waits for that turn to end
and returns its answer (`status` `finished`, `blocked`, `exited` or `timeout`). Refused while the
worker works or waits on the user.

Arguments: `pane` (required), `text` (required), `wait`, `timeoutMs`.

### `agent_wait`

Waits until workers reach a state: by default until any of them is idle, done, blocked, failed
or exited; `all: true` waits for every one; `until` names the states. Returns each worker's
state.

Arguments: `panes` (required), `until`, `all`, `timeoutMs`.

### `agent_result`

A worker's last answer from the agent itself rather than its screen: how its last turn ended
(`completed`, `cancelled`, `failed`), its final message, and its transcript file. Without a
message, `messageUnavailable` says why. It still answers after the worker's pane closed (a
`closeWhenDone` window, or `pane_close`); a worker closed mid-turn reports `cancelled` with
`reason: pane_closed`.

Arguments: `pane` (required).

## Also useful

- `events_wait` with `types: ["agent.state"]` follows many workers at once
  (`references/terminal.md`).
- `status_set` shows your own progress on your pane while workers run.
- `pane_wait` with `status: ["blocked", "done"]` waits on any program that reports a status.
- `pane_close` ends a worker you no longer need.
