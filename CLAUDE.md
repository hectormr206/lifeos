# CLAUDE.md

LifeOS — AI-native Linux distribution on Fedora bootc (immutable). Rust CLI (`life`) + user-session daemon (`lifeosd`) + bootc OS image.

**Language:** Rust 2021. Documentation in Spanish, code in English.

## Build Commands

```bash
# Build
cargo build --manifest-path cli/Cargo.toml       # CLI
cargo build --manifest-path daemon/Cargo.toml     # Daemon
make build                                        # Both (release)

# Test
cargo test -p life                                # CLI tests
cargo test -p lifeosd                             # Daemon tests
cargo test -p life test_name                      # Single test

# Lint
cargo clippy -p life --all-features -- -D warnings
cargo clippy -p lifeosd --all-features -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml
cargo fmt --manifest-path daemon/Cargo.toml

# ISO (requires sudo + podman)
sudo bash scripts/build-iso.sh
```

## Architecture (quick ref)

| Crate | Binary | Entry | Key dirs |
|-------|--------|-------|----------|
| `cli/` | `life` | `cli/src/main.rs` | `commands/`, `config/`, `daemon_client.rs` |
| `daemon/` | `lifeosd` | `daemon/src/main.rs` | `api/`, `axi_tools.rs` (shared agentic chat), `llm_router.rs`, `supervisor.rs` |
| `image/` | ISO | `image/Containerfile` | `image/files/` (systemd units, scripts, configs) |

- **Daemon API:** Axum REST on `127.0.0.1:8081` + WebSocket at `/ws`. Auth: `x-bootstrap-token` header
- **AI runtime:** llama-server on `:8082`, Qwen3.5-4B default, 13+ LLM providers via `llm_router.rs`
- **Features:** `default = ["dbus", "http-api"]`, optional `ui-overlay` (GTK4), `messaging` (SimpleX bridge), `tray`

## Critical Constraints

- **bootc:** `/usr` is read-only at runtime. All mutable state in `/var/` or `/home/`
- **No `#[allow(dead_code)]`** on new modules — wire to Telegram/API/event bus/supervisor
- **Pre-commit hooks:** rustfmt + clippy. On push: cargo test + cargo audit
- **User cannot run sudo** — provide commands for user to run manually
- **Daemon auth:** All `/api/v1/*` need `x-bootstrap-token` or `x-api-key` header

## Documentation Sync Rule

**When changing code, ALWAYS update docs in the same commit.** This is mandatory, not optional.

| If you change... | Update... |
|---|---|
| New systemd service/timer | `docs/operations/system-admin.md` (service diagram) |
| New feature in daemon | `docs/user/user-guide.md` + `README.md` feature list |
| New CLI command | `docs/user/user-guide.md` |
| Containerfile (new package/service) | `docs/user/installation.md` if user-visible |
| SimpleX bridge | `docs/operations/simplex-features.md` |
| Security config | `docs/user/installation.md` Security Defaults section |
| Architecture change | `docs/architecture/` relevant file |
| Version bump | `README.md` badge + `docs/architecture/update-channels.md` examples |

If unsure whether docs need updating: **they do.**

## Navigation — Find What You Need

Instead of reading everything, use `docs/README.md` as index:

| Need | Go to |
|------|-------|
| Strategy, phases, roadmap | `docs/strategy/` |
| Technical architecture | `docs/architecture/` |
| Operations, runbooks | `docs/operations/` |
| Branding, icons, theme | `docs/branding/` |
| Privacy, LLM provider policies | `docs/privacy/` |
| User guides | `docs/user/` |
| Contributing | `docs/contributor/` |
| Research (OpenClaw analysis) | `docs/research/openclaw/` |

**Tip:** Use `grep` or `glob` to find specific files rather than reading entire directories.
