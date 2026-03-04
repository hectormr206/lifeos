# GEMINI.md - LifeOS Context & Instructions

## Project Overview
LifeOS is an **AI-Native Linux Distribution** designed to be user-friendly, developer-powerful, and immutable. It is built on top of **Fedora bootc** and the **COSMIC desktop environment**.

### Key Technologies
- **Base OS:** Fedora bootc (Immutable, atomic updates with A/B slots).
- **Desktop:** COSMIC (Modern, Rust-based).
- **Languages:** Primarily **Rust** (CLI and Daemon).
- **AI Runtime:** `llama-server` (llama.cpp) supporting GGUF models (default: Qwen3.5-4B).
- **Storage:** Btrfs (snapshots, compression) + composefs (immutable /usr).
- **Packaging:** Flatpak (sandboxed apps) and Toolbx (mutable dev environments).
- **Security:** LUKS2, Secure Boot, TPM 2.0, and OCI image signing (Sigstore/Cosign).

### Core Components
- `cli/`: The `life` command-line tool (system management, AI interaction).
- `daemon/`: `lifeosd`, the system daemon for health monitoring, updates, and AI orchestration.
- `contracts/`: JSON schemas for intents and identity management.
- `image/`: OCI image definition (Containerfile) and system configuration files.
- `docs/`: Extensive documentation (Source of Truth: `docs/lifeos-ai-distribution.md`).

---

## Building and Running
The project uses a `Makefile` for common development tasks.

### Core Commands
- **Set up environment:** `make dev-setup` (installs required Rust tools and pre-commit hooks).
- **Build everything:** `make build` (builds CLI and Daemon in release mode).
- **Build CLI only:** `make build-cli`.
- **Build Daemon only:** `make build-daemon`.
- **Build OCI Image:** `make docker` (requires `podman`).
- **Run CLI (dev):** `make run-cli` or `cd cli && cargo run -- [args]`.
- **Run Daemon (dev):** `make run-daemon` or `cd daemon && cargo run --all-features`.
- **Clean artifacts:** `make clean`.

### Testing and Validation
- **Run all tests:** `make test`.
- **CLI tests:** `make test-cli`.
- **Daemon tests:** `make test-daemon`.
- **CI Checks:** `make ci` (runs linting, tests, and security audits).

---

## Development Conventions

### Coding Standards
- **Language:** Rust for all core system components. Follow idiomatic Rust patterns.
- **Formatting:** Always run `make fmt` before committing. CI enforces `fmt-check`.
- **Linting:** Clippy must pass without warnings (`make lint`).
- **Error Handling:** Use `anyhow` for application-level errors and `thiserror` for library-level errors.

### Project Workflow
- **Immutability:** Assume `/usr` is read-only. Persistent state should go to `/var`, `/etc`, or `/home`.
- **Security First:** Never log or commit secrets. Use the `life-id` system for agent capabilities.
- **Documentation:** Keep the documentation in `docs/` updated with any architectural changes.
- **Testing:** Every new feature or bug fix must include corresponding tests. Integration tests are preferred for end-to-end flows.

### AI Integration
- LifeOS uses a "Biological Model" (Soul, Skills, Workplace, Agents).
- All AI actions must go through the **Intent Bus** (`life intents`) for auditability and safety.
- Local inference is prioritized. Use `llama-server` API on `127.0.0.1:8082`.

---

## Key Files & Directories
- `Cargo.toml`: Workspace configuration.
- `Makefile`: Entry point for build/test automation.
- `cli/src/commands/`: Implementation of `life` subcommands.
- `daemon/src/`: Core logic for `lifeosd`.
- `docs/lifeos-ai-distribution.md`: Comprehensive product and architectural specification.
- `image/Containerfile`: Defines the system image build process.
