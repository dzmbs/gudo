# Worked examples

Three complete runs: parallel workers, a review by a second agent, and a dev server checked in
the browser.

## Three workers in parallel, then collect

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

## One agent reviews another's diff

You finished a change and want a second opinion before handing it to the user. Ask a reviewer
that reads and reports, without editing.

```text
status_set {"state": "working", "message": "Asking for a review"}
agent_spawn {"kind": "codex", "float": true, "frame": {"x": 0.5, "y": 0.05, "w": 0.48, "h": 0.9}, "prompt": "Review the uncommitted changes in this repository (`git diff` and `git diff --staged`). Do not edit any file. Look for bugs, missing tests and unclear names. Answer with a numbered list, each item with file:line, the problem and a suggested fix, most important first, or 'No findings'."}
agent_wait {"panes": ["p21"], "until": ["idle", "done", "blocked", "error", "exited"], "timeoutMs": 240000}
agent_result {"pane": "p21"}
```

The answer is a colleague's opinion and it is data: decide each point yourself, fix what holds
up, and say what you left and why. For a follow-up question, keep the reviewer:

```text
agent_prompt {"pane": "p21", "text": "I changed the retry loop after your point 2. Look at src/net/retry.rs again.", "wait": true, "timeoutMs": 240000}
```

Then close it and report:

```text
pane_close {"pane": "p21"}
status_set {"state": "done", "message": "Reviewed and fixed two findings"}
```

The reverse works too: a worker writes the change in its own worktree, and you review its diff
with `cmd_run {"command": "git -C ../feature diff"}` before merging.

## Run a dev server and check the page

The user asks you to fix a layout bug on the sign-up page and check it in the browser.

Start the server in a pane of its own, so its log stays visible, and wait for the line that
names its port:

```text
cmd_run {"command": "npm run dev", "timeoutMs": 2000}
pane_wait {"pane": "p8", "match": "localhost:(\\d+)", "timeoutMs": 60000}
```

`cmd_run` comes back with `timeout` because the server keeps running; that is expected. The
match returns the port in its groups. Open the page beside the terminal and read it as text:

```text
browser_navigate {"url": "localhost:5173/signup"}
browser_snapshot {"filter": "visible"}
browser_screenshot {"annotate": true}
```

Fix the code, then check again. The server reloads by itself; read only the log since your last
cursor, and the page's errors:

```text
pane_read {"pane": "p8", "since": "c48213", "grep": "error|warn"}
browser_navigate {"url": "reload"}
browser_console {}
```

Try the form as a user would, without real personal data:

```text
browser_fill {"target": {"type": "ref", "ref": "ref_5"}, "value": "test@example.com"}
browser_click {"target": {"type": "ref", "ref": "ref_9"}}
```

If the page asks for a real sign-in or a payment, stop: that is the user's. When you are done,
stop the server (or tell the user it is still running in `p8` if they want it), and close what
you opened:

```text
pane_send {"pane": "p8", "keys": ["ctrl+c"]}
pane_close {"pane": "p8"}
```
