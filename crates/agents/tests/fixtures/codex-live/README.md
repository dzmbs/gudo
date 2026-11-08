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
Daemon transport/control integration remains an enablement prerequisite.

`pane-stream-0.166.0.json` captures binding and event frames from a pane-environment app-server.
MCP was configured on that server, with an explicit `env_vars` name allowlist: default MCP subprocess
sanitization omitted pane identity and `CODEX_HOME`. The fixture MCP initialized with the expected
pane identity, token and home after allowlisting. Token values are not recorded. The user's notify
program remained configured and ran in the pane environment. These probes do not cover all Gudo
MCP tools or arbitrary user MCP configurations.

`pane-approval-0.166.0.json` captures an actual command-approval request on that topology. A loopback
model requested a throwaway `printf` with escalation. The TUI used on-request approval; the request
was held and no decision was sent. Replay tests decode its identity only. The recorded request keeps
its policy and permission fields; the decoder does not supply a policy-ready approval or claim command
execution. Both event captures include auxiliary title activity to exercise primary-thread filtering.

The event decoder is launch-owned, starts before the first turn and requires an exact current binding.
It emits bounded text deltas and typed completion outcomes without notify. Late observers still need
snapshot hydration. Signed decisions, complete permission metadata, native prompt receipts and actual
daemon lifecycle/session integration are not provided by these captures or decoder tests.

Codex protocol behavior and TUI sources are covered by the repository's Codex Apache-2.0 notices.
