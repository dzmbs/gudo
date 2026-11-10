# One agent reviews another's diff

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
