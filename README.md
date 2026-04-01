# LifeOS

**AI-native Linux distribution built on Fedora bootc (immutable) with COSMIC Desktop.**

Your personal AI assistant **Axi** lives at the OS level — local inference, encrypted memory, voice, vision, autonomous execution, and privacy by default. No cloud required.

## What Makes LifeOS Different

- **IS the OS** — not an app inside an OS. Full access to kernel, systemd, GPU, hardware
- **Local AI first** — Qwen3.5-4B via llama.cpp, runs on consumer GPUs (4GB+ VRAM) or CPU-only
- **Privacy by default** — AES-GCM-SIV encrypted memory, machine-derived keys, data never leaves the device
- **Immutable + rollback** — bootc atomic updates, if AI breaks something, rollback in seconds
- **53 MCP tools** — AI controls windows, apps, clipboard, browser, LibreOffice, COSMIC desktop, accessibility trees
- **13+ LLM providers** — privacy-aware routing with automatic data sensitivity classification
- **Multi-channel** — Telegram, Slack, Discord, voice, desktop overlay
- **Self-healing** — 5-layer reliability: watchdog, sentinel, circuit breaker, safe mode, config rollback
- **Zero-config security** — CIS Benchmark-level hardening: firewalld, auditd, DNS-over-TLS, SSH, AIDE, kernel hardening
- **GPU Game Guard** — auto-offloads AI from GPU when gaming, restores when done

## Quick Start

```bash
make build      # Build CLI + daemon (Rust)
make test       # Run 341 tests
make lint       # Clippy + fmt
```

## Repository Layout

```
lifeos/
├── cli/        # `life` command-line tool (Rust)
├── daemon/     # `lifeosd` system daemon (100+ modules, 341 tests)
├── image/      # Containerfile + system files for bootc OS image
├── scripts/    # Build, CI, icon generation, verification scripts
├── docs/       # Strategy, architecture, operations, research
├── evidence/   # Phase closeout evidence (auditable history)
└── contracts/  # JSON schemas for intents and identity
```

## Documentation

All documentation is organized in [`docs/`](docs/README.md):

| Topic | Location |
|-------|----------|
| Strategy & roadmap | `docs/strategy/` |
| Architecture & specs | `docs/architecture/` |
| Operations & runbooks | `docs/operations/` |
| User guides | `docs/user/` |
| Branding & design | `docs/branding/` |
| Privacy analysis | `docs/privacy/` |
| Research | `docs/research/` |

## Tech Stack

- **Language:** Rust 2021 (daemon + CLI)
- **OS Base:** Fedora bootc (immutable, OCI-based)
- **Desktop:** COSMIC (System76) on Wayland
- **AI Runtime:** llama.cpp / llama-server
- **Database:** SQLite with WAL + sqlite-vec for embeddings
- **API:** Axum REST + WebSocket on localhost:8081
- **Protocols:** MCP (Model Context Protocol), AT-SPI2, D-Bus, CDP

## Author

Created by **Héctor Martínez Reséndiz** — [hectormr.com](https://hectormr.com)

## License

- **Daemon & CLI:** Apache-2.0
- **OS Image:** GPL-3.0
