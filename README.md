# LifeOS

> A private AI life companion that runs entirely on your own laptop. No cloud, no accounts, no telemetry — your voice, your screen, your health, your finances, your relationships never leave your machine.

![status](https://img.shields.io/badge/status-alpha-ffaa33)
![python](https://img.shields.io/badge/python-3.12-3776ab)
![tests](https://img.shields.io/badge/tests-945-22cc55)
![license](https://img.shields.io/badge/license-MIT-22cc55)

LifeOS is two things working together:

- **Axi** — a voice-and-vision AI assistant. It listens through your microphone, sees your screen and camera, transcribes and remembers, runs a local LLM "brain", and frees your GPU with one click when you want to game.
- **The life companion** — a set of personal-life domains (health, finance, reminders, exercise, relationships, and more) that share one local store, surface cross-domain correlations, and push you a daily digest.

Everything runs on a single laptop against **100% local models**. Nothing is sent to the internet by default.

---

## Why this exists

Personal AI assistants today are cloud services: your most intimate data — what you say, what's on your screen, your health and money — is uploaded, stored, and mined by someone else. LifeOS is built on the opposite premise: **digital sovereignty**. The assistant that knows the most about you should run on hardware *you* own, with data *you* control, on software *you* can read and change.

- **Local-first** — the LLM, speech-to-text, text-to-speech, and OCR all run on-device.
- **Privacy by default** — audio, conversations, meetings, and your life-companion records all stay on your disk, and both data stores (the assistant's memory and the life domains) are encrypted at rest with SQLCipher.
- **Yours to inspect** — open source (MIT), no hidden services, no accounts.

This is the through-line of the project and it has never changed (see [The pivot](#project-status--the-pivot) for how the *implementation* evolved).

---

## What works today

Axi (voice / vision / brain):

| Capability | How it works |
|---|---|
| 🎤 **Voice** | Push-to-talk dictation to clipboard/auto-type; ask-about-my-screen and ask-about-my-camera; voice commands |
| 🧠 **Brain** | Qwen3.6-35B-A3B (MoE) on GPU via llama.cpp, with `--cpu-moe` offload so it fits a 12 GB card; in-app selector for multiple 2026 multimodal models with per-model parameter tuning |
| 🌐 **Live interpreter** | Real-time EN→ES speech interpreting (Whisper → LLM → Piper), sub-3s latency |
| 🎙️ **Meetings** | Dual capture (mic + system audio), incremental transcription, speaker diarization, LLM summaries |
| 🧩 **Memory** | SQLite + FTS5 full-text search over conversations, with fact extraction and a memory graph |
| 🎮 **Game Guard** | Releases ~12 GB of VRAM on click and restores it when you're done |
| 📊 **Dashboard** | Local FastAPI + Alpine.js web app, installable as a PWA, reachable from your phone over your own VPN |

The life companion (personal domains, all in the dashboard):

| Domain | What it tracks / does |
|---|---|
| ❤️ **Health** | Log entries and trends |
| 💸 **Finance** | Entries, summaries, and guided reflection on impulsive spending |
| ⏰ **Reminders** | Scheduled, with web-push notifications (VAPID) |
| 🏃 **Exercise** | Sessions and summaries |
| 👥 **Relationships** | People and interactions you want to stay on top of |
| 🧘 **Spirituality / Posture / Learning** | Lightweight tracking for the rest of life |
| 🔗 **Insights** | Cross-domain **correlations** with drill-down evidence (e.g. *poor sleep → impulsive purchases*), surfaced in a daily/weekly digest |

> Tested: **945 tests** (375 for Axi, 570 for the companion).

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
  │   /insights /meetings /memory /graph /models /config …        │
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

- **MCP tool surface** — expose LifeOS capabilities to other local agents via the Model Context Protocol.
- **OS-level control** — let the assistant act on the desktop (open apps, manage windows) safely.
- **Multi-device sync** — encrypted peer-to-peer sync across the user's own devices (still no cloud).
- **Beyond CachyOS** — broaden tested support to other Arch-based and non-KDE setups.

---

## Repository layout

```
lifeos/
├── install.sh          # one-command installer (CachyOS reference)
├── axi/                # voice/vision assistant, dashboard, systemd units
│   ├── src/axi/        # daemon, brain, whisper, dashboard, doctor …
│   ├── scripts/        # axi-toggle, axi-check, axi-llama-launch …
│   └── systemd/        # user services
└── lifeos/             # life-companion core (health, finance, insights …)
    └── src/lifeos/     # domains, scheduler, encrypted store, correlations
```

---

## License

MIT © 2026 Héctor Martínez Reséndiz — see [axi/LICENSE](axi/LICENSE).
