# ChatSyntax

Native, display-only syntax ranges for Chat code previews, using SwiftTreeSitter and pinned
upstream grammars/queries. Rust, Swift, JavaScript/JSX, TypeScript/TSX, Python, Go, shell, JSON,
YAML, TOML, Markdown, C/C++, HTML, CSS and diff fences are supported. Unknown fences stay plain.
No JavaScript runtime, subprocess, networking, file opening or input/approval authority is used.

`CodeHighlighter` is synchronous and deliberately non-Sendable. The app's timeline render worker
owns one through its `RowBuilder`; only immutable UTF-16 `CodeToken` ranges cross to the UI.
Parsers stay on their worker. Immutable queries are shared, at most one per bundled language, each
behind its own lock, so a cold compile of one language never waits on another. There is no await
under those locks. TypeScript/TSX and C++ compile inherited base queries against their own grammar.

Limits: 16 KiB / fewer than 2,000 newlines per input, 1,024 matches/tokens, parser 10 ms timeout,
256 concurrent query matches and a 20 ms query-consumption allowance. Unsupported, unavailable,
invalid or over-budget highlighting falls back to unmodified plain text. Timed-out parsers are
reset before reuse. A source-and-language keyed LRU retains at most 128 entries / 512 KiB.
`beginAllowance(_:)` bounds a whole render pass: once it is spent, uncached blocks return
`.deferred` (plain, not cached) and highlight on a later pass. The first uncached block of a pass
always parses, so every pass makes progress. Callers can skip caching for text that is still
changing, such as a streaming block.
The app sends only its existing 30-line / 8 KiB preview, not hidden full code. Full copy text is
unchanged and never contains highlighting metadata.

Token roles map to ANSI palette slots, not fixed colours. The app separately projects them
through the current terminal theme with readable contrast, and caches that presentation by
content, tokens, complete theme and contrast setting. Colour changes do not reparse or remeasure
code, and do not add links or other interactive attributes.

Some newer upstream SPM manifests detect scanner sources relative to the invoking working
directory. SwiftPM's Xcode build system omitted those scanners and failed to link. The JavaScript,
Python, CSS and YAML pins here deliberately use working releases with explicit scanner sources.
No dependency checkout patches or build-directory assumptions are required. Tests exercise every
grammar and actual query resource loading, Unicode ranges, inherited captures, incomplete code,
plain fallback and cache bounds. App tests separately check resources in the actual app bundle.

Licences and copyrights: `../../../scripts/notices/tree-sitter.txt` and
`../../../scripts/notices/tree-sitter-unicode.txt` from the repository root's notice generation.
