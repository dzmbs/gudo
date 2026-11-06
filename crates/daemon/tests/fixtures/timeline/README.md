# Timeline fixtures

`claude-2.1.318.jsonl` is emitted by Claude Code 2.1.318 against a loopback-only mock
Anthropic API. The CLI runs with an empty temporary home, disabled hooks and MCP, and a
placeholder key. No sign-in, real account or external service is involved. The mock asks
for a Bash command, Write, Edit and Read, then returns Markdown. Thinking is mock text,
not a model's private reasoning.

The fixture contains the CLI's user and assistant records. Other records are excluded.
Working directories and file paths are replaced with `/fixture/project`. UUIDs, usage,
content block boundaries and tool result shapes are preserved. The collection uses print
mode to avoid onboarding; the Chat implementation must only mirror the terminal's process.

The parser tests construct additional cases for title and permission metadata, plans,
Task results, compaction, errors, unknown entries, bounded previews and invalid JSON.

`codex-0.166.0.json` records two independent WebSocket clients connected to one Codex
0.166.0 app-server over a private Unix socket. The server uses an empty temporary home and
CODEX_HOME, a placeholder key and a loopback-only mock Responses API. One client starts a
turn; the other attaches with `thread/resume` while that turn is running. Both receive the
same message deltas and completion, and `thread/read` returns one turn for both clients.
An empty thread has no persisted rollout yet: attaching before its first turn returns
`no rollout found`; attaching after the first request reaches the mock API succeeds.
No replacement process or concurrent agent session is involved. The server is terminated
after collection. Host names and temporary paths are sanitized; protocol IDs and payload
shapes are preserved.
