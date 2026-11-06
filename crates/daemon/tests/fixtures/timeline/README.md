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
