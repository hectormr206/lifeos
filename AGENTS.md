# AGENTS.md — Quick Onboarding for AI Agents

## What is LifeOS?

AI-native Linux distribution (Fedora bootc + COSMIC Desktop). Three Rust crates:

| Crate | Binary | Purpose |
|-------|--------|---------|
| `cli/` | `life` | CLI for user interaction |
| `daemon/` | `lifeosd` | System daemon: REST API, AI, Telegram, supervisor |
| `tests/` | — | Integration tests |

Plus: `image/` (OS container), `scripts/` (automation), `docs/` (documentation).

## Build & Test (essential commands)

```bash
cargo build --manifest-path daemon/Cargo.toml    # Build daemon
cargo test -p lifeosd                             # Test daemon
cargo test -p lifeosd test_name                   # Single test
cargo clippy -p lifeosd --all-features -- -D warnings  # Lint
cargo fmt --manifest-path daemon/Cargo.toml       # Format
```

## Rules for New Code

1. **No orphaned modules** — register in `main.rs`, wire to Telegram/API/event bus
2. **Use `anyhow::Result`** for all fallible functions
3. **Run `cargo fmt` + `clippy`** before committing
4. **`/usr` is read-only** at runtime (bootc immutable) — state goes to `/var/` or `/home/`
5. **Auth required** — all API routes need `x-bootstrap-token` header

## Contribution Workflow Policy

LifeOS uses a pragmatic issue/PR policy:

- **Small fixes, maintenance, or obvious cleanup** — no issue required
- **Medium features or important changes** — issue recommended, not mandatory
- **Large, architectural, or sensitive changes** — issue + PR required

Prefer the lightest process that still preserves enough context for future maintainers and agents.

## How to Navigate This Repo

**Do NOT read all docs.** Use targeted searches:

```
docs/README.md          ← Master index (start here)
docs/strategy/          ← Roadmap, phases, competition
docs/architecture/      ← Technical specs, LLM routing, threat model
docs/operations/        ← Runbooks, ISO build, incident response
docs/branding/          ← Icons, colors, fonts, design tokens
docs/privacy/           ← LLM provider privacy analysis
docs/contributor/       ← Coding style, testing conventions
docs/research/openclaw/ ← OpenClaw reverse engineering (21 docs)
docs/archive/           ← Deprecated docs (historical only)
```

**Tip:** Use `grep -r "keyword" docs/` to find specific topics instead of reading entire files.

## Module Integration Checklist

When adding a new daemon module:

- [ ] `mod new_module;` in `main.rs` (no `#[allow(dead_code)]`)
- [ ] At least ONE runtime path: Telegram tool, API endpoint, background loop, or supervisor action
- [ ] If it stores data: use MemoryPlane (encrypted) or existing SQLite DBs
- [ ] If it needs LLM: receive `LlmRouter` reference
- [ ] If it produces user-facing data: send notification via event bus
