# Native scrolling surfaces

Code and transcript-sized surfaces must not use SwiftUI lazy stacks. Their cells are reusable
native containers; SwiftUI draws only the current window of rows. `NativeVirtualList` uses
`NSCollectionView` on Mac and `UICollectionView` with a diffable data source on touch.
`NativeListLayout` owns fixed/cached heights, prefix positions, binary-search viewport and
header lookup, stable identities and scroll anchors. Diff and file rows have fixed or
precomputed heights. Chat measures visible cells once per row revision and metrics, then updates
prefix positions in a bounded native pass, outside SwiftUI state. Geometry revisions change only when identifiers, dimensions or header behavior change;
a status/text update with identical geometry refreshes visible content without reloading rows.
The hosting boundary forwards the environment, including theme, accessibility and window model.

## Surface audit

- **Touch Chat presentation:** one normal-orientation `UICollectionView`, diffable row identities
  and `UIHostingConfiguration` content. Native measurements are cached by identity, revision,
  exact width, Dynamic Type, legibility, expansion and terminal font size. One detached sizing
  host avoids caching a reused cell's previous intrinsic size; a measurement pass yields after 3 ms.
  UIKit cell content ignores safe areas: collection-level insets own the chrome and keyboard
  boundaries, so a partially clipped row never reflows itself around the screen's safe area.
  Stable order revisions and changed-row values avoid walking the whole window on token updates.
  A skipped frame falls back to full reconciliation. Height changes update prefix geometry
  without rebuilding identifiers. Prepends restore the reading anchor; bottom following checks
  the user's scroll generation before deferred adjustments. Large Markdown lists split into
  20-line native rows, prose into 2,048-character rows, and code previews cap both lines and bytes.
  Long user/thinking text, tables and plans retain their full values for explicit detail actions.
- **Diff review:** `DiffRenderDocument` builds unified/split rows and note heights off the main
  actor. No nested scrolls or lazy stacks. Code never wraps; width is estimated before rendering.
  Split columns stay equally wide in the viewport; horizontal scrolling moves their code,
  not their gutters or the center divider. Notes retain their draft outside reused cells.
  File headers remain pinned. Anchors fall back
  to the file header when a collapsed file removes their line.
- **File text preview:** `NativeTextDocument` detaches numbered lines, determines its gutter
  before layout and supplies fixed heights. Numbers and code share one native row, rather than
  two independent lazy stacks. Truncation is a separate final row.
- **Open-source notices:** the same native surface, with paragraph wrapping and Core Text
  heights calculated off-main for the available width. Resizing invalidates cached heights,
  not a row-measurement/state feedback loop.
- **Workspace sidebar, projects, agents and worktrees:** a plain native-backed SwiftUI `List`
  with transparent row groups, zero row insets and hidden system fills/separators. Each tab,
  agent and expanded worktree is a separate native row. Expanded worktrees are flattened in the
  sidebar model instead of placing an entire repository in one cell. The list owns the drag
  coordinate space and drop target; frame reporting is hit-test data, never a height input.
- **Agents/Inbox, Hosts, files/folders, ports, session history/replay actions and searchable
  settings:** already use native-backed `List`/`Form`. Menu pickers and bounded toolbar/chip
  stacks are not long-list renderers. Browser content, terminal grids and the editor retain
  their own native rendering engines.

There are no `LazyVStack`/`LazyHStack` instances in App sources after this audit.

## Regression evidence

The owner's `error.txt` main-thread sample identifies SwiftUI section/lazy-stack sizing, not
patch parsing. The small offscreen split fixture exposed proposal-dependent wrapping (129 pt
for one paired code row plus its hunk header); the fixed renderer keeps the code row at 18 pt
through repeated width changes. This fixture does not claim to reproduce the exact 251-second
OS layout stall. Removing the nested lazy renderer removes that stack from the scrolling path.

`DiffLayoutTests` covers the small layout, namespaced hunk identities, both note sides, cached
positions and anchors, and real native jumps through 20,000 lines on Mac and touch, recording
main-thread jump times and bounding the number of created row contents. `NativeListLayoutTests`
covers revision stability, empty/pinned-header boundaries, 20,000 preview lines and cached
paragraph reflow and incremental height updates. `ProjectSidebarTests` checks native row
granularity and drag coordinates. `ChatCollectionTests` covers anchored prepends, following versus
reading, changed-row reconfiguration, coalesced frames, connection generations and clock teardown.
Its synthetic 2,000-row Simulator replay gates cached first content at 100 ms, streaming apply
p99 at 4 ms, memory above baseline at 80 MiB and second-pass growth at 8 MiB. These are Debug
Simulator checks, not physical-device Release measurements.
Snapshots are opt-in and run in process; Mac test windows remain offscreen.
