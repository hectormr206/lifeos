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
- **No dead code:** Every new module must be wired to SimpleX/API/event bus/supervisor
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
| Developer workstation bootstrap | `docs/operations/developer-bootstrap.md` |
| Update check/stage/apply flow | `docs/operations/update-flow.md` |

## Key Services (runtime)

| Service | Address | Notes |
|---------|---------|-------|
| `lifeosd` REST API | UDS `/run/lifeos/lifeosd.sock` (machine clients) + TCP `127.0.0.1:8081` (browser) | Auth: SO_PEERCRED on UDS; `x-bootstrap-token` on TCP |
| `llama-server` | `127.0.0.1:8082` | Local LLM inference (llama.cpp) |
| `lifeos-tts` | `127.0.0.1:8084` | TTS: Kokoro-82M (Apache 2.0), 50+ voices. See [`docs/operations/tts.md`](docs/operations/tts.md) |
| `llama-embeddings` | `127.0.0.1:8083` | Semantic embeddings (nomic-embed-text-v1.5 via llama.cpp) |
| `simplex-chat` | `ws://127.0.0.1:5226` | SimpleX bridge WebSocket |

## Key Files

| File | Purpose |
|------|---------|
| `daemon/src/main.rs` | Daemon entry, background tasks, signal handling |
| `daemon/src/api/mod.rs` | REST API (Axum) — 224+ route handlers |
| `daemon/src/llm_router.rs` | Multi-provider LLM routing with privacy filtering |
| `daemon/src/axi_tools.rs` | Shared agentic chat engine + tools (used by SimpleX + dashboard) |
| `daemon/src/supervisor.rs` | Autonomous task execution |
| `desktop/src/main.rs` | Desktop companion entry: tray, wake-word, bootstrap |
| `image/Containerfile` | OS image build definition |
