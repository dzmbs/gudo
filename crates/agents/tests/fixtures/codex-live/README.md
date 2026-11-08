# Physical Codex TUI correlation

`physical-tui-0.166.0.json` contains selected official request/reply pairs from Codex CLI 0.166.0
connected through a temporary private Unix relay to an isolated app-server. Paths use `/fixture`;
credentials were placeholders and the model API was a loopback fixture. Requests and replies retain
their generated RPC and thread IDs. No user account, project, host name or credentials are recorded.

The first pair starts the visible user thread. The second starts an ephemeral `thread_title` helper
on the same physical TUI connection after a user prompt. The helper is not a selected conversation.
The correlation test must retain the exact user binding across both helper frames, not follow every
`thread/start` response. Unknown purpose combinations close native observation; Terminal forwarding
must remain independent of observation errors.

The capture is a subset, not a complete transport replay or proof of native input authorization.
The isolated run entered one primary prompt through the TUI and attached a second observer during
that turn. Both clients received primary completion. The TUI's own auxiliary title turn is separate
from that primary prompt, not a native bootstrap turn.

The probe also observed an empty per-thread config override map despite a TUI notify override.
Account-default notify ran from the server environment for both primary and helper completions.
Per-pane notify/MCP parity and daemon transport/control integration remain enablement prerequisites.
Codex protocol behavior and TUI sources are covered by the repository's Codex Apache-2.0 notices.
