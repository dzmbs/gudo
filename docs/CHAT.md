# Agent timelines

A timeline mirrors the agent in a pane. The Claude adapter reads that process's transcript;
it never starts a second agent, restarts the TUI or writes to its session files. Prompts,
interrupts and approvals use the existing input and signed-decision paths.

## Protocol

`Caps::AGENT_TIMELINE` opts a connection into timeline pushes.
`DaemonFeatures::AGENT_TIMELINE` gates requests to the helper. Terminal-only clients receive
no timeline traffic.

- `TimelineWatch` returns the last approximately 60 items and a cursor, then
  `ServerCtl::Timeline` pushes operations.
- `TimelineUnwatch` releases the subscription.
- `TimelineItemsBefore` returns up to 100 older items. Its byte cursor is scoped to the
  watched pane's transcript, not a client-supplied file path.
- `TimelineToolOutput` reads output on demand, up to 256 KiB per page. Handles bind the
  transcript epoch, record offset and tool ID. Offsets must be UTF-8 boundaries and pages
  must hold at least four bytes.

Items have stable agent IDs and revisions. Operations carry an epoch and sequence. File
replacement, truncation, a changed session or a rewritten tail produces a snapshot with a
changed epoch. A slow consumer receives a current snapshot rather than an expanding queue.
`Checkpoint` advances a scoped reader past an operation it may not see, without exposing
that operation's contents.

Wire enums are append-only and covered by golden-byte tests. The Apple FFI carries timeline
values as JSON strings; decoding and row preparation belong off the main actor.

## Claude adapter

`crates/daemon/src/timeline/` owns discovery, parsing, paging and watches. Session IDs come
from the pane's captured agent session. Hook `transcript_path` takes precedence over the
project-directory convention. A pane can be watched before the agent writes its first
transcript.

The parser recognizes user messages, assistant text and thinking, tool calls and results,
structured edit patches, plans, title and permission metadata, turn duration and compaction.
Unknown record and content-block kinds are skipped. Invalid JSON or unsupported message
sizes yield a short Terminal fallback note, not an agent restart. Thinking signatures and
redacted data are never exposed.

Native file notifications wake an incremental byte-offset reader. Agent events and a timed
check cover session changes and missed file notifications. Blocking I/O and parsing run on
the blocking executor. Reusable tool IDs merge calls and results; complete output remains
on disk until requested. Inline output is a terminal-control-free tail of at most 4 KiB,
and inline diff previews retain at most six lines.

The fixture in `crates/daemon/tests/fixtures/timeline/` is emitted by the installed Claude
Code CLI against a loopback-only mock API with an isolated home and placeholder key. Its
README records which data is preserved. No real account is used.

## Scope and bounds

Every request requires View on its pane. A guest's since-join policy filters items and full
output, including reads made with a guessed handle. A transcript must resolve inside the
pane's agent account's `projects` directory and its filename must match the captured session.
Files are opened without following a final symlink. Output reads reject stale file identity
or tail anchors, even before the file watcher runs.

The daemon retains at most 512 items per watched pane and 128 tool-call merge entries.
Initial and historical reads seek within the last 8 MiB before the requested position;
only the selected records are parsed. Snapshot item data is capped at 1 MiB. A connection
may watch four panes. Pushes occupy one mailbox slot per pane and coalesce to a snapshot
under backpressure. Watch tokens prevent a cancelled forwarder from reviving an unwatched
pane or replacing a later watch.

Bulk timeline requests have four per-connection permits. Successful snapshot and output
replies retain their permits until the control writer sends them, so a slow reader cannot
accumulate large RPC replies. Reused request IDs retain separate permits. Disconnecting
clears watches, mailboxes and reply permits; the last subscription releases its native
watcher and owned worker.

Tests cover parser entry kinds, incremental and partial records, paging a 2,000-item file,
rewrites, output paging, UTF-8, size bounds, backpressure, stale watches, and two real network
clients watching one transcript. Guest tests cover pane scope and full versus since-join
history.
