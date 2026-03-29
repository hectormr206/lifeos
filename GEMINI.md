# GEMINI.md — LifeOS Context

LifeOS — AI-native Linux distribution on Fedora bootc. Rust CLI (`life`) + daemon (`lifeosd`) + COSMIC Desktop.

## Build & Test

```bash
make build          # Build all (release)
make test           # All tests
make lint           # Clippy + fmt check
make ci             # Full CI locally
cargo test -p lifeosd test_name   # Single test
```

## Key Conventions

- **Rust 2021**, `anyhow` for errors, `tokio` async runtime
- **Formatting:** `cargo fmt` before commit, clippy with `-D warnings`
- **Immutability:** `/usr` is read-only. State goes to `/var/`, `/etc/`, `/home/`
- **No dead code:** Every new module must be wired to Telegram/API/event bus/supervisor
- **AI:** Local `llama-server` on `:8082` (Qwen3.5-4B). LLM router with 13+ providers

## Find Documentation

All docs are organized in `docs/`. Read `docs/README.md` for the full index.

| Need | Location |
|------|----------|
| Architecture & specs | `docs/architecture/` |
| Strategy & phases | `docs/strategy/` |
| Operations & runbooks | `docs/operations/` |
| Branding & icons | `docs/branding/` |
| Privacy analysis | `docs/privacy/` |

## Key Files

| File | Purpose |
|------|---------|
| `daemon/src/main.rs` | Daemon entry, background tasks, signal handling |
| `daemon/src/api/mod.rs` | REST API (Axum) — 224+ route handlers |
| `daemon/src/llm_router.rs` | Multi-provider LLM routing with privacy filtering |
| `daemon/src/telegram_tools.rs` | Agentic chat loop + 33 tools |
| `daemon/src/supervisor.rs` | Autonomous task execution |
| `image/Containerfile` | OS image build definition |
