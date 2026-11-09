# Claude Code hook fixtures

`message_display_2.1.319.json` records an interactive Claude Code 2.1.319 run with a private home,
placeholder credentials and a loopback Messages API. IDs and paths are replaced with fixture
values. The HTTP handler sent `{}` before recording the payload. The model stream paused after
the first completed line until that batch reached the handler.

The capture establishes these protocol details:

- `index` counts batches within a display message, not API content blocks.
- `final` can carry an unfinished last line or an empty delta.
- `Stop` can arrive before the final display batch.
- The display message ID is not the transcript record UUID or the API message ID.
- A shared `prompt_id` connects `UserPromptSubmit`, display batches and `Stop`.

Additional isolated runs covered a newline-terminated tail, two API text blocks, and an actual
read of a fixture file followed by a second model response. Two API text blocks share one display
message while occupying separate transcript records. The read round trip keeps one display turn
ID and starts a second display message with its batch index reset to zero. HTTP bearer header
environment interpolation was verified with `allowedEnvVars`.

The parser and reassembly are display-only. They do not authenticate a pane, authorize input or
approvals, establish original creation time, or confirm tool execution. The daemon must admit the
current pane/session/prompt and recorded paths separately, then reconcile against the transcript.

The version threshold is 2.1.69. Older-version fallback and end-to-end daemon streaming are not
established by these captures; real CLI evidence here is limited to 2.1.319.
