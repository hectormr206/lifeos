# LifeOS / Axi

> Local-first AI personal assistant. Vive en tu laptop, no en la nube.

Axi escucha por el micrófono, ve tu pantalla y tu cámara, traduce videos en tiempo real, graba reuniones con diarización de hablantes, recuerda con búsqueda full-text, y libera VRAM con un click cuando querés jugar. Todo en una sola laptop, sin enviar nada a internet.

![status](https://img.shields.io/badge/status-alpha-ffaa33) ![python](https://img.shields.io/badge/python-3.12-3776ab) ![license](https://img.shields.io/badge/license-MIT-22cc55)

---

## Qué hace

| Capacidad | Cómo funciona |
|---|---|
| 🎤 **Voz** | Dictado, Q&A con pantalla/cámara, comandos de voz ("Axi, abre el dashboard") |
| 🧠 **Cerebro** | Qwen3.6 35B-A3B (MoE) en GPU vía llama.cpp · selector de 9 modelos multimodales 2026 · editor de 16 parámetros por modelo |
| 🌐 **Intérprete EN→ES** | Tiempo real, sub-3s de latencia: Whisper streaming + Qwen + Piper |
| 🎙️ **Reuniones** | Grabación dual (mic + sistema) · transcripción incremental · diarización (Resemblyzer / pyannote) · resúmenes generados por Qwen |
| 🧩 **Memoria** | SQLite + FTS5 · historial de conversaciones · extracción de hechos · timezone-aware |
| 🎮 **Game Guard** | Libera 12 GB de VRAM con un click; restaura al volver |
| 📊 **Dashboard** | FastAPI + Alpine.js · event log · brain metrics · daily digest · meeting search |
| 🔔 **Tray KDE** | Estado live · comandos rápidos · tooltip de ubicación de modelos |

---

## Stack

- **Voz**: faster-whisper (Whisper turbo, large-v3-turbo), Piper TTS (es_MX-claude-high)
- **Cerebro**: llama.cpp + Qwen3.6-35B-A3B (default) o cualquiera del [catálogo](src/axi/models_catalog.py)
- **Pipeline**: Python 3.12, FastAPI, SQLite + FTS5, PipeWire, KDE Plasma, systemd user units
- **Tests**: pytest (241 tests passing)

---

## Hardware target

- **GPU**: NVIDIA RTX 5070 Ti Laptop (12 GB VRAM, Blackwell sm_120). Otros 12 GB+ deberían funcionar.
- **OS**: CachyOS, Arch o Fedora con KDE Plasma + PipeWire
- **CPU**: i9-13900HX o similar (las reuniones largas usan varios cores en paralelo)

---

## Instalación

Ver [INSTALL.md](INSTALL.md) para los pasos completos (modelos, systemd units, ydotoold).

Resumen rápido:

```bash
git clone https://github.com/hectormr206/lifeos.git
cd lifeos
uv venv && uv sync

# Modelos
mkdir -p ~/LifeOS/models/Qwen3.6-35B-A3B
# Descargar Qwen3.6-35B-A3B-MXFP4_MOE.gguf + mmproj-BF16.gguf desde HF

# Systemd units (user-level, sin sudo)
cp systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now axi-voice llama-server axi-tray axi-dashboard
```

Verificá con `axi-doctor` (`scripts/axi-check`).

---

## Arquitectura

```
                      ┌──────────────────────────────────────────┐
                      │ axi-tray (KDE)                           │
                      │  ↔ Unix socket ↔                         │
                      │ axi-voice (Whisper)                      │
                      │  ├─ dictation → clipboard / type         │
                      │  ├─ ask-screen → vision → brain          │
                      │  └─ ask-camera → eyes → brain            │
                      │      ↓                                   │
                      │  llama-server (Qwen) ← HTTP              │
                      │      ↓                                   │
                      │  axi.speak → Piper TTS → speakers        │
                      └──────────────────────────────────────────┘
                      ┌──────────────────────────────────────────┐
                      │ axi-translate (interpreter mode, opt-in)│
                      │  PipeWire null-sink monitor → Whisper    │
                      │   → Qwen → Piper → speakers (ES)         │
                      └──────────────────────────────────────────┘
                      ┌──────────────────────────────────────────┐
                      │ axi-dashboard (FastAPI 127.0.0.1:8081)   │
                      │  /events /models /conversations          │
                      │  /meetings /memory /config               │
                      └──────────────────────────────────────────┘
```

Documentos relevantes:
- [docs/PRD-NEXT.md](docs/PRD-NEXT.md) — roadmap actual y próxima iteración
- [docs/AUTONOMOUS-RUN-SUMMARY.md](docs/AUTONOMOUS-RUN-SUMMARY.md) — registro de cambios mayores

---

## Filosofía

- **Local-first**: nada va a la nube por default
- **Privacy by default**: audio, conversaciones y reuniones se quedan en disco propio
- **Single user, single laptop**: no multi-tenant, no auth, no cloud sync
- **AI is a tool**: el humano dirige, la IA ejecuta

---

## Estado

Alpha. Lo uso a diario. La pipeline core (voz + brain + memoria + dashboard) es estable. Hay polish pendiente — ver [docs/PRD-NEXT.md](docs/PRD-NEXT.md).

## License

MIT — ver [LICENSE](LICENSE).
