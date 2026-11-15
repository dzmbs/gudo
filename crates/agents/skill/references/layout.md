# Layout tools

Nothing these tools open takes the user's focus; the keyboard stays where the user has it, and
every tab keeps its focused pane. You may have 32 panes you opened yourself open at once, and the
agents of this session 128 together; `whoami` shows both counts under `limits.panes`.

Every result has `effects`: each pane whose tab, floating window, frame or focus the call
changed, as `{pane, changes, was, now}`. `changes` lists `opened`, `closed`, `tab`, `float`,
`frame` or `focus`; `was` and `now` say where the pane was and is (`tab`, `floating`, `frame`,
`minimized`, `pinned`, `focused`). Check it instead of listing panes again.

A `frame` is fractions of the tab: `{"x": 0.55, "y": 0.05, "w": 0.4, "h": 0.5}` (x and y from
the top left, w and h at least 0.1). `closeWhenDone: true` closes a floating window 2.5 s after
its work ends: an agent's turn, a done or error status, or the first command run in it.

### `pane_split`

Opens a pane beside (`right`) or below (`down`) a pane, yours by default: a shell, a `command`,
or a coding `agent` (`claude`, `codex`). `float: true` opens it as a floating window instead.

Arguments: `of`, `direction`, `cwd`, `command`, `agent`, `focus`, `float`, `frame`,
`closeWhenDone`.

### `tab_new`

Opens a tab in this session without switching the user to it. `title` is the tab's fixed title:
programs in it cannot change it. With `float: true` the pane opens as a floating window over your
own tab instead.

Arguments: `cwd`, `command`, `title`, `focus`, `float`, `frame`, `closeWhenDone`.

### `pane_close`

Closes a pane you created, ending what runs in it. Closing a pane that is already gone succeeds
(`alreadyClosed`); an id that never existed is `not_found`. For one of the user's panes, the user
is asked first. A tab's last pane in place is not closed while windows float over the tab, since
one would drop into its place: dock or close them first, or pass `closeFloats: true` to close
them too (only when they are all yours).

Arguments: `pane` (required), `closeFloats`.

### `pane_float`

Floats a pane you created as a window over its tab, or moves its window to `frame`. `pinned`
shows it over every tab. A pane floated again gets back the frame and pin it had when it docked.
A tab keeps at least one pane in place.

Arguments: `pane` (required), `frame`, `pinned`.

### `pane_dock`

Puts a floating pane you created back into the tab's layout: where it was, or beside another
pane (`beside`, on `side`: `left`, `right`, `up`, `down`). Beside a pane in another tab it is
refused with `cross_tab`, which names both tabs; pass `moveTab: true` to move the pane there, and
the result's `moved` says from which tab to which.

Arguments: `pane` (required), `beside`, `side`, `moveTab`.

### `pane_minimize`

Sends a floating pane you created to the tab's tray, or restores it with `minimized: false`.

Arguments: `pane` (required), `minimized`.

### `pane_raise`

Brings a floating pane you created to the front and out of the tray, so the user sees it.

Arguments: `pane` (required).
