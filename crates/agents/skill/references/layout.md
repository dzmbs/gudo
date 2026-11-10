# Layout tools

Nothing these tools open takes the user's focus; the keyboard stays where the user has it. One
agent, with every worker it started, may have 32 panes open at once.

A `frame` is fractions of the tab: `{"x": 0.55, "y": 0.05, "w": 0.4, "h": 0.5}` (x and y from
the top left, w and h at least 0.1). `closeWhenDone: true` closes a floating window 2.5 s after
its work ends: an agent's turn, a done or error status, or the first command run in it.

### `pane_split`

Opens a pane beside (`right`) or below (`down`) a pane, yours by default: a shell, a `command`,
or a coding `agent` (`claude`, `codex`). `float: true` opens it as a floating window instead.

Arguments: `of`, `direction`, `cwd`, `command`, `agent`, `focus`, `float`, `frame`,
`closeWhenDone`.

### `tab_new`

Opens a tab in this session without switching the user to it. With `float: true` the pane opens
as a floating window over your own tab instead.

Arguments: `cwd`, `command`, `title`, `focus`, `float`, `frame`, `closeWhenDone`.

### `pane_close`

Closes a pane you created, ending what runs in it. Closing a pane that is already gone succeeds.
For one of the user's panes, the user is asked first.

Arguments: `pane` (required).

### `pane_float`

Floats a pane you created as a window over its tab, or moves its window to `frame`. `pinned`
shows it over every tab. A tab keeps at least one pane in place.

Arguments: `pane` (required), `frame`, `pinned`.

### `pane_dock`

Puts a floating pane you created back into the tab's layout: where it was, or beside another
pane (`beside`, on `side`: `left`, `right`, `up`, `down`).

Arguments: `pane` (required), `beside`, `side`.

### `pane_minimize`

Sends a floating pane you created to the tab's tray, or restores it with `minimized: false`.

Arguments: `pane` (required), `minimized`.

### `pane_raise`

Brings a floating pane you created to the front and out of the tray, so the user sees it.

Arguments: `pane` (required).
