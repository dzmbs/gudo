# Claude TUI input observations

Captured 2026-11-06 from Claude Code 2.1.318 and 2.1.319 in fresh, private temporary HOME,
CLAUDE_CONFIG_DIR and working directories. Hooks and MCP servers were disabled. The API used
an asserted placeholder key and a loopback-only synthetic Messages/SSE server; no real account,
external model request or existing conversation was used. The CLI itself created its transcript.
No session files were edited or existing TUI resumed.

The viewport was 100 columns by 40 rows. Each fixture starts at the emitted bracketed-paste
mode enable immediately before entering the alternate screen; later frames are incremental
output. Machine/temp-directory identifiers were replaced with equal-byte-length strings so
cursor geometry is unchanged. Onboarding, trust and API-key confirmation screens are omitted.
`input_hex` is the exact input sent between frames. Fixtures contain no credentials.

These are functional VT observations, not a supported-draft classifier:

- **`claude-2.1.318-burst.json`**: one PTY write containing bracketed `Hello mirror.` followed
  immediately by Return reached the fake API exactly once. The same live probe also succeeded
  on 2.1.319. This small prompt does not prove all payload sizes or bindings work.
- **`claude-2.1.319-multiline.json`**: bracketed `first\nsecond`, then Ctrl-U, leaves `first` in
  the draft. The cursor's current line is visually empty, so reading that line alone is unsafe.
- **`claude-2.1.319-spaces.json`**: three spaces followed by Ctrl-A leaves the exact same cursor
  and input-region cells, including all styles and blank-cell distinctions, as a genuinely
  empty input. Even a version-tested VT layout cannot prove the underlying draft is empty.

Any constrained native composer therefore needs input-revision provenance and a trusted empty
checkpoint, in addition to layout/foreground/session checks. Raw/manual input must invalidate
that provenance immediately. A visually empty row after arbitrary editing remains unknown;
do not clear it with Ctrl-U or treat it as safe to overwrite. Unknown layouts/versions, resumed
unproven drafts, modal UI and changed revisions must retain the draft and fall back to Terminal.

The exit fence is a separate safeguard: it prevents pending native bytes from reaching the
fallback shell, not edits or submissions into a dirty agent draft. See
[`docs/security/host-local.md`](../../../../../docs/security/host-local.md).
