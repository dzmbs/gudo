# Other hosts

The user may have more than one computer with {{PRODUCT}}. The terminal tools that read, open,
type, run and close (`pane_list`, `pane_read`, `pane_wait`, `pane_send`, `cmd_run`, `tab_new`,
`pane_split`, `pane_close`, `agent_spawn`, `agent_prompt`, `agent_wait`, `agent_result`) take
`host`: a host's name as the app shows it, or its id from `host_list`. Pane ids then name panes
on that host.

Nothing reaches another host without the user. Their {{PRODUCT}} device carries each call
there, and only for hosts they turned on for agents on this one. The first call asks them:
"Allow once" lets that call through (and your reads on that host after it); "Allow all for this
agent" lets everything you ask on that host through until your pane closes. Until they answer,
the call waits, up to two minutes. With no device connected it fails, and they are notified:
say so and try again later. Panes you open there are yours; a password prompt there is never
typed into. `events_wait` stays on this host.

### `host_list`

The user's other hosts and where each stands: `enabled` (you may ask), `off` (they have not
turned it on for agents here), `offline`, `guest` (someone else's host, never reachable),
`no_helper` (reached over plain SSH: the helper must be installed first) or `old_helper`. Each
has a `note` saying what to do when it is not `enabled`.

Arguments: none.
