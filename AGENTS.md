# Repository Guidelines

## Project Overview
LifeOS is a Rust workspace for an AI-focused operating system with three crates:
- **cli/** (`life` binary): Command-line interface for user interaction
- **daemon/** (`lifeosd` binary): Background service with REST API and D-Bus IPC
- **tests/**: Integration test crate

## Project Structure
```
lifeos/
├── cli/                    # life binary
│   ├── src/
│   │   ├── main.rs         # Entry point, clap setup
│   │   ├── lib.rs          # Module exports
│   │   ├── commands/       # CLI subcommands (init, status, etc.)
│   │   ├── config/         # Configuration management
│   │   └── daemon_client/  # Daemon IPC client
│   └── Cargo.toml
├── daemon/                 # lifeosd binary
│   ├── src/
│   │   ├── main.rs         # Daemon entry point
│   │   ├── api/            # REST API (axum + utoipa)
│   │   ├── ai.rs           # AI/LLM integration
│   │   ├── health.rs       # Health monitoring
│   │   ├── updates.rs      # Update management
│   │   └── telemetry.rs    # Telemetry subsystem
│   └── Cargo.toml
├── tests/                  # Integration tests
│   └── integration/main.rs
├── contracts/              # JSON schemas and API contracts
├── image/                  # OCI container image
├── files/                  # Systemd units, default configs, desktop assets
├── scripts/                # Python automation scripts
├── security/               # CVE policies and waivers
├── docs/                   # Extended documentation
└── Makefile               # Build orchestration
```

## Build, Test, and Development Commands

### Build Commands
```bash
# Build all (release)
make build

# Build specific component
cd cli && cargo build --release
cd daemon && cargo build --release --all-features

# Debug build
make debug

# Run CLI directly
cd cli && cargo run -- <args>

# Run daemon with all features
cd daemon && cargo run --all-features
```

### Test Commands
```bash
# Run all tests
make test

# Run tests for specific component
make test-cli
make test-daemon
make test-integration

# Run a SINGLE test (IMPORTANT)
cd cli && cargo test <test_name> --all-features
cd daemon && cargo test <test_name> --all-features

# Example: Run specific test
cd cli && cargo test test_default_config --all-features

# Run test with output visible
cd cli && cargo test <test_name> --all-features -- --nocapture

# Run tests with coverage (uses tarpaulin)
make test-coverage

# Security regression tests
bash tests/security_tests.sh  # Set LIFEOS_DAEMON_BIN for custom binaries
```

### Lint Commands
```bash
# Run all linting (fmt check + clippy)
make lint

# Format code
make fmt
# Or directly:
cd cli && cargo fmt
cd daemon && cargo fmt

# Check formatting without changes
make fmt-check

# Clippy (warnings are errors!)
cd cli && cargo clippy --all-features -- -D warnings
cd daemon && cargo clippy --all-features -- -D warnings
```

### CI Commands
```bash
# Run full CI locally before pushing
make ci  # Runs: fmt-check, lint, test, audit

# Security audit
make audit

# Docker build
make docker-build
```

## Coding Style & Naming Conventions

### Formatting
- Rust 2021 edition across all crates
- Uses **default rustfmt** (no custom config) - 4-space indentation
- Always run `cargo fmt` before committing

### Linting
- Uses **default clippy** with `-D warnings` (all warnings are errors)
- Fix ALL clippy warnings before submitting

### Naming Conventions
| Element | Convention | Example |
|---------|------------|---------|
| Modules/files | snake_case | `update_scheduler.rs`, `daemon_client` |
| Functions | snake_case | `load_config`, `execute`, `check_health` |
| Variables | snake_case | `config_path`, `health_monitor` |
| Types/structs/enums | PascalCase | `LifeConfig`, `AiManager`, `UpdateResult` |
| Constants | UPPER_SNAKE_CASE | `DEFAULT_PORT`, `MAX_RETRIES` |
| CLI subcommands | kebab-case | `first-boot`, `computer-use` |

### Import Organization
```rust
// External crates first (alphabetical)
use anyhow::Result;
use clap::{Args, Parser, Subcommand};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

// Standard library
use std::path::PathBuf;
use std::sync::Arc;

// Internal modules (crate::)
use crate::config;
use crate::system;
```

### Type Patterns
```rust
// Use anyhow::Result for all fallible functions
pub async fn execute(args: StatusArgs) -> anyhow::Result<()> { }

// Struct derives - be explicit about what you need
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LifeConfig { }

// Clap args use Args derive
#[derive(Args, Default)]
pub struct StatusArgs { }
```

### Error Handling
- Use `anyhow` throughout (not `thiserror`)
- Use `?` operator for error propagation
- Use `anyhow::bail!` for early termination with error

```rust
// Error creation
anyhow::bail!("Failed to create config directory: {}", e);

// Error wrapping with context
let config = load_config().map_err(|e| {
    anyhow::anyhow!("Could not load config: {}", e)
})?;

// Option handling
let channel = config
    .as_ref()
    .map(|c| c.updates.channel.clone())
    .unwrap_or_else(|| "stable".to_string());
```

### Async Patterns
```rust
// Tokio runtime with #[tokio::main]
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // ...
}

// Shared state with Arc<RwLock<T>>
pub struct DaemonState {
    pub system_monitor: Arc<RwLock<SystemMonitor>>,
    pub health_monitor: Arc<HealthMonitor>,
}

// Spawn background tasks
let health_handle = tokio::spawn(run_health_checks(state.clone()));
```

## Testing Guidelines

### Test File Convention
- Unit tests: `src/module_tests.rs` (separate file with `_tests` suffix)
- Integration tests: `tests/integration/main.rs`
- Name tests descriptively with `test_` prefix
- Target at least 70% coverage on new code

### Test Pattern
```rust
// In src/config/tests.rs
#[cfg(test)]
mod tests {
    use super::super::*;  // Import parent module
    use tempfile::NamedTempFile;

    #[test]
    fn test_default_config() {
        let config = LifeConfig::default();
        assert_eq!(config.version, "1");
    }

    #[test]
    fn test_load_config_from_invalid_toml() {
        let result = load_config_from(invalid_path);
        assert!(result.is_err());
    }
}

// CLI parsing tests use clap::Parser
#[test]
fn test_cli_parses_init_command() {
    let cli = Cli::parse_from(["life", "init"]);
    match cli.command {
        Commands::Init(_) => (),
        _ => panic!("Expected Init command"),
    }
}
```

## Daemon Features
```toml
[features]
default = ["dbus", "http-api"]
dbus = ["zbus"]
http-api = ["axum"]
ui-overlay = ["gtk4", "glib"]
```

Always use `--all-features` when building/testing the daemon.

## Key Dependencies
| Purpose | Crate |
|---------|-------|
| CLI parsing | clap |
| Async runtime | tokio (full features) |
| Serialization | serde (derive) |
| Error handling | anyhow |
| HTTP API | axum + utoipa (OpenAPI) |
| D-Bus IPC | zbus |
| System info | sysinfo |
| Testing mocks | mockall |
| Coverage | tarpaulin |

## Commit & Pull Request Guidelines

### Commit Messages
Follow Conventional Commits, matching existing history:
- `feat(phase2): add new AI manager integration`
- `fix(scripts): correct update path resolution`
- `ci(phase2): add coverage reporting`
- `docs: update installation instructions`

Keep commit messages imperative and scoped.

### Before Pushing
1. `cargo fmt` in both cli/ and daemon/
2. `make lint` - fix ALL warnings
3. `make test` - all tests must pass
4. `make audit` - no security vulnerabilities
5. `pre-commit run --all-files`

Or simply: `make ci`

### PR Requirements
- Clear summary of behavior changes
- Linked issue(s) or rationale
- Test evidence (commands run and results)
- Screenshots/log snippets for UI, workflow, or ops-facing changes
