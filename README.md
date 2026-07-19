# LifeOS

> **LifeOS** is a private, local-first life platform that runs entirely on your own laptop. **Axi** — a Mexican axolotl — is the AI agent that lives inside it: it sees, listens, remembers, and reasons across everything LifeOS holds. No cloud, no accounts, no telemetry — your voice, your screen, your health, your finances, your relationships never leave your machine.

![status](https://img.shields.io/badge/status-alpha-ffaa33)
![python](https://img.shields.io/badge/python-3.12-3776ab)
![tests](https://img.shields.io/badge/tests-3548-22cc55)
![license](https://img.shields.io/badge/license-AGPL--3.0-22cc55)

Think of it as a platform and its agent:

- **LifeOS — the platform.** Your life, structured and sovereign: health, finance, relationships, reminders, exercise, and memory, all in one local encrypted store. It turns what you say into structured records, surfaces cross-domain correlations, and pushes a daily digest — with a dashboard to see it all. This is the *where* — where your life lives.
- **Axi — the agent.** The Mexican axolotl that lives inside LifeOS: voice and vision, a local LLM "brain", and a real-time interpreter. Axi is the *who* — what you talk to. It reasons across everything LifeOS holds to answer you, and frees your GPU with one click when you want to game.

> **Install LifeOS. Talk to Axi.**

Everything runs on a single laptop against **100% local models**. Nothing is sent to the internet by default.

---

## Why this exists

Personal AI assistants today are cloud services: your most intimate data — what you say, what's on your screen, your health and money — is uploaded, stored, and mined by someone else. LifeOS is built on the opposite premise: **digital sovereignty**. The assistant that knows the most about you should run on hardware *you* own, with data *you* control, on software *you* can read and change.

- **Local-first** — the LLM, speech-to-text, text-to-speech, and OCR all run on-device.
- **Privacy by default** — audio, conversations, meetings, and your life-companion records all stay on your disk, and both data stores (the assistant's memory and the life domains) are encrypted at rest with SQLCipher.
- **Yours to inspect** — open source (AGPL-3.0-or-later), no hidden services, no accounts.

This is the through-line of the project and it has never changed (see [The pivot](#project-status--the-pivot) for how the *implementation* evolved).

---

## What works today

### Axi — the agent (what you talk to)

| Capability | How it works |
|---|---|
| 🎤 **Voice** | Push-to-talk dictation to clipboard/auto-type; hands-free wake word ("Axi, …") — no hotkey needed; ask-about-my-screen and ask-about-my-camera; voice commands |
| 🧠 **Brain** | Qwen3.6-35B-A3B (MoE) on GPU via llama.cpp, with `--cpu-moe` offload so it fits a 12 GB card; in-app selector for multiple 2026 multimodal models with per-model parameter tuning |
| 🌐 **Live interpreter** | Real-time EN→ES speech interpreting (Whisper → LLM → Piper), sub-3s latency |
| 🎙️ **Meetings** | Dual capture (mic + system audio), incremental transcription, speaker diarization, LLM summaries |
| 🧩 **Memory & recall** | A universal knowledge graph: everything you tell Axi — people, meds, conditions, doctors, dates, preferences — becomes typed nodes and edges. Chat answers cross-reference it ("who diagnosed my hypertension and what was prescribed?"), and a natural-language "forget" deletes with confirmation (including a subset by number). The durable, encrypted store underneath belongs to LifeOS. |
| 🌍 **Web & briefings** | The brain searches the web on its own when a question needs it. Scheduled agentic briefings ("tráeme las noticias cada mañana a las 9") search on schedule, curate with real cited links, and push to your phone with deep links into a briefings panel |
| 🎮 **Game Guard** | Releases ~12 GB of VRAM on click and restores it when you're done |

### LifeOS — the life platform (what it keeps)

| Domain | What it tracks / does |
|---|---|
| ❤️ **Health** | Log entries and trends |
| 💸 **Finance** | Entries, summaries, and guided reflection on impulsive spending |
| ⏰ **Reminders** | Scheduled, with web-push notifications (VAPID) |
| 🏃 **Exercise** | Sessions and summaries |
| 👥 **Relationships** | People and interactions you want to stay on top of |
| 🧘 **Spirituality / Posture / Learning** | Lightweight tracking for the rest of life |
| 🔗 **Insights** | Cross-domain **correlations** with drill-down evidence (e.g. *poor sleep → impulsive purchases*) |
| 🌙 **Nightly digest** | A daily push summary narrated by the local LLM from deterministically computed facts (code computes the numbers, the model only writes — no hallucinated stats), including knowledge-graph observations, delivered at an adaptive hour learned from your median bedtime |
| 📊 **Dashboard** | The local web app (FastAPI + Alpine.js, installable as a PWA) where your whole life lives — mobile bottom tab bar, desktop sidebar, and a living Axi mascot that shows thinking/offline state in the dashboard and as the tray icon — reachable from your phone over your own VPN |
| 🛡️ **Reliability** | Single-writer architecture for the encrypted store (no multi-process write corruption), data-loss-guarded rotating backups, and web push with correct deep links over your own VPN |

> All domains parse both **English and Spanish** utterances on a fast deterministic path — "blood pressure 120 over 80", "spent 250 on groceries", "remind me tomorrow at 3pm…" all land as structured records without touching the LLM.

> Tested: **3,548 tests** (2,409 for Axi, 1,139 for LifeOS).

---

## How it works

```
  ┌─────────────────────────────────────────────────────────────┐
  │  axi-tray (KDE)  ── Super+Space ──▶  axi-voice (daemon)       │
  │                                       ├─ dictation → clipboard │
  │                                       ├─ ask-screen → vision   │
  │                                       └─ ask-camera → eyes     │
  │                                            │                   │
  │   Whisper (STT) ──▶  llama-server (LLM brain)  ──▶  Piper (TTS)│
  └─────────────────────────────────────────────────────────────┘
  ┌─────────────────────────────────────────────────────────────┐
  │  axi-dashboard (FastAPI, 127.0.0.1:8081, PWA)                 │
  │   /chat /health /finance /reminders /exercise /relationships  │
  │   /insights /briefings /meetings /memory /graph /models …     │
  │        │                                                      │
  │   lifeos core: one encrypted SQLite store + scheduler         │
  │   → daily digest, cross-domain correlations, web push         │
  └─────────────────────────────────────────────────────────────┘
```

All inference runs locally: `faster-whisper` (large-v3-turbo) for speech, `llama.cpp` + Qwen for the brain, Piper for speech, Tesseract for OCR. Both stores — the assistant's memory and the life-companion data — are encrypted at rest with SQLCipher (AES-256) under your home directory.

---

## Requirements

LifeOS is **alpha**: robust enough for daily use (the author runs it every day), but currently single-user and validated on one platform.

- **OS**: Arch-based Linux with KDE Plasma + PipeWire. **CachyOS** is the reference and only tested target.
- **GPU**: NVIDIA with CUDA, **12 GB+ VRAM** (RTX 5070 Ti Laptop reference). The brain is a MoE model offloaded with `--cpu-moe`, so it fits 12 GB.
- **Disk**: ~35 GB for the default model set + virtualenv.
- **Python**: 3.12 (provided automatically by `uv`).

---

## Install

A single idempotent installer handles system packages, the Python environment, model downloads (with explicit consent for the large one), and the systemd user services:

```bash
git clone https://github.com/hectormr206/lifeos.git ~/LifeOS/lifeos
cd ~/LifeOS/lifeos
./install.sh
```

> The repository must live at `~/LifeOS/lifeos` — the systemd services reference that path.

Useful modes:

```bash
./install.sh --check          # verify the system, change nothing
./install.sh --skip-models    # install software + services without downloading models
./install.sh --help           # all options
```

After install, bind a global shortcut (e.g. Super+Space) to `axi/scripts/axi-toggle` and open the dashboard at <http://127.0.0.1:8081>. Re-check health any time with `./install.sh --check` or `axi/scripts/axi-check`.

---

## Privacy & data ownership

- **No network egress for inference** — STT, the LLM, TTS, and OCR are all local binaries/models.
- **Data at rest is encrypted** — both SQLite stores use SQLCipher (AES-256); the keys stay on your machine. See [axi/docs/threat-model.md](axi/docs/threat-model.md).
- **The dashboard binds to `127.0.0.1` by default** — no auth, no TLS, because it never leaves the loopback interface unless *you* opt in to exposing it over a private VPN (Tailscale/WireGuard).
- **No accounts, no telemetry, no phone-home.**

---

## Project status & the pivot

LifeOS began as an immutable Linux distribution (a `bootc` image with a Rust daemon and many domain modules). That design proved too slow to iterate on: every change meant rebuilding and reflashing an OS image. So the project **pivoted to what it is now** — an installable Python application you can run on an existing Arch/CachyOS system today, while keeping the original vision (digital sovereignty, privacy-first, 100% local AI) completely intact.

The earlier Rust domains are preserved as `archive/*` git tags and can be revived if useful. What ships in `main` is the working, tested, daily-driven application described above.

---

## Roadmap

Planned, **not yet present**:

- **MCP tool surface** — *v1 shipped*: a local [MCP](https://modelcontextprotocol.io) server (`axi.mcp_server`) exposes read + additive-write tools over stdio so other local agents (e.g. Claude Code) can work with your memory, reminders, finance, and health. See [axi/docs/mcp.md](axi/docs/mcp.md). Expanding to insights/digest and per-tool consent next.
- **OS-level control** — let the assistant act on the desktop (open apps, manage windows) safely.
- **Multi-device sync** — encrypted peer-to-peer sync across the user's own devices (still no cloud).
- **Beyond CachyOS** — broaden tested support to other Arch-based and non-KDE setups.

---

## Repository layout

```
lifeos/
├── install.sh          # one-command installer (CachyOS reference)
├── axi/                # Axi — the agent: voice/vision, brain, dashboard, systemd units
│   ├── src/axi/        # daemon, brain, whisper, dashboard, doctor …
│   ├── scripts/        # axi-toggle, axi-check, axi-llama-launch …
│   └── systemd/        # user services
└── lifeos/             # LifeOS — the life platform core (health, finance, insights …)
    └── src/lifeos/     # domains, scheduler, encrypted store, correlations
```

---

## License

AGPL-3.0-or-later © 2026 Héctor Martínez Reséndiz — see [LICENSE](LICENSE).

Running LifeOS over a network (e.g. the multi-device mesh) makes it a "modified/conveyed work" under AGPL §13: if you distribute or offer it as a network service, you must offer users the corresponding source. Held under strong copyleft on purpose — the core stays free and stays open.
