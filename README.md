# LifeOS

![Beta](https://img.shields.io/badge/status-beta-orange?style=for-the-badge) ![Version](https://img.shields.io/badge/version-0.4.1-teal?style=for-the-badge)

**AI-native Linux distribution built on Fedora bootc (immutable) with COSMIC Desktop.**

> **Heads up — LifeOS is in Beta.** Things work, things break, things change. Running LifeOS on your primary machine means opting into fast iteration over long-term stability. Feedback and issue reports are welcome and actively shape the roadmap.

LifeOS is building toward an OS-level assistant named **Axi** with local inference, encrypted memory, desktop control, and privacy-first defaults.

Public docs use a simple maturity taxonomy so repo capabilities are not confused with default shipped behavior:

- **Validated on host** - integrated and observed working on a real machine recently
- **Integrated in repo** - wired in code and runtime, but not recently re-validated on a real host
- **Experimental / partial** - foundation exists, but the end-to-end product path is still incomplete
- **Shipped disabled / feature-gated** - present in repo, but not compiled or enabled by default in the standard image

LifeOS is built in Mexico and developed in the open for users, contributors, and supporters anywhere.

## What Makes LifeOS Different

- **OS-level architecture** - not just an app inside another OS; the project targets kernel, systemd, GPU, hardware, and desktop surfaces directly
- **Local AI first** (`validated on host`) - local inference via llama.cpp is part of the current real product path
- **Encrypted local memory foundations** (`integrated in repo`) - encrypted memory is a core design pillar, with public docs kept conservative about what is fully validated end-to-end today
- **Immutable + rollback base** (`integrated in repo`) - bootc-style atomic updates and rollback shape the platform direction, while install/update validation is still an active focus
- **Desktop control tooling** (`integrated in repo`) - the repo includes tools for windows, apps, clipboard, browser, LibreOffice, COSMIC desktop, and accessibility trees
- **Provider routing** (`integrated in repo`) - multiple LLM providers are wired with privacy-aware routing policies
- **Interaction surfaces** - Telegram and SimpleX are the current remote paths; SimpleX (`simplex_bridge.rs` + `simplex-chat.service`) gives Axi the same capabilities as Telegram on a privacy-first, serverless messenger (`integrated in repo`); local voice and broader desktop surfaces exist but some remain experimental or are still being re-validated
- **Reliability layers** (`integrated in repo`) - watchdog, sentinel, circuit breaker, safe mode, and config rollback exist, but not every repair flow is equally mature
- **Security baseline** (`integrated in repo`) - the image ships firewalld, auditd, DNS-over-TLS, SSH hardening, and related guardrails; broader hardening claims should be read as a baseline, not as a finished benchmark story
- **GPU Game Guard** (`validated on host`) - GPU offload policy exists and recent false positives were fixed, but it stays under ongoing validation after daemon/runtime changes
- **Flatpak auto-update** (`validated on host`) - updates run automatically with guards for active gaming sessions, battery level, and metered network connections
- **Nvidia GL extension auto-sync** (`validated on host`) - host driver version is detected on boot and the matching GL extension layer is applied automatically; no manual intervention after driver updates
- **Automated maintenance cleanup** (`integrated in repo`) - scheduled cleanup of podman image layers, Rust build cache, and orphaned Flatpak runtimes to keep disk usage in check
- **Speaker identification** (`experimental / partial`) - WeSpeaker ONNX model is integrated for speaker diarization; end-to-end product path is still being completed

## Quick Start

```bash
make build      # Build CLI + daemon (Rust)
make test       # Run repository test suite
make lint       # Clippy + fmt
```

## Repository Layout

```
lifeos/
├── cli/        # `life` command-line tool (Rust)
├── daemon/     # `lifeosd` daemon and API runtime
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
| Update channels | `docs/architecture/update-channels.md` |
| Contributing | `CONTRIBUTING.md`, `docs/contributor/` |
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
