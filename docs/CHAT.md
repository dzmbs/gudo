# Agent timelines

A timeline mirrors the agent in a pane. The Claude adapter reads that process's transcript;
it never starts a second agent, restarts the TUI or writes to its session files. Prompts,
interrupts and approvals use the existing input and signed-decision paths.

## Protocol

`Caps::AGENT_TIMELINE` opts a connection into timeline pushes.
`DaemonFeatures::AGENT_TIMELINE` gates requests to the helper. Terminal-only clients receive
no timeline traffic.

- `TimelineWatch` returns the last approximately 60 items and a cursor, then
  `ServerCtl::Timeline` pushes operations. Its frozen encoding always selects schema 1.
- `TimelineWatchVersioned`, gated by `DaemonFeatures::VERSIONED_TIMELINE`, supplies the
  peer's highest readable schema. The helper selects the highest version supported by both;
  version 0 is rejected before replacing a watch. Current peers support schema 1. A newer app
  uses the frozen legacy request with helpers that do not advertise versioned watches.
- `TimelineUnwatch` releases the subscription.
- `TimelineItemsBefore` returns up to 100 older items. Its byte cursor is scoped to the
  watched pane's transcript, not a client-supplied file path.
- `TimelineToolOutput` reads output on demand, up to 256 KiB per page. Handles bind the
  transcript epoch, record offset and tool ID. Offsets must be UTF-8 boundaries and pages
  must hold at least four bytes. Rust retains a validated `OutputHandle` value and parses
  incoming opaque request strings once. Its JSON/postcard encoding remains the existing
  `epoch:record-offset:tool-id` string; assigning an epoch replaces it, never nests prefixes.

Items have stable agent IDs and revisions. Operations carry an epoch and sequence. File
replacement, truncation, a changed session or a rewritten tail produces a snapshot with a
changed epoch. A slow consumer receives a current snapshot rather than an expanding queue.
`Checkpoint` advances a scoped reader past an operation it may not see, without exposing
that operation's contents.

Wire enums are append-only and covered by golden-byte tests. Schema 1 has closed whitelists:
unsupported item bodies/origins become a local Terminal notice, future tool kinds become Other,
and unsupported patches offer Terminal rather than closing the control stream. Initial, live,
recovery and history snapshots pass through the schema adapter. Native unknown content blocks
become bounded notices before retention; their opaque payload is never used as text or actions.
Current watches all select schema 1. Adding a supported second schema requires carrying that
selection through its watch and writers, not widening schema 1's whitelist.

The Apple FFI carries timeline values as JSON strings; decoding and row preparation belong off
the main actor.

## Apple values and subscriptions

HostKit decodes the FFI's JSON into sendable timeline values. Explicit coding keys preserve
Rust's external enum tags and snake-case fields, including round trips through a device
cache. Integer cursors never pass through floating-point JSON objects. Agent, permission,
command-source, status, kind and append-field tags decode into domain-specific typed values;
future tags retain their raw string in Unknown without acquiring known behavior. Views do not
compare wire strings. An unknown append field rejects its whole batch transactionally and
offers Terminal rather than applying an unsupported patch.

A `TimelineChannel` shares one pane watch between screens on a connection. A new viewer
refreshes the snapshot for every viewer, so replacing the helper's watch cannot leave another
screen behind. Pushes arriving during that request wait behind its snapshot. The pending queue
is bounded to 64 updates and 2 MiB; overflow requests a fresh snapshot. The final viewer waits
for an in-flight watch's reply before unwatching. A viewer arriving during unwatch waits for
that request to finish. Connection generations reject late replies, and pane closure releases
the channel.

`RowBuilder` parses Markdown on its actor into independent block rows with stable IDs and
cached attributed inline text. Its cache is bounded by 500 blocks, 500 item entries and
4 MiB of estimated retained content. Only HTTP, HTTPS and mail links are interactive; HTML
stays literal text. Original block source comes from cmark's UTF-8 ranges, not a padded table
formatter. Nested tables rendered inline keep their literal source instead of expanding columns.
The upstream Markdown and cmark-gfm licences ship with the app.

Append-only revisions retain the parsed completed prefix and parse the mutable suffix from a
source-line boundary, preserving indentation, CRLF and Unicode. A partial final line retains
one extra block because cmark can temporarily separate a partial table row from its table.
Authoritative rewrites discard the partition; possible reference definitions use a source-wide
fallback. Partition state shares the bounded render-cache lifetime. The native partition adapts
Codex's incremental renderer; its Apache licence ships in the app. This prefix reuse does not
substitute for phase-2 newline gating and prose/table/fence holdback.

`TimelineModel` serializes bounded JSON batches through an off-main render worker. Its value
window checks epoch and sequence continuity, ignores stale revisions, applies batches
transactionally and reconciles authoritative snapshots without discarding older loaded pages.
Historical replies never advance the live cursor. Values are bounded by both 3,000 items and
16 MiB of conservative retained-value weight (twice UTF-8 string storage plus record/collection
allowances, not a resident-memory measurement). Incremental accounting includes tool inputs,
output tails, nested diffs, attachments, plans and actor bytes. Live following evicts older
pages at known byte boundaries; a missing history boundary requests a fresh snapshot.

`ChatModelPool` offers four retained models sharing a 16 MiB value allowance, split into
immutable 4 MiB worker grants that survive resets. Leases protect visible models from eviction;
only inactive models are replaced, with the least recently used one first. The final lease
stops its model's subscription. This bounds pooled value retention, not rendered-memory or RSS;
controllers and derived caches need their own limits.

Paging further back evicts newest values but never the controller's current reading item. A
page that cannot fit without losing that anchor is rejected transactionally with a Terminal
fallback, not retried automatically. Protected history declines over-budget growth and exposes
a jump-to-latest gap. Appends are frozen across that gap so later deltas cannot attach to an
outdated prefix; authoritative full values can still reconcile. A snapshot page that cannot
fit produces a bounded fallback instead of an endless refresh loop. If following stops while
a history-boundary refresh is in flight, an unrepairable boundary offers Terminal rather than
discarding the reading rows. The New control remains visible at the loaded bottom while that
bottom is not the live bottom. Connection resets clear rendered values before another connection can
publish, including screens that were stopped during a reconnect. Expansion and drafts stay
local to the screen; drafts do not cross hosts.

## Touch presentation

`TerminalHost` can park its long-lived terminal view outside the window hierarchy while the
backend and VT feed remain alive. Inactive containers neither take the view from an active
host nor give it their changing layout; removal stops the terminal's display link and releases
GPU resources through its existing lifecycle. Reactivation reuses the same view and backend.
The pane switch must also preserve keyboard geometry and gate pending IME composition before
parking; this container support alone is not the integrated Terminal/Chat switch.

`DaemonPaneBackend.cacheSize` stages a hidden viewport without sending a resize or claiming
ownership. Actual input or an explicit sizing claim admits it before input bytes; generated
replies and focus reports do not. Deferred candidates are excluded from automatic local-tap
handover. This API is not yet wired into the pane switch: warm-layout admission and keyboard
geometry still require integrated no-SIGWINCH acceptance.

`ChatViewController` owns one normal-orientation reusable collection and a composer host pinned
to the keyboard layout guide. A display-link coalesces pending frames; stopped views release
that clock. Inactive presentation parks it and retains only the latest pending frame. Changed-row values and order revisions keep content-only updates independent of
window length. Parent revisions detect a skipped render frame and force full reconciliation.
A render generation also invalidates cached values when two connections reuse IDs and cursors.

Visible rows use cached native fitting heights from one detached sizing host, independent of
reused cells' stale intrinsic sizes. Exact width, Dynamic Type and legibility changes invalidate
those measurements. The measurement pass yields after 3 ms and
updates prefix positions without re-hashing every row. Prepends restore the same reading row;
following updates pin to the bottom unless a newer user drag invalidates that adjustment.
The New capsule remains separate from the reusable cells.

Markdown rows use prepared attributed values. Long lists and paragraphs split into bounded
native rows. Code uses the terminal's font, foreground and background, with a 30-line/8-KiB
prepared preview and an explicit full-code action. Large user, thinking and notice text have
4-KiB UTF-8-safe previews; full values remain available for detail and copy actions. Plans and tables
also bound the number of views constructed in one cell. The Mac has no Chat presentation.

`ChatCollectionTests` exercises native reading anchors, bottom following, frozen visible rows,
coalescing, reused connection IDs, cached opening, streaming apply, two-pass memory and teardown.
The replay here uses synthetic cached rows on the Simulator; real transcript replay and device
performance verification are separate gates.

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

## Native composer safety prerequisites

The native collection is not yet an integrated Chat composer. The exit fence protects existing
composer/reviewer PTY writes from crossing into the fallback shell; it does not prove the TUI
has an empty draft or make those legacy paste/Enter pairs transactional.

Real Claude 2.1.318/2.1.319 captures in `crates/daemon/tests/fixtures/agent-input/` establish two
important limits: Ctrl-U after a multiline paste leaves an earlier line intact, and a spaces-only
draft with the cursor at Home has exactly the same input-region cells and cursor as an empty
draft. Layout, styles, blank-cell distinctions and cursor position cannot establish emptiness
by themselves. Constrained submission also needs input-revision provenance and a trusted empty
checkpoint. Manual/raw input must invalidate that proof immediately; unknown versions/layouts,
unproven resumed drafts and changed revisions retain the draft and fall back to Terminal.

The gate now belongs to `Pane`, so every non-protocol `Pane.write` advances its input revision
before enqueue and again when enqueue finishes or is cancelled. An owned guard counts writes
waiting under backpressure; native legacy writes advance the same revision under that gate.
Revision exhaustion disables native input instead of wrapping. These are input bookkeeping,
not a child-read acknowledgement: even a later Stop hook cannot prove an older raw write has
finished traversing the kernel and the TUI's own input queues. No trusted empty checkpoint or
new atomic submission API is enabled by this bookkeeping alone.

A small bracketed-paste-plus-Return packet reached the isolated loopback API exactly once on
both probed versions. That observation does not prove all bindings, payload sizes or modal
states safe. Signed approval routes and owner-only permission-mode changes remain separate.

## Scope and bounds

Every request requires View on its pane. A guest's since-join policy filters items and full
output, including reads made with a guessed handle. A transcript must resolve inside the
pane's agent account's `projects` directory and its filename must match the captured session.
Files are opened without following a final symlink. Output reads reject stale file identity
or tail anchors, even before the file watcher runs.

The daemon retains at most 512 items per watched pane and 128 tool-call merge entries.
Initial and historical reads seek within the last 8 MiB before the requested position;
only the selected records are parsed. Native record, block, result and plan tags decode into
typed values at the reader boundary; arbitrary tool input retains bounded JSON for its sheet.
Command sources and permission modes are shared proto enums with an Unknown case. They retain
the original string encoding for known values on both postcard and JSON; unrecognized metadata
becomes Unknown rather than an actionable permission mode.
Malformed complete records are skipped without ending the timeline. Text over 256 KiB becomes
a per-item Terminal notice, not a session-wide error. Live scanning is limited to 8 MiB per
refresh, including record newlines. An oversized line is discarded through its next newline;
the scan position and last complete record boundary are distinct, so an unfinished line never
publishes a false offset or repeatedly resets the epoch. Partial-tail rewrite checks cover
the scanned position as well as the completed boundary.

Snapshot item data is capped at 1 MiB. A connection
may watch four panes. Pushes occupy one mailbox slot per pane and coalesce to a snapshot
under backpressure. Watch tokens prevent a cancelled forwarder from reviving an unwatched
pane or replacing a later watch. A stopped worker is never reused, even while an old
connection still retains its Watch. Worker exit (including cancellation) marks the worker
closed before publishing Unavailable; subscribers check liveness after subscribing so they
cannot miss that exit. A re-watch opens a fresh reader with an epoch above previously observed
rewrite epochs. Transient read failures receive at most three retries, 250 ms apart, without
keeping an abandoned pane alive during backoff. Authorization and invalid-source errors are
not retried.

Bulk timeline requests have four per-connection permits. Successful snapshot and output
replies retain their permits until the control writer sends them, so a slow reader cannot
accumulate large RPC replies. Reused request IDs retain separate permits. Disconnecting
clears watches, mailboxes and reply permits; the last subscription releases its native
watcher and owned worker.

Tests cover parser entry kinds, incremental and partial records, paging a 2,000-item file,
rewrites, output paging, UTF-8, size bounds, backpressure, stale watches, and two real network
clients watching one transcript. Guest tests cover pane scope and full versus since-join
history.
