# Contributing to LifeOS

Thanks for helping improve LifeOS.

## Recommended Workflow

1. Create a focused branch (or work from your fork).
2. Implement the change with tests.
3. Run the required quality gates locally.
4. Open a pull request with a clear summary of the change.

## Issue and PR Policy

LifeOS uses a pragmatic process:

- **Small fixes, maintenance, or obvious cleanup** -> PR is enough; no issue required.
- **Medium features or important changes** -> issue is recommended, but not mandatory.
- **Large, architectural, or sensitive changes** -> open an issue first, then submit a PR.

Use the lightest process that still preserves enough context for future maintainers.

## Required Quality Gates

Run these before opening a PR:

```bash
make check-daemon-prereqs
make phase3-hardening
make truth-alignment
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features --no-fail-fast
cargo test --package lifeos-integration-tests --test integration_tests -- --test-threads=1
```

## More Contributor Docs

- `docs/contributor/contributor-guide.md` — contributor workflow and local setup
- `docs/contributor/claim-vs-runtime-checklist.md` — fast guardrail for docs/runtime/update claims
- `docs/contributor/testing-conventions.md` — testing expectations and regression coverage
- `docs/README.md` — documentation index
