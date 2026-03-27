# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LifeOS is an AI-native Linux distribution built on Fedora 42 bootc (immutable). It consists of a Rust CLI (`life`), a system daemon (`lifeosd`), and a container-based OS image that gets flashed as an ISO.

**Language:** Rust (2021 edition). Documentation in Spanish, code in English.

## Build Commands

```bash
# Build everything (release)
make build

# Build individual crates (dev)
cargo build --manifest-path cli/Cargo.toml
cargo build --manifest-path daemon/Cargo.toml

# Daemon with all features (needed for ui-overlay/GTK4)
cargo build --manifest-path daemon/Cargo.toml --all-features

# Tests
make test                  # all tests
cargo test -p life         # CLI only
cargo test -p lifeosd      # daemon only

# Single test
cargo test -p life test_name

# Lint
make lint                  # clippy + fmt check
cargo clippy -p life --all-features -- -D warnings
cargo clippy -p lifeosd --all-features -- -D warnings

# Format
cargo fmt --manifest-path cli/Cargo.toml
cargo fmt --manifest-path daemon/Cargo.toml

# Build ISO (requires sudo + podman)
sudo bash scripts/build-iso.sh
```

## Architecture

**Workspace crates:** `cli/`, `daemon/`, `tests/`

### CLI (`cli/` → binary `life`)
- Entry: `cli/src/main.rs` — 34+ subcommands dispatched via clap derive
- Modules: `cli/src/commands/` — one file per command group (mode.rs, context.rs, telemetry.rs, etc.)
- Config: `cli/src/config/` — TOML-based configuration management
- Daemon IPC: `cli/src/daemon_client.rs` — authenticated HTTP client that reads bootstrap token from `/run/lifeos/bootstrap.token` and sends `x-bootstrap-token` header

### Daemon (`daemon/` → binary `lifeosd`)
- Entry: `daemon/src/main.rs` — startup, config, background tasks, signal handling
- API: `daemon/src/api/mod.rs` — Axum REST API on `127.0.0.1:8081` with bootstrap token middleware
- Feature flags: `default = ["dbus", "http-api"]`, optional `ui-overlay` (requires GTK4)
- Key modules: `experience_modes.rs`, `follow_along.rs`, `context_policies.rs`, `telemetry.rs`, `overlay.rs`, `agent_runtime.rs`, `memory_plane.rs`, `computer_use.rs`
- State: `DaemonState` uses `Arc<RwLock<>>` for concurrent manager access

### OS Image (`image/`)
- `image/Containerfile` — two-stage build: Fedora 42 builder → Fedora bootc runtime
- `image/files/` — system files copied into the image (systemd units, scripts, configs)
- AI runtime: llama-server built statically from source, Qwen3.5-4B model bundled at `/var/lib/lifeos/models/`

### Contracts (`contracts/`)
- JSON schemas for intents, identity/delegation, skills, and onboarding

## Critical Constraints

- **bootc immutability:** `/usr` is read-only at runtime. Never create symlinks or modify files in `/usr/bin` or `/usr/sbin` at runtime. All changes to `/usr` happen at image build time in the Containerfile.
- **llama-server:** Must be built with `-DBUILD_SHARED_LIBS=OFF -DGGML_STATIC=ON` (static). Binary ends up at `/usr/sbin/llama-server`.
- **os-release:** Must keep `ID=fedora` for bootc-image-builder compatibility. Use `VARIANT_ID=lifeos` for branding. **NEVER use non-ASCII characters** (em dash `—`, accents, emoji) in any field — the GitHub Actions runner sends `PRETTY_NAME` in HTTP headers, and .NET rejects non-ASCII.
- **systemd:** Does NOT support `${VAR:-default}` bash syntax in ExecStart. Use EnvironmentFile for variable defaults.
- **Daemon auth:** All `/api/v1/*` routes require `x-bootstrap-token` or `x-api-key` header. CLI reads token from `/run/lifeos/bootstrap.token`. The `daemon_client::authenticated_client()` handles this.
- **Daemon features:** Default features exclude `ui-overlay`. Building `--all-features` requires GTK4 dev headers (`gtk4-devel`, `glib2-devel`, etc.).
- **User cannot run sudo:** Never run sudo commands directly. Provide commands for the user to run manually.

## Integration Rule: No Orphaned Modules

**Every new module MUST be connected to the runtime before committing.** LifeOS has 40+ modules but historically many were implemented as dead code (`#[allow(dead_code)]`) without being wired to Telegram, the API, the supervisor, or any background loop.

**Before implementing any feature, answer these questions:**
1. **Who calls this?** — Which existing module will invoke this new code?
2. **How does it reach the user?** — Via Telegram tool? API endpoint? Proactive notification? Background automation?
3. **Does it need the event bus?** — Should it emit or listen to DaemonEvent?
4. **Does it need memory?** — Should it read from or write to MemoryPlane/KnowledgeGraph?

**Checklist for every new module:**
- [ ] Registered in `main.rs` WITHOUT `#[allow(dead_code)]`
- [ ] Instantiated in `DaemonState` (if stateful) or called from an existing module
- [ ] Has at least ONE runtime path: Telegram tool, API route, event bus handler, or background task
- [ ] If it produces data the user cares about: wired to Telegram notifications
- [ ] If it stores data: wired to MemoryPlane or KnowledgeGraph
- [ ] If it needs LLM: receives LlmRouter reference

**Exceptions:** Feature-gated modules (`#[cfg(feature = "...")]`) that require external services (Home Assistant, WhatsApp, etc.) may be compiled but not active until configured. These are NOT dead code — they activate when the user provides credentials.

## Self-hosted Runner (`/var/lib/lifeos/actions-runner/`)

- Service: `actions.runner.hectormr206-lifeos.hectormr.service` (system-level, user `lifeos`)
- **SELinux:** After installing or updating the runner, binaries need `bin_t` context or systemd fails with `status=203/EXEC`:
  ```bash
  sudo chcon -t bin_t /var/lib/lifeos/actions-runner/runsvc.sh
  sudo chcon -t bin_t /var/lib/lifeos/actions-runner/bin/Runner.Listener
  sudo chcon -t bin_t /var/lib/lifeos/actions-runner/bin/Runner.Worker
  sudo chcon -t bin_t /var/lib/lifeos/actions-runner/externals/node20/bin/node
  ```
- `.env` sets `DOCKER_HOST=unix:///run/user/1000/podman/podman.sock`
- Labels: `self-hosted, Linux, X64, lifeos, bootc`

## Pre-commit Hooks

On commit: rustfmt check + clippy (both crates). On push: cargo test + cargo audit.

## CI Pipeline (`.github/workflows/ci.yml`)

Jobs: build-cli → build-daemon → integration-tests → security-audit → runtime-security → coverage → docs. Clippy runs with `-D warnings`.

## Key File Paths (in the OS image)

| Purpose | Path |
|---------|------|
| Containerfile | `image/Containerfile` |
| llama-server service | `image/files/etc/systemd/system/llama-server.service` |
| llama-server env | `image/files/etc/lifeos/llama-server.env` |
| AI setup script | `image/files/usr/local/bin/lifeos-ai-setup.sh` |
| System check | `image/files/usr/local/bin/lifeos-check.sh` |
| Build ISO | `scripts/build-iso.sh` |
| Roadmap | `docs/lifeos-ai-distribution.md` |
