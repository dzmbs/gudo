# Worker agents

A worker is a coding agent you start in a pane of its own. The user watches it in the app and
can type into it. Its states: `starting`, `idle`, `working`, `done`, `blocked` (waiting on the
user: a permission, a question, a sign-in), `error`, `exited`. `turns` counts the turns it has
finished.

Write a worker's prompt so it stands alone. It does not see your conversation. Give it:

- the goal, in one or two sentences;
- where to work (`cwd`, a worktree or branch) and which files are its own;
- the limits (do not push, do not touch other folders, run these tests);
- what done looks like, and what the final message should hold (a short summary, the files it
  changed, the commands it ran and their results).

### `agent_spawn`

Starts `claude` or `codex` in a new pane beside yours (or a floating window), and gives it
`prompt` once it is ready. `timeoutMs` is how long to wait for it to be ready (60 s by default).
A worker stopped on a dialog at start (folder trust, an approval) comes back `blocked`: that is
the user's to answer.

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
(`completed`, `cancelled`, `failed`), its final message, and its transcript file. It still
answers after a `closeWhenDone` window closed.

Arguments: `pane` (required).

## Also useful

- `events_wait` with `types: ["agent.state"]` follows many workers at once
  (`references/terminal.md`).
- `status_set` shows your own progress on your pane while workers run.
- `pane_wait` with `status: ["blocked", "done"]` waits on any program that reports a status.
- `pane_close` ends a worker you no longer need.
