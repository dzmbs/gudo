# Terminal tools

Panes are named `p12`, tabs `t3`. A tool given no pane works on your own pane. Waits default to
30 s and stop at 240 s with status `timeout`, which is not an error: the work goes on. Output is
the text as a person sees it (colors removed, progress lines settled), with the middle left out
when it is long; `maxBytes` raises the cap (16 KiB by default).

### `whoami`

Your own pane: its id, folder, session and host, and the limits of these tools.

Arguments: none.

### `pane_list`

The panes of this session (or only this tab): folder, whether a shell waits at its prompt, the
running program, the last command and its exit code, `createdByYou`, and `scopes`: `read`,
`input` and `manage` where you may act, `ask` where the user must agree first. `scope` is
`session` (the default) or `tab`.

Arguments: `scope`.

### `cmd_run`

Runs a shell command in a pane and waits for it: exit code, the command's own output, a cursor.
Without `pane` it opens a pane below yours and keeps it: pass its id for later commands. In a
pane the user opened, the user is asked first. A shell without integration reports `unknown`
instead of an exit code.

Arguments: `command` (required), `pane`, `cwd`, `timeoutMs`, `maxBytes`.

### `pane_read`

Reads a pane: the last lines (`tail`, 80 by default), only what came after a cursor (`since`),
one command's output (`command`: an id or `"last"`), or the visible screen of a full-screen
program with its cursor and highlighted items (`screen: true`). `grep` keeps matching lines,
`context` lines around each.

Arguments: `pane`, `since`, `command`, `screen`, `tail`, `grep`, `context`, `maxBytes`.

### `pane_wait`

Waits until a pane prints a line matching `match` (the line and its groups come back), its shell
is back at the prompt (`prompt`), it is quiet for `quietMs`, a command exits (`exit`), or its
program reports one of `status` (an agent blocked or done). Only output after `since` (default:
now) counts. With `screen: true` the regex is matched against the visible screen; `gone: true`
waits until it is no longer shown (a spinner, a dialog).

Arguments: `pane`, `match`, `screen`, `gone`, `since`, `prompt`, `quietMs`, `exit`, `status`,
`timeoutMs`, `maxBytes`.

### `pane_send`

Types into a pane you created: `text` (pasted as one piece), named `keys` (`enter`, `esc`,
`tab`, `up`, `ctrl+c`, `shift+tab`, `f5`), and `submit` to press Enter after. For answering a
program's prompt or driving a full-screen program; to run a command use `cmd_run`. Refused at a
password prompt.

Arguments: `pane` (required), `text`, `keys`, `submit`.

### `status_set`

Reports what you are doing on your own pane, as the user and other agents see it.

Arguments: `state` (required), `kind`, `message`, `progress`.

`state` is `working`, `blocked`, `done`, `error`, `idle` or `clear`; `kind` (for `blocked`) is
`permission`, `question` or `auth`; `progress` is 0 to 100.

### `events_wait`

Waits for what happens in this session instead of polling: `pane.opened`, `pane.closed`,
`command.started`, `command.finished` (with exit codes), `agent.state`, `layout.changed`. Pass
the returned `cursor` as `since` to read on; `events.lost` says some were missed.

Arguments: `since`, `types`, `max`, `timeoutMs`.
