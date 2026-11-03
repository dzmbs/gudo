Codex hook stdin payloads built to the JSON schemas in openai/codex
codex-rs/hooks/schema/generated/*.command.input.schema.json (main, fetched 2026-10-18). Every
required field is present. Values are invented; the tool_name for shell commands ("Bash") is an
assumption that must be checked against a running Codex.

notify_agent_turn_complete.json is the `notify` program argument (not stdin), copied from the
historical wire shape pinned in openai/codex codex-rs/hooks/src/legacy_notify.rs tests (main,
fetched 2026-11-03); the same fields are documented under `notify` in the Codex advanced
configuration docs.
