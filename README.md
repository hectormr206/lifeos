# LifeOS

AI-native Linux distribution built on Fedora bootc (immutable) with COSMIC Desktop. Your personal AI assistant **Axi** lives at the OS level — voice, vision, memory, autonomous execution, and privacy by default.

## What Makes LifeOS Different

- **IS the OS** — not an app inside an OS. Access to kernel, systemd, GPU, hardware
- **Immutable + rollback** — bootc atomic updates, if AI breaks something, rollback in seconds
- **Privacy first** — local LLM (Qwen3.5-4B), 13+ cloud providers with sensitivity routing
- **24/7 assistant** — Telegram, Slack, Discord, WhatsApp, Matrix, Signal, voice, desktop overlay
- **GPU Game Guard** — auto-offloads AI from GPU when gaming, restores when done

## Quick Start

```bash
make build      # Build CLI + daemon
make test       # Run 309 tests
make lint       # Clippy + fmt
```

## Repository Layout

```
lifeos/
├── cli/        # `life` command-line tool
├── daemon/     # `lifeosd` system daemon (50+ modules, 309 tests)
├── image/      # Containerfile + system files for bootc image
├── scripts/    # Build, CI, icon generation, verification scripts
├── docs/       # Organized documentation (see docs/README.md)
├── evidence/   # Phase closeout evidence (auditable history)
├── contracts/  # JSON schemas for intents and identity
├── CLAUDE.md   # Instructions for Claude Code
├── GEMINI.md   # Instructions for Gemini
└── AGENTS.md   # Quick onboarding for any AI agent
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

## License

Proprietary — Hector Martinez (hectormr.com)
