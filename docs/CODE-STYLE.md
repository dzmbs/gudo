# Code style

How code in this repository is written. Match it exactly; when unsure, copy how the surrounding
code does it. Reviewers reject changes that don't follow this file.

## 1. Code speaks for itself

The reader learns what code does from its names and structure, never from comments.

### Names

Use descriptive, full words for every meaningful value, parameter, field and function.

| Don't | Do |
|---|---|
| `let r = conn.send(&req).await?;` | `let response = connection.send(&request).await?;` |
| `fn proc(p: u64, b: &[u8])` | `fn write_input(pane_id: PaneId, input_bytes: &[u8])` |
| `let tmp = layout.clone();` | `let previous_layout = layout.clone();` |
| `cfg`, `ctx2`, `buf2`, `res`, `e`, `v`, `s`, `m` | `config`, `session`, `snapshot_bytes`, `result`, `error` |
| `isOK`, `flag`, `data` | `isReachable`, `wantsFocus`, `pairingTicket` |

Short names are fine only where they are the clearest: `i`/`j` in a short loop, `x`/`y` for
coordinates, a closure that only forwards (`.map(|pane| pane.id)`), `f` in `fmt`, `tx`/`rx` for
channel ends. Fix misleading names when you touch them.

Booleans read as yes/no questions (`is_live`, `has_layout`, `wantsFocus`). Functions are verbs
(`resize_pane`, `restoreFocus()`); types are nouns (`PaneLayout`, `HandOff`).

### Comments

Almost none. A comment is allowed only when deleting it would invite a wrong change:

1. A non-obvious **why**: a protocol quirk, a platform bug being worked around, an ordering that
   matters, a number whose origin isn't obvious.
2. Every `// SAFETY:` explaining why an `unsafe` block is sound (required).
3. A security invariant the code depends on.
4. Rust public items may have a single-line `///` when the name alone can't say it.

Everything else is removed:

```rust
// Don't
// Increment the retry counter.
retries += 1;
// Loop over the panes and close each one.
for pane in panes { pane.close(); }
// Fixed: we used to send the snapshot twice here.
// TODO: done
// ===== Helpers =====

// Do (a why the code can't say)
// The kernel may report the child exited before its PTY drains; read until EOF first.
drain_until_eof(&mut master)?;

// SAFETY: `fd` was just returned by `openpty` and is owned by this function.
let master = unsafe { OwnedFd::from_raw_fd(fd) };
```

Never in comments, code, commit messages or docs: conversation details ("as asked", "after the
review"), history ("used to", "now", "previously", "new"), personal data, host names, IPs,
`/Users/...` paths, or other products' names (except real dependencies we interoperate with:
Ghostty/libghostty-vt, iroh, Claude Code, Codex, pi, VS Code, tmux, zsh, bash, fish).

If code needs a comment to be understood, rename or restructure it first.

## 2. Rust

Write Rust a senior Rust engineer would approve: lean, explicit, correctly typed, with the compiler
doing the work. These are the rules; `.claude/skills/rust-idiomatic/references/` has detail
(naming and API, documentation, types and enums, async and concurrency, project structure).

- **Tooling:** `rustfmt` style (4 spaces, 100 columns, trailing commas). `cargo clippy
  --workspace --all-targets -- -D warnings` must be clean. Treat clippy's suggestions as the idiom
  guide.
- **Naming (RFC 430):** `UpperCamelCase` types/traits/variants, `snake_case` everything else,
  `SCREAMING_SNAKE_CASE` constants. Acronyms are one word (`Uuid`, `HttpClient`). No `get_`
  prefix on getters. Conversions: `as_*` cheap borrow, `to_*` owned/expensive, `into_*` consuming.
- **Errors:** `Result<T, E>` for anything that can fail with bad input; `?` for propagation, never
  a hand-written `match` that only re-returns. Real error types: an `enum` with `thiserror` in
  library crates, `anyhow` in binaries. No `String` or `()` errors. `unwrap`/`expect` only for true
  invariants, never on paths a caller or the network can reach; `expect` messages state the
  invariant.
- **Types over primitives:** make illegal states unrepresentable. An `enum` or newtype instead
  of a `bool`, bare integer or `String` with a fixed set of meanings (`PaneId(u64)`,
  `Focus::Pane | Focus::Tab`). Parse untrusted input once at the boundary into typed values, then
  pass those around.
- **Ownership:** take the most general borrow (`&str`, `&[T]`, `impl AsRef<Path>`), return owned
  values. Don't `.clone()` to quiet the borrow checker; restructure, or share deliberately with
  `Arc`. Iterators and adapters over index loops, but split a chain into named steps when it stops
  reading well.
- **Async (Tokio):** never hold a `MutexGuard` or any non-`Send` value across `.await`; don't block
  in async code (`spawn_blocking` for blocking I/O); every spawned task has an owner that stops it;
  bounded channels where a fast producer could outrun a consumer; cancellation-safe `select!` arms.
- **unsafe:** as little as possible, wrapped in a safe API, every block with `// SAFETY:`.
- **Structure:** small focused modules; `pub` only what other crates need; no `mod.rs` sprawl of
  unrelated helpers; tests next to the code (`#[cfg(test)] mod tests`) and integration tests in
  `tests/it/`.
- **Compatibility:** wire types (`proto`), serde field names, FFI names, CLI flags, env vars and
  on-disk formats never change incompatibly. Add fields and enum variants at the end, gate new
  behaviour on capability bits, extend the golden-byte tests.
- **Self-check before committing:** fmt and clippy clean; no new `unwrap` on reachable paths; no
  `&String`/`&Vec<T>` parameters; no stray `.clone()`; no lock held across `.await`; comments are
  only the four kinds above.

## 3. Swift

- Swift 6 language mode, `@Observable` models, `@MainActor` by default, structured concurrency
  (`async`/`await`, task groups); no `DispatchQueue` for new code unless an API requires it.
- No force unwraps (`!`, `try!`, `as!`) on any path a user or the network can reach.
- Small views composed from smaller ones; state lives in models, not in deep view trees.
- Reuse `DesignSystem` before writing anything new: `ChromePalette` for every colour (derived from
  the user's terminal theme), `DS.Font` for type, `DS.Motion` for animation, existing buttons,
  rows, headers, toasts and glass surfaces. Never hard-code a colour or a system colour on chrome.
- Accessibility labels on every control; Dynamic Type on iOS; Reduce Motion and Reduce
  Transparency respected.

## 4. Layout

Things are aligned to edges, never left floating.

- Every overlay (toasts, banners, the update card, status pills, popovers) sits at a defined
  anchor with the standard inset from the window or pane edges: 16 pt on the Mac, the safe-area
  margin on iOS. Never "somewhere near the top right".
- Toasts and notification banners inside the app stack at the **bottom leading corner** of the
  window's content area, 16 pt from the bottom and leading edges, newest at the bottom, sliding
  in from the edge. They never cover the toolbar.
- Toolbars: title and back at the leading edge, actions at the trailing edge. Sheets: title at
  the top margin, buttons at the bottom margin.
- Centre only what is meant to be centred (empty states, the pairing QR code); everything else
  aligns to a leading or trailing edge on the same grid as its neighbours.
- One spacing scale (`DesignSystem` tokens). If two things look almost aligned, make them exactly
  aligned.

## 5. Tests

- Reproduce a bug with a failing test before fixing it.
- Test behaviour through public APIs; avoid testing private details.
- Tests must not depend on timing where a condition can be awaited instead; when a test is
  timing-sensitive, wait for the condition with a generous timeout rather than sleeping a fixed
  time.
- UI changes come with screenshots in light and dark, and in at least two themes.
