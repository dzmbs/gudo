# Three workers in parallel, then collect

The user asks to add input validation to three independent API handlers. Each handler is its own
file, the work does not overlap, and the tests run per handler: a good fit for three workers.

Give each worker its own worktree so their edits cannot collide:

```sh
git worktree add ../api-users -b validate-users
git worktree add ../api-orders -b validate-orders
git worktree add ../api-billing -b validate-billing
```

`cwd` takes an absolute path; here the repository is `/work/api`.

Then, one call per line:

```text
status_set {"state": "working", "message": "Three workers adding validation", "progress": 0}
agent_spawn {"kind": "claude", "cwd": "/work/api-users", "prompt": "Add input validation to src/handlers/users.ts using the zod schemas in src/schemas. Change only that file and its test. Run `npm test -- users` until it passes. Do not commit or push. End with a short summary: what you validated, the files you changed, the test result."}
agent_spawn {"kind": "codex", "cwd": "/work/api-orders", "prompt": "…the same for orders.ts…"}
agent_spawn {"kind": "claude", "cwd": "/work/api-billing", "prompt": "…the same for billing.ts…"}
agent_wait {"panes": ["p14", "p15", "p16"], "all": true, "until": ["idle", "done", "blocked", "error", "exited"], "timeoutMs": 240000}
```

The pane ids come from each `agent_spawn` result. `agent_wait` returns each worker's state. On `timeout`, call it again; the workers go on. A
worker in `blocked` is waiting on the user: leave it, and say which pane needs them.

For each worker that finished:

```text
agent_result {"pane": "p14"}
cmd_run {"command": "git -C ../api-users diff --stat && npm --prefix ../api-users test -- users"}
```

Check what each one claims before trusting it, then merge the branches yourself, read the
combined diff, and run the whole suite once. Finish:

```text
pane_close {"pane": "p14"}
pane_close {"pane": "p15"}
pane_close {"pane": "p16"}
status_set {"state": "done", "message": "Validation added to users, orders and billing"}
```

Remove the worktrees once their branches are merged (`git worktree remove ../api-users`).
