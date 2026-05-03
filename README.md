# LifeOS

![Beta](https://img.shields.io/badge/status-beta-orange?style=for-the-badge) ![Version](https://img.shields.io/badge/version-0.7.17-teal?style=for-the-badge)

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
- **Interaction surfaces** - SimpleX is the privacy-first remote channel (`simplex_bridge.rs` + `simplex-chat.service`, E2E encrypted, no phone number required); the local dashboard (`http://127.0.0.1:8081/dashboard`) is the in-host web UI (`integrated in repo`); local voice and broader desktop surfaces exist but some remain experimental or are still being re-validated
- **Voice: Kokoro-82M** (`integrated in repo`) - 50+ voices, Apache 2.0, CPU-only inference via `lifeos-tts.service` on `:8084`; dashboard voice selector lets users pick and preview any voice; SimpleX voice replies send OGG attachments when you send Axi a voice note
- **Reliability layers** (`integrated in repo`) - watchdog, sentinel, circuit breaker, safe mode, and config rollback exist, but not every repair flow is equally mature
- **Security baseline** (`integrated in repo`) - the image ships firewalld, auditd, DNS-over-TLS, SSH hardening, and related guardrails; broader hardening claims should be read as a baseline, not as a finished benchmark story. A read-only `GET /api/security/alerts` endpoint (localhost-only, no auth) exposes the in-memory ring buffer of recent security monitor events for the dashboard
- **GPU Game Guard with per-profile model swap** (`validated on host`) - when a game grabs the GPU, lifeosd swaps Axi from Qwen3.5-9B (full GPU) to Qwen3.5-4B in CPU **keeping the same 131K-token context** (on 64GB+ RAM hosts) so tool-calling and long-conversation memory stay intact instead of degrading to a 4K fallback. The runtime profile is auto-tuned per hardware via a microbenchmark; the 9B+GPU profile is restored when the game closes
- **Flatpak auto-update** (`validated on host`) - updates run automatically with guards for active gaming sessions, battery level, and metered network connections
- **Nvidia GL extension auto-sync** (`validated on host`) - host driver version is detected on boot and the matching GL extension layer is applied automatically; no manual intervention after driver updates
- **Automated maintenance cleanup** (`integrated in repo`) - scheduled cleanup of podman image layers, Rust build cache, and orphaned Flatpak runtimes to keep disk usage in check
- **Speaker identification** (`experimental / partial`) - WeSpeaker ONNX model is integrated for speaker diarization; end-to-end product path is still being completed
- **Web search tool** (`integrated in repo`) - Axi's `web_search` tool queries Brave Search (free tier, ~2,000 queries/month at <https://api.search.brave.com/app/subscriptions/subscribe>). Configure via env `BRAVE_SEARCH_API_KEY=<token>` or `/var/lib/lifeos/config-checkpoints/working/config.toml` under `[web_search] brave_api_key = "..."`. Works on all channels including SimpleX.
- **Real persistent memory (no silent forgetting)** (`integrated in repo`) - tool calls travel via the OpenAI-compatible `tools` channel (not text scanning), so Axi's persistence claims are tied to actual SQL writes. Past assistant narratives that say "ya guardé" but never invoked a tool are sanitized in the conversation context to prevent the model from deferring future tool calls based on stale claims. End-to-end test: `health_facts` row appears in `memory.db` when you tell Axi a permanent fact like "soy alérgico a la X"
- **Intent inference and ambiguity guard** (`integrated in repo`) - Axi infers when to record from data shape, not from keyword triggers. "116/78 59 pulsos" → three `vital_record` calls (sys/dia/heart_rate). "Soy alérgico a la lactosa" → `health_fact_add`. Ambiguous messages ("sentí una bola en el cuello") prompt Axi to ask before recording, instead of either silently saving a worry as a medical fact or ignoring it entirely
- **Life Areas backends** (`integrated in repo`) - first-class domains for **Freelance** (clientes/sesiones/facturas/tarifas), **Finanzas**, **Vehículos**, **Viajes**, **Proyectos** — each with schemas, LLM tools, and REST endpoints. Freelance has a full dashboard tab; the others ship backend-only for now
- **User-configurable AI context size** (`integrated in repo`) - the dashboard exposes `LIFEOS_AI_CTX_SIZE` so you can pin the llama.cpp ctx (default 128K) and the daemon honors it across restarts and benchmark cycles. The auto-benchmarker still tunes threads/batch/parallel per hardware
- **VPS-first deploy with layer deltas** (`developer convenience`) - solo dev workflow: `~/bin/vps-prepare-laptop-update.sh` syncs GHCR → VPS local registry, `~/bin/vps-deploy-to-laptop.sh` makes the laptop pull only changed layers via WireGuard. Typical update: ~20 seconds vs ~8 minutes with the previous tar-archive flow. Not part of the bootc image — these are personal scripts in the maintainer's `~/bin/`

## Quick Start

```bash
make build      # Build CLI + daemon (Rust)
make test       # Run repository test suite
make lint       # Clippy + fmt
```

### AI Tools

Axi ships with an agentic tool set that works across all channels (dashboard,
SimpleX, Telegram). A few highlights you'll likely want on from day one:

- **`web_search`** — live web results via Brave Search (free tier,
  ~2,000 queries/month). Requires an API key; grab one at
  <https://api.search.brave.com/app/subscriptions/subscribe> and set it
  with either:

  ```bash
  export BRAVE_SEARCH_API_KEY=<tu_token>
  ```

  or in `/var/lib/lifeos/config-checkpoints/working/config.toml`:

  ```toml
  [web_search]
  brave_api_key = "<tu_token>"
  ```

  The daemon reloads the key with a short TTL (≈60 s), so dashboard
  updates surface without a restart.

- **`screenshot`**, **`run_command`**, **`browser_navigate`**, **`cron`**,
  and ~15 more — see `daemon/src/axi_tools.rs` for the full list.

See the full feature matrix above and the operations docs under
[`docs/operations/`](docs/operations/) for per-channel behavior.

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
| Update check/stage/apply flow | `docs/operations/update-flow.md` |
| Developer workstation setup | `docs/operations/developer-bootstrap.md` |
| Contributing | `CONTRIBUTING.md`, `docs/contributor/` |
| Branding & design | `docs/branding/` |
| Privacy analysis | `docs/privacy/` |
| Research | `docs/research/` |

## Tech Stack

- **Language:** Rust 2021 (daemon + CLI)
- **OS Base:** Fedora bootc (immutable, OCI-based) + per-service podman Quadlets
- **Desktop:** COSMIC (System76) on Wayland
- **AI Runtime:** llama.cpp / llama-server
- **TTS:** Kokoro-82M (Apache 2.0) — runs as a podman Quadlet (`lifeos-tts.service`) pulling `ghcr.io/hectormr206/lifeos-tts:stable`, exposes `127.0.0.1:8084`
- **Service architecture:** lean bootc host + ghcr.io side images per service
  (`lifeos-tts`, `lifeos-llama-embeddings`, `lifeos-lifeosd`, `lifeos-simplex-bridge`).
  See `docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md`.
- **Database:** SQLite with WAL + sqlite-vec for embeddings
- **API:** Axum REST + WebSocket on localhost:8081
- **Protocols:** MCP (Model Context Protocol), AT-SPI2, D-Bus, CDP

## Author

Created by **Héctor Martínez Reséndiz** — [hectormr.com](https://hectormr.com)

## License

- **Daemon & CLI:** Apache-2.0
- **OS Image:** GPL-3.0
