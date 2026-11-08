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
- `TimelineItemsBefore` requests up to 100 older items. A page always includes whole native
  records, so its soft requested count can expand to at most 512 sibling items within the
  byte allowance. Its byte cursor is scoped to the watched pane's transcript, not a
  client-supplied file path.
- `TimelineToolOutput` reads output on demand, up to 256 KiB per page. Handles bind the
  transcript epoch, record offset and tool ID. Offsets must be UTF-8 boundaries and pages
  must hold at least four bytes. Rust retains a validated `OutputHandle` value and parses
  incoming opaque request strings once. Its JSON/postcard encoding remains the existing
  `epoch:record-offset:tool-id` string; assigning an epoch replaces it, never nests prefixes.
- `TimelineToolDiff` reads complete recorded changes from that same result handle, not the
  working tree or a numeric repository capture. It requires `DaemonFeatures::TIMELINE_TOOL_DIFF`;
  clients construct no request without both this feature and the timeline feature. Request67,
  response37 and feature28 append to the protocol; legacy golden bytes and schema 1 stay unchanged.
  View on the watched pane, session identity, since-join, file rewrite and epoch checks apply.
  Rich metadata must belong to exactly one matching tool result. The whole selection is rejected
  when unavailable, ambiguous, malformed or over its 1 MiB value allowance, 512 hunks, 20,000 lines
  or 8 KiB per UTF8 line. It never returns another truncated preview as a complete result.
  These charges are not an allocator/RSS bound. The four actual-write reply permits also cover it.

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
4 MiB of estimated retained content, including assistant IDs, turn/parent and actor metadata.
Row and height caches share a single-owner constant-time LRU with cached byte/unit costs;
an entry that cannot fit does not discard unrelated completed prefixes. Empty documents still
consume entry slots. A single document beyond the block budget remains uncached; incremental
freezing for that larger prefix is not finished. Only HTTP, HTTPS and mail links are interactive; HTML
stays literal text. Original block source comes from cmark's UTF-8 ranges, not a padded table
formatter. Nested tables rendered inline keep their literal source instead of expanding columns.
The upstream Markdown and cmark-gfm licences ship with the app. One parse may reuse up to 32
identical inline fragments within a 64KiB conservative charge; this scratch LRU is cleared after
each parse and shares no styles across documents.

Rendering separately admits at most 256 KiB of UTF-8 per Markdown message before invoking
cmark, and at most 3,000 resulting native rows per message. Over-limit messages become a
local typed placeholder with an explicit Terminal action, without exposing a partial prefix as
the complete message. Omission drops only that item's old cache entry. These are per-message
limits, separate from the aggregate rendered-page allowance.

Each worker also keeps an incremental ledger for at most 3,000 active rendered rows and
8 MiB of conservative rendered-value charges. Original value weights, extra Markdown buffers,
and row metadata (at least twice `MemoryLayout<ChatRow>.stride`) are charged once and reused
from cached renders; revisions/removals subtract their old charge. Changed items are admitted
one at a time into a staged page, before committing its window. An over-budget initial/live
page becomes an explicit Terminal fallback; protected readers keep their old values and
history boundary while rejected live cursors advance. Rejected history alone does not invent
newer content. Neither boundary refreshes nor automatic history retries loop on that fallback;
an explicit reset can recover. These remain accounting allowances, not allocator, transient
parser or whole-process RSS guarantees.

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

On iOS, tracked Claude/Codex panes have a title-bar Chat/Terminal control. New iPhone panes
prefer Chat; iPad panes prefer Terminal. Explicit choices persist by host and pane, not native
session, and temporary availability fallbacks do not overwrite them. Other agents and the Mac
remain Terminal-only. Codex currently falls back until its same-process adapter is connected.

`PaneChatState` owns the draft independently of the evictable render model. Visible panes lease
a bounded model and route the same workspace/pane's `TimelineChannel` into it. Both presentation
containers stay mounted while visible; the timeline continues advancing in Terminal mode.
Leaving the view releases its lease, and destroying the pane forgets the unreachable model.

`TerminalHost` parks its long-lived terminal view outside the window hierarchy while the
backend and VT feed remain alive. Inactive containers neither take the view from an active
host nor give it changing layout; removal stops the display link and releases GPU resources.
Reactivation reuses the same view and backend. Both directions veto marked text before resigning.
A shared typed presentation gate blocks stale terminal keys and pastes while Chat is selected,
including the prediction path; generated VT replies remain independent. This gate is not a
prompt-consumption acknowledgement. The iOS composer uses the separate owner-only, capability-gated
send path below; old helpers cannot receive its new wire variants.

Before the first Chat layout, `DeferredPaneSizing` stages the hidden viewport without sending
a resize or claiming ownership. Actual input or an explicit sizing claim admits it; generated
replies and focus do not. Deferred candidates are excluded from automatic local-tap handover.
Native fixture tests cover retained views, reading position, live updates while parked, original
VT geometry and zero resize/claim/input calls. Real paired no-SIGWINCH acceptance remains separate.

Chat pins the existing structured approval card above its composer, including for a solo joined owner.
It uses the same `DaemonConnection.decide` signed-decision route, policy/claim/two-person gates and
first-valid-answer handling as the existing shared overlay, never prompt input. An action revalidates
this pane's current request, exact option identity, unanswered state and policy immediately before
calling that route. A known blocked dialog disables Send and refuses prompt prepare/admit on the
host as well; typed chat text cannot act as an unsigned approval key. Empty/unstructured dialogs
still require Terminal. Joining is required; another
pane's metadata cannot produce this card. The Terminal/shared overlay is hidden while Chat owns the
card, so it is not duplicated over transcript rows. Chat actions have44pt minimum touch targets and
do not introduce the shared overlay's idle receipt timer. Existing short-lived Terminal/shared receipts
are unchanged. A known owner can answer before the participant roster arrives; the card does not
mislabel that interval as nobody being able to answer. Command-Return uses the same once-only
composer admission as the Send button. Both the shortcut's enabled state and its action check that
Chat is actually selected, owner membership is known, and terminal/composer IME composition can
park; a retained hidden Chat view cannot send from Terminal. Presentation/lifetime, native session
and timeline epoch are rechecked when the action task runs and again before either native request,
so navigation or a scope replacement between a tap and deferred dispatch cannot start a late send.
Deferred actions keep their tapped text and model generation; a confirmation also keeps its exact
warning revision, never implicitly approving a newer warning. Opening a read-only detail also
rotates the action scope before building its snapshot/command offer; closing it cannot revive
controls queued before that navigation.

Claude's working composer also offers Stop/Escape through a separate interrupt capability and
prepare/admit path. Its ticket is bound to the authenticated `UserPromptSubmit` turn sequence as
well as the live session; a delayed request cannot cross an admitted new turn in the same session.
Stop/StopFailure retire that hook identity; a hook generated before the latest input cannot renew it.
This is not proof of a unique CLI submission, or of the input queue being consumed or clean.
The handler requires owner/Prompt authorization, a still-working Claude runtime, actual foreground,
open exit fence and no pending writer. Dirty/unknown input requires the same current-revision warning
with an explicit Interrupt anyway action. Admission consumes the ticket and dirties the draft before
one Escape is enqueued. A second ticket cannot repeat Escape in that hook turn. The only positive
receipt is **Interrupt requested**, not Stopped. UI/transport failures never automatically retry;
phone text is never cleared. The state machine is independent of a pending prompt receipt, which an
interrupt may make unconfirmed. Current-link capability and live-request checks also cover queued
interrupt controls. Idle/agent/presentation/lifetime changes discard stale native completions;
IME composition vetoes both actions. Codex interrupt is unavailable until its official same-process
control adapter is installed; use Terminal. This is not a proof of an empty PTY queue.

VoiceKit dictation uses an explicit local-draft target, never the focused-Terminal fallback. It
previews without changing the draft and appends only on Use dictation, with no automatic Send or
PTY paste. Context and unchanged-draft checks plus the 16KiB draft budget apply at commit. Starting
dictation invalidates older queued native controls; Send/Stop are vetoed while recording. Target-scoped
finish/cancel cannot control a replacement recording in another pane, and failures stay with their
target. Agent/presentation/lifetime changes and backgrounding cancel. Starting may survive an inactive
scene for system permission dialogs, but host controls remain unavailable during that interval.

The composer Add menu offers Claude's bounded session command list (built-ins plus user/project
command directories). Selecting a command only edits an unchanged, current-scope draft; it never
submits. Offers are replaced rather than reused across navigation or session changes.

Photo selection uses the system's limited picker, not unrestricted photo-library access. An off-main
ImageIO worker admits at most 20MiB of source data, produces a metadata-free JPEG with a longest edge
of 2,048 pixels, and caps uploads at 8MiB. Private, protected local staging files are removed when their
transfer ends. The existing authenticated upload stream creates a unique, non-overwriting 0600 file
under the host's `Downloads/Gudo-Attachments`, then appends its escaped `@path` to the current local
draft without Send or PTY input. Typing during upload is preserved; marked text or a full draft defers
insertion until explicit Add photo. Native controls are blocked during selection/upload. Cancellation,
backgrounding and scope changes discard late completions; a remotely committed image may remain in
Downloads after cancellation, but is never silently attached or retried.

Select Text presents one read-only TextKit2 `UITextView`, not an editor in every row. Native range
selection keeps Unicode/UTF-16 boundaries, with data detectors disabled and DS literal type, ink
and accent. An immutable snapshot identity avoids reassigning the whole string on parent/theme
updates, preserving selection and reading position; a new snapshot replaces it explicitly.
Copy/Select Text use rendered plain block content, while Copy as Markdown preserves the exact
source. If structured rendering omits content, menus explicitly offer the full raw Markdown
rather than labeling a partial table/list preview as complete plain text.

Tool headers distinguish Running, Completed, Failed, Denied and Interrupted in text as well as
colour; future status tags never become success. Titles are bounded for native layout and
accessibility. Empty/redacted thinking has no false expand affordance or invented duration.
Expanded tools reuse the existing read-only diff-line renderer for the first six bounded lines,
prepared off-main and charged to the render cache. Copy/selection menus explicitly label output
previews rather than presenting a tail as complete output. Task tools show recorded input/output
and status; nested subagent transcripts remain a Terminal fallback, never a guessed file/thread.

Tool details read output through the existing authenticated same-pane output API, one bounded
native page at a time, with Input/Output tabs and Beginning/Previous/Next navigation. Closing the
sheet invalidates pending replies. Diff details use read-only native unified/side-by-side rows,
with independent file collapse and explicit preview/omission notices. Load recorded changes uses
only the selected tool results' existing opaque handles on this pane's authenticated client. Replies
are decoded off-main within a 12MiB + 1KiB JSON envelope and staged incrementally against one aggregate
native diff budget; a rejected, cancelled or stale request retains the original preview. Loaded paths
cannot broaden the selection and incomplete replies cannot acquire the recorded-result label.
The sheet labels recorded tool changes, not a complete turn or the current working tree. It never
maps opaque timeline turns to numeric repository captures. Complete-turn aggregation beyond the
retained results and device snapshot persistence remain pending.
Turn-summary Changes uses the opaque turn identity, not a file path. Tool-file selections also
carry the owning item identity. Missing or empty turn correlation offers Terminal rather than
showing changes from other visible turns. Command-mark lookup is associated with the exact
Pane/view, not a process-global pane number: different hosts and linked views can reuse it.
Exact command jumps use that VT's retained row pin; missing, future, erased, foreign-pane or
alternate-screen marks are not approximated with a similar-looking prompt. Chat row and tool-detail
Terminal actions admit the presentation before navigating, with both Terminal and composer marked-text
vetoes. An unavailable pin opens Terminal without scrolling and shows an explicit notice. An admitted
presentation selection or agent change clears that notice. Navigation does not launch an agent or write input.

`ChatViewController` owns one normal-orientation reusable collection and a composer host pinned
to the keyboard layout guide. A display-link coalesces pending frames; stopped views release
that clock. Inactive presentation parks it and retains only the latest pending frame. Changed-row values and order revisions keep content-only updates independent of
window length. Parent revisions detect a skipped render frame and force full reconciliation.
A render generation also invalidates cached values when two connections reuse IDs and cursors.

Visible rows use cached native fitting heights from one detached sizing host, independent of
reused cells' stale intrinsic sizes. Exact width, Dynamic Type and legibility changes invalidate
those measurements. Measurement markers are pruned to retained row IDs after order changes;
the 500-entry height LRU also charges identifier/metric metadata against a 4 MiB allowance.
Before a timeline snapshot is submitted, its current and destination viewports receive native
fitting heights; viewport selection repeats if fitting exposes additional rows. An empty
collection uses a synchronous initial reload and destination placement in the same layout
transaction; populated collections retain their diffable updates and reading anchors.
Unstyled ASCII paragraphs fitting one or two lines use Core Text for line breaks and an
eight-profile LRU of heights calibrated through the same native row/environment for that exact
line count. Three-plus lines, styled, Unicode, control-character and custom text-case/line-height
values keep the sizing-host fallback; there is no guessed UIFont equivalent or line-height formula.
This preflight is synchronous, so its cold cost is still a performance acceptance gate.
Scrolling opts into the same viewport fitting before the native collection layout prepares
cell attributes, repeating if fitted heights expose more rows and preserving the reading anchor.
The hook is weak and optional; other native lists do not acquire Chat fitting. Active snapshot
transactions and reentrant sizing are excluded. The fallback measurement pass still yields after
3 ms and updates prefix positions without re-hashing every row. Valid subpoint reading offsets
near a row end remain exact; only offsets outside a resized row use the end fallback.
Prepends restore the same reading row;
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
performance verification are separate gates. `RowBuilderTests.testColdFourKiBRowBuildMedianBudget`
is an opt-in timing check (`TEST_RUNNER_GUDO_CHAT_PERFORMANCE=1` with xcodebuild); it measures both
repeated and varied paragraphs, with worker time separate from actor scheduling. Its 2ms median
assertion remains strict. An ordinary functional test run skips it rather than implying performance
acceptance. Optimized Debug measurements are still Debug simulator evidence, not Release or hardware.

## Claude adapter

`crates/daemon/src/timeline/` owns discovery, parsing, paging and watches. Session IDs come
from the pane's captured agent session. Hook `transcript_path` takes precedence over the
project-directory convention. A pane can be watched before the agent writes its first
transcript.

The parser recognizes user messages, assistant text and thinking, tool calls and results,
structured edit patches, plans, title and permission metadata, turn duration and compaction.
Unknown or malformed records are skipped without ending the watch. Unsupported visible
content and oversized messages produce bounded Terminal notices, not an agent restart.
Thinking signatures and redacted data are never exposed.

Native file notifications and scoped agent events wake an incremental byte-offset reader;
there is no periodic filesystem/session poll. Native subscriptions attach before the initial
read and queue one reconciliation to cover changes during attachment. Installation or reported
backend failures make Chat unavailable instead of silently losing coverage. Read/open events
cannot wake the reader back into itself. Known bounded-read backlogs queue their own continuation,
including when no further file event occurs. The 35 ms minimum refresh interval coalesces only
already-pending work; idle workers have neither an active timer nor a strong pane lease.
Blocking I/O and parsing run on the blocking executor. Reusable tool IDs merge calls and results; complete output remains
on disk until requested. Inline output is a terminal-control-free tail of at most 4 KiB,
and inline diff previews retain at most six lines. Each preview line retains at most 512
Unicode scalar values; either line-count or line-text truncation marks the hunks incomplete,
including created-file previews. Unknown recorded change kinds do not become familiar Modified
previews; literal tool text/output and Terminal remain available. The historical edit shape with no
change-kind field remains distinct from an explicit unknown kind.

The fixture in `crates/daemon/tests/fixtures/timeline/` is emitted by the installed Claude
Code CLI against a loopback-only mock API with an isolated home and placeholder key. Its
README records which data is preserved. No real account is used.

## Read-only diff foundation

Native diff rows accept an explicit note callback; without one, they expose copy actions but
no note action or review-button accessibility trait. Snapshot identities can differ from display
paths, so separate edits of the same file do not share native rows or collapse state. Existing
repository diffs retain their path identities and review callbacks.

`ChatDiffSnapshot` converts scoped timeline diff groups without treating opaque turn identities
as repository capture IDs. It admits at most 128 files, 512 hunks, 20,000 lines and 2 MiB of
conservative derived-value charges, with an 8 KiB UTF8 limit per line. Over-budget or unknown
semantics reject the whole selection with a Terminal fallback. Hunk coordinates, newline
markers and omission flags survive conversion. The native Chat diff sheet uses this snapshot
without a `DiffSource`, repository identity, note callback or review submission path. Snapshot
conversion and native geometry run off-main. Scaled header metrics preserve touch targets and
summary room without changing repository-review defaults. The inline timeline retains bounded
previews; the separate feature-gated recorded-result endpoint loads selected tool changes.

## Output reader foundation

`ChatOutputReader` reads one 64 KiB output range at a time and retains only that page, with
64 prior byte offsets and a route back to the beginning. Responses must agree with UTF8
byte cursors, make progress and fit a bounded JSON envelope. Native presentation admits at
most 4,096 lines; remaining text continues at the exact unconsumed byte, without being lost.
Cancelled or superseded reads cannot publish a page or overwrite a later loading state.
A changed output size requires restarting rather than mixing versions. The tool sheet uses the
reader rather than treating its short output reference preview as complete. Input and output use
native virtual text rows; oversized input gets an explicit Terminal fallback. No detail action
submits text or launches another process.

## Shared daemon agent interface

`agent_driver::AgentDriver` is the daemon boundary for capabilities, opening a pane's session,
queueing a prompt, requesting an interrupt and delivering an approved/denied request. It also
normalizes transport acknowledgements and turn boundaries. Adapter capabilities describe read,
send, acknowledged send, stop, approvals, diffs, streaming deltas, thinking and plans; they do not
authorize an action.

`AgentSession` exposes common snapshots, incremental operations, history, tool output and recorded
diffs. It owns its notification source and reports session changes through snapshot epochs.
On-demand reads return owned futures: file readers can complete in the blocking pool, while RPC
readers can await a response after releasing the service mutex. The service checks identity and
epoch again before returning a deferred response. No session file or RPC shape is part of either
interface. Pending approvals expose normalized request IDs, tool names and optional command/editable
text, plus a cheap live-delivery check. Policy, edited approvals and input assistance query the driver,
not a particular hook or RPC transport.

Claude's account/path discovery, transcript lifecycle, prompt/turn hook interpretation, interrupt
encoding and approval reply format belong to its adapter/read backend. The common daemon retains
owner/role checks, signed approval policy, audit ordering, draft revisions, single-use tickets,
input-to-runtime locking and exit fencing. Queue admission does not acknowledge consumption or a
unique CLI submission. No action is automatically retried.

The terminal-only compatibility adapter preserves the existing Codex paste/notify behavior; it has
no readable session or native interrupt. It is not the official app-server adapter.

`agent_driver::conformance` runs the same capability-driven contract against each registered adapter's
fixtures. It covers stable snapshots, disjoint paging, malformed/unknown records, upserts, output,
recorded changes, rotation, stale deferred replies, session replacement, draft consent/revision,
single-use send/stop, matching and absent acknowledgements, and signed allow/deny without PTY text.
Format-specific fixture setup and response decoding stay beside the adapter. Raw PTY tests prove
queue bytes and hook correlation, not real CLI consumption.

`DaemonFeatures::AGENT_CAPABILITIES` gates `TimelineWatchCapabilities` (workspace request72).
Its `AgentTimeline` reply (response39) pairs the existing snapshot with the producing session's
`AgentCapabilities`, captured under one state lock. Legacy watches retain their exact reply shape;
no metadata pushes or extra fields are sent to old apps. Metadata watches use the same View scope,
since-join filtering, schema negotiation and bounded watch/bulk queues as legacy watches. The client
checks the current link's feature bit at serialization as well as before requesting metadata.

The FFI exposes the snapshot's JSON with an additional numeric `capabilities` field. On a helper without
the bit, it performs the legacy watch and derives the readable block-level contract and controls from
that link's existing feature bits, without looking at agent kinds. A snapshot lacking FFI metadata is
read-only in the app; unknown feature bits never grant a known action. Chat selects Send, Stop,
approvals and recorded-diff controls by feature, with the existing role/context checks still required.
A capability round trip rotates the local intent generation even when both transitions arrive in one
render batch, so restoring support cannot revive a deferred action. Live timeline operations retain
the watch's features; reconnects and agent/session replacement retire its context.

Codex proxy work follows this shared interface and capability contract.

## Codex adapter foundation (phase 2)

`agents::CodexBinding` passively correlates one proven pane-owned TUI connection's official
thread/start, thread/resume and thread/fork replies. An unsolicited thread/started notification
or matching cwd cannot establish ownership. A new request retires the old binding immediately;
resume requires the exact requested thread. Each successful binding has a non-reused identity,
so deferred work cannot survive a same-thread round trip or another connection. Typed envelopes
reject duplicate identity fields. Observation retains at most 256 bounded binding-request IDs
and parses at most 64KiB per pending control frame; exhaustion closes native binding, not Terminal.
A future proxy must forward official frames unchanged, independently of these native limits.

This is the adapter's correlation foundation, not an enabled production Codex timeline/control
transport. It opens no sockets, starts/resumes no process, sends no bootstrap turn and writes no
session file. Tests use synthetic requests plus the previously recorded official response fixture;
they do not prove a new real-TUI proxy integration. Pane/account-owned transport lifecycle, exact
live notification materialization and signed approval routing still need integration. Existing
Codex panes are not restarted or silently replaced to enable Chat.

## Native composer safety prerequisites

The integrated native Chat composer retains the exit-fence boundary. That fence protects existing
composer/reviewer PTY writes from crossing into the fallback shell; it does not prove the TUI
has an empty draft or make those legacy paste/Enter pairs transactional.

Real Claude 2.1.318/2.1.319 captures in `crates/daemon/tests/fixtures/agent-input/` establish two
important limits: Ctrl-U after a multiline paste leaves an earlier line intact, and a spaces-only
draft with the cursor at Home has exactly the same input-region cells and cursor as an empty
draft. Layout, styles, blank-cell distinctions and cursor position cannot establish emptiness
by themselves. Chat instead uses explicit draft-risk admission: real input after the last accepted
`UserPromptSubmit` dirties the draft, including Escape, interrupt, deletion and whitespace. Unknown
sessions and missing hooks require confirmation rather than acquiring an inferred empty checkpoint.

The gate now belongs to `Pane`, so every non-protocol `Pane.write` advances its input revision
before enqueue and again when enqueue finishes or is cancelled. An owned guard counts writes
waiting under backpressure; native legacy writes advance the same revision under that gate.
Revision exhaustion disables native input instead of wrapping. These are input bookkeeping,
not a child-read acknowledgement: even a later Stop hook cannot prove an older raw write has
finished traversing the kernel and the TUI's own input queues. The new path does not claim that
bookkeeping is a trusted empty checkpoint or that a writer flush is consumption.

A small bracketed-paste-plus-Return packet reached the isolated loopback API exactly once on
both probed versions. That observation does not prove all bindings, payload sizes or modal
states safe. Signed approval routes and owner-only permission-mode changes remain separate.

## Native sending

`ChatPrepare` (request 68) mints one single-use, session-bound ticket for the live fenced pane.
`ChatSend` (69), response `ChatSend` (38), and helper feature `CHAT_SEND` (29) are append-only.
Client methods check the feature before constructing requests and again against the current peer when
queued control traffic leaves after a reconnect. Expired/disconnected Chat controls are dropped before
serialization instead of reaching a later connection. Sending requires pane Prompt permission
and a paired owner; guests cannot send through this path. Read-only timeline requests still require View.

The daemon accounts for every real input byte at `Pane.write`, before enqueue/backpressure, and for
legacy native input under the same gate. Generated VT replies and focus reports do not dirty drafts.
The ephemeral journal retains at most 16KiB, counts overflow without becoming clean, and is never
persisted or returned to clients. It is not a screen-based draft reconstruction. A dirty/unknown draft
requires the displayed revision's explicit Send anyway. Any intervening input requires confirmation
again. Preparing another ticket invalidates the previous unconsumed ticket; consumed tickets cannot
replay, even after timeout or pane replacement. Ticket allocation is monotonic across launch state and
starts beyond this boot's clock so a fresh daemon process does not recycle earlier same-boot tickets. Native text is sanitized and limited to 16KiB.

The admitted write is one bracketed-paste-plus-Return packet under the existing exit fence. It neither
clears a Mac draft nor retries. Bracketed-paste mode and the same live foreground agent are required.
Adopted panes without an exit fence remain unavailable: confirmation cannot create that process fence.

For Claude, the authenticated `UserPromptSubmit` hook must match the tracked native session and
whitespace-normalized prompt within five seconds. Replayed or pre-input hook timestamps cannot clear
newer drafts or confirm a send. Mismatch, concurrent real input, timeout or exit reports
**Not confirmed, check the terminal**. A late hook cannot change a terminal receipt; concurrent input
keeps a late hook from establishing a clean baseline. Matching session/text is the requested hook-based
confirmation policy, not a cryptographic submission ID or proof that all preexisting PTY bytes were read.
For Codex, an available `UserPromptSubmit`, or a same-thread `agent-turn-complete` notify with exactly
one matching `input-messages` entry, can confirm within the same window. Missing/ambiguous notify input
cannot be guessed or aggregated. Codex with no correlated acknowledgement reports **Sent, not confirmed**
after that window; mismatch, concurrent typing and exit remain **Not confirmed, check the terminal**.
Native request waits end after ten seconds on transport loss, without resend.
The phone preserves an unconfirmed draft and blocks accidental reuse of that unchanged text; confirmed
text clears only if the user has not edited the composer while awaiting the receipt.

## Scope and bounds

Every read request requires View on its pane. A guest's since-join policy filters items and full
output, including reads made with a guessed handle. Output handles cannot bypass the record-kind
and sidechain exclusions of the main timeline. A transcript must resolve inside the
pane's agent account's `projects` directory and its filename must match the captured session.
Files are opened without following a final symlink. Output reads reject stale file identity
or tail anchors, even before the file watcher runs.

The daemon retains at most 512 items per watched pane and 128 tool-call merge entries.
A separate 16 MiB indexed-value allowance is maintained incrementally on insertion,
revision and whole-record eviction. Each value reserves four cached wire allowances for
owned strings/vectors, duplicate index keys and metadata. This conservative accounting is
not an allocator/RSS measurement and does not include parser state, temporary reads,
in-flight updates or rendered caches. Both count and value pressure remove complete native
records, never just their first siblings. If revisions expand the currently updated record
past the entire allowance, it becomes an explicit Terminal notice rather than an empty page.
Records exceeding the 512-item or page-byte allowance become one explicit Terminal notice
on open, live refresh and history reads. Tool results retain their original record position.
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

Snapshot item data is capped at 1 MiB using a conservative cached postcard bound. The bound
walks typed string/vector fields only when an item changes; snapshot/history selection does
not serialize items to measure them. The requested item count and remaining byte allowance
are tested between complete records; a record that cannot fit after newer records is deferred
to the next page, not silently truncated. This wire allowance does not establish a resident
memory or RSS bound. A connection
may watch four panes. Pushes occupy one mailbox slot per pane and coalesce to a snapshot
under backpressure. Each queued update caches a typed conservative wire bound, without an
encode-to-measure allocation. Coalescing snapshots and failure messages are checked against
the same allowance; an oversized fallback becomes a bounded Terminal failure, not another
oversized queued payload. Watch tokens prevent a cancelled forwarder from reviving an unwatched
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
