# Contributing

Thanks for your interest in Gudo. Bug reports, fixes and improvements are welcome.

## Before you start

- For a bug, open an issue with steps to reproduce, what you expected, and your platform (app
  version, macOS/iOS version, host OS).
- For a larger change, open an issue first so we can agree on the approach.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Building

See "Build from source" in the [README](README.md), [apple/README.md](apple/README.md) for the
apps, and [docs/](docs/) for how the pieces fit together.

## Checks

Run these before you open a pull request:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
scripts/check-invisible-unicode.py
```

For Swift changes, run the affected package's `swift test` (under `apple/Packages`) and build
the app. For changes to the wire protocol, update the golden files in `crates/proto/tests`; wire
messages are append-only.

## Pull requests

- Keep each pull request to one change, with a plain description of what and why.
- Add or update tests for behaviour you change.
- Don't rename public wire types, serde fields, CLI flags, environment variables or anything
  stored on disk: that breaks existing installs.
- Comments explain why, not what. Keep them short.

## Licence

Gudo is licensed under the Apache License 2.0. By contributing you agree that your
contribution is licensed under the same terms (section 5 of the [LICENSE](LICENSE)).
