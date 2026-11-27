# Other hosts

The user may have more than one computer with {{PRODUCT}}. The terminal tools that read, open,
type, run and close (`pane_list`, `pane_read`, `pane_wait`, `pane_send`, `cmd_run`, `tab_new`,
`pane_split`, `pane_close`, `agent_spawn`, `agent_prompt`, `agent_wait`, `agent_result`) take
`host`: a host's name as the app shows it, or its id from `host_list`. Pane ids then name panes
on that host; a pane id from one host means nothing on another.

Nothing reaches another host without the user. Their {{PRODUCT}} device carries each call
there, and only for hosts they turned on for agents on this one. The first call asks them:
"Allow once" lets that call through (and your reads on that host after it); "Allow all for this
agent" lets everything you ask on that host through until you exit. Until they answer, the call
waits, up to two minutes. With no device connected it fails, and they are notified: say so and
try again later. Panes you open there are yours; the user's own panes there need their yes, as
here. A password prompt there is never typed into. `events_wait` stays on this host.

## Find and use a pane there

1. `host_list`: the host must be `enabled`.
2. `pane_list` with `host`: the tabs and panes of the session the user's device shows on that
   host (else its most recent). If the pane the user means is not listed, it is in another
   session: ask them to open that session in the app, then list again.
3. `pane_read` with `host` and `pane` reads it; for an agent there, `agent_result` gives its
   last answer.
4. `pane_send` or `agent_prompt` with `host` types into it, and `agent_wait` waits for the reply.

Never ask the user for a pane id before trying `pane_list` with `host`.

### `host_list`

The user's other hosts and where each stands: `enabled` (you may ask), `off` (they have not
turned it on for agents here), `offline`, `guest` (someone else's host, never reachable),
`no_helper` (reached over plain SSH: the helper must be installed first) or `old_helper`. Each
has a `note` saying what to do when it is not `enabled`.

Arguments: none.
