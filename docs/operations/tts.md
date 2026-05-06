# TTS Service — Kokoro

> Updated: 2026-05-01

## Overview

LifeOS ships **Kokoro-82M** as its text-to-speech engine. Kokoro is an open-weight
model released under the Apache 2.0 license with 50+ high-quality voices across
multiple languages.

As of 0.8.26 the engine runs as a **systemd Quadlet** (`lifeos-tts.service`)
generated from `/etc/containers/systemd/lifeos-tts.container`. The Quadlet
pulls `ghcr.io/hectormr206/lifeos-tts:stable` and exposes the same local
HTTP API on `127.0.0.1:8084` via `Network=host` — clients (lifeosd) keep
working unchanged. This is Phase 1 of the architecture pivot
(`docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md`).

As of 0.8.37 the bootc image no longer ships a host-side TTS unit. The
legacy `lifeos-tts-server.service` was removed in Phase 6 along with
the Python venv at `/opt/lifeos/kokoro-env/` (~850 MB) — both moved
INTO the `lifeos-tts:stable` side container image. Rolling back to a
TTS regression is now bootc-native: `sudo bootc rollback && sudo
systemctl reboot` flips back to the previous deployment.

| Property | Value |
|----------|-------|
| Model | Kokoro-82M |
| License | Apache 2.0 |
| Backend | Python 3.12 venv (inside `ghcr.io/hectormr206/lifeos-tts:stable`) |
| Listen address | `127.0.0.1:8084` (loopback only) |
| Default voice | `ef_dora` (feminine, Spanish) |
| Inference | CPU-only (no CUDA dependency) |
| Memory limit | `MemoryMax=1536M` (in-process watchdog trips at 1400 MB) |
| Restart policy | `Restart=always` with `StartLimitBurst=3` / `StartLimitIntervalSec=300` |
| Config | `/etc/lifeos/tts-server.env` |

### Voice prefix convention

Kokoro voice names encode language and gender in the two-letter prefix:
`a`=US-English, `b`=UK-English, `e`=Español, `f`=Français, `h`=Hindi,
`i`=Italiano, `j`=Japonés, `p`=Português, `z`=中文; second letter `f`=female,
`m`=male. So `ef_dora` = Español-Female-Dora, `if_sara` = Italian-Female-Sara.
Picking a voice whose prefix does not match the spoken language degrades
naturalness noticeably.

### Required environment

`lifeos-tts.service` needs `PHONEMIZER_ESPEAK_LIBRARY=/usr/lib64/libespeak-ng.so.1`
to point the `phonemizer` Python library at the Fedora-shipped `libespeak-ng`.
Without it, phonemizer fails silently and Kokoro falls back to grapheme-level
tokens — every voice sounds robotic regardless of selection. The variable is
set both in `/etc/lifeos/tts-server.env` and as a hard-coded `os.environ.setdefault`
inside `lifeos-tts-server.py` for defense in depth.

`lifeosd` resolves the TTS endpoint via `daemon/src/endpoints.rs::tts_url()`,
which checks (in order):

1. `LIFEOS_TTS_URL` — canonical name. The Phase 8b Quadlet sets this to
   `http://lifeos-tts:8084` so the daemon reaches the TTS container by
   service name on the `lifeos-net` bridge.
2. `LIFEOS_TTS_SERVER_URL` — legacy name, kept for compatibility with
   pre-pivot hosts that still ship `00-tts.conf` drop-ins.
3. Default `http://127.0.0.1:8084` for the legacy `Network=host` rollback
   path.

Both variables must be a bare `scheme://host[:port]` URL — no path, no
query, at most one trailing slash. Anything else is logged at `WARN`
and the default is used (so the daemon never silently degrades to the
robot voice from a typo in the env file).

If the dashboard's voice selector produces no audio, check `tts.tts_engine`
in the `POST /api/v1/sensory/tts/speak` response: `kokoro:<voice>` means
success, `/usr/bin/espeak-ng` means the URL was unreachable or both env
vars resolved to empty/invalid values.

---

## Architecture

```
                                  ┌──────────────────────┐
                                  │  lifeos-tts   │
  lifeosd ──POST /tts────────────►│  (Kokoro-82M, :8084) │──► pw-play / aplay
          ◄── audio/wav ──────────│  127.0.0.1 only      │    (host speakers)
                                  └──────────────────────┘
                                            ▲
  simplex_bridge ──POST /tts───────────────►│
                   (format=ogg)             │
  ◄── audio/ogg ──────────────────────────►│
          │                                └──────────────────────┘
          └── send_file(ogg) ──► SimpleX mobile (voice bubble)
```

**Flow — direct voice (lifeosd):**
1. `lifeosd` synthesizes text via `POST /tts` (WAV format).
2. The WAV bytes are written to a temp file and played through PipeWire (`pw-play`).

**Flow — SimpleX voice reply (simplex_bridge):**
1. User sends a voice note → Whisper transcribes it.
2. LLM generates a reply → `send_message` delivers the text.
3. `synthesize_with_kokoro_http` posts to `/tts` with `format=ogg`.
4. The OGG file is sent via `send_file` as a voice bubble in the SimpleX app.
5. The file is deleted 60 seconds after delivery.

---

## Service Lifecycle

### Check status

```bash
systemctl status lifeos-tts
```

### View logs

```bash
journalctl -u lifeos-tts -f
journalctl -u lifeos-tts --since "10 minutes ago"
```

### Start / stop / restart

```bash
# These require appropriate polkit / sudo permissions:
systemctl start lifeos-tts
systemctl stop lifeos-tts
systemctl restart lifeos-tts
```

### Health check

```bash
curl -s http://127.0.0.1:8084/health | python3 -m json.tool
```

Expected response when ready:

```json
{
  "status": "ok",
  "model": "Kokoro-82M",
  "voices_loaded": 54
}
```

Returns HTTP 503 while the model is still loading at startup.

---

## API Reference

### `GET /health`

Returns service status.

**Response 200:**

```json
{
  "status": "ok",
  "model": "Kokoro-82M",
  "voices_loaded": 54
}
```

**Response 503** (warming up):

```json
{ "status": "loading" }
```

---

### `GET /voices`

Returns the full list of available Kokoro voices.

**Response 200:**

```json
[
  { "name": "if_sara",   "language": "en-us", "gender": "feminine",  "is_default": true  },
  { "name": "im_nicola", "language": "en-us", "gender": "masculine", "is_default": false },
  { "name": "af_heart",  "language": "en-us", "gender": "feminine",  "is_default": false }
]
```

Each object contains:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Kokoro voice identifier |
| `language` | string | BCP-47 language tag |
| `gender` | string | `"feminine"` or `"masculine"` |
| `is_default` | bool | `true` for the system-default voice |

---

### `POST /tts`

Synthesize speech from text.

**Request body (JSON):**

```json
{
  "text": "Hola Héctor, soy Axi. ¿Cómo puedo ayudarte hoy?",
  "voice": "if_sara",
  "speed": 1.0,
  "format": "wav"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | Yes | Text to synthesize |
| `voice` | string | No | Voice name (defaults to `LIFEOS_TTS_DEFAULT_VOICE`) |
| `speed` | float | No | Playback speed multiplier (default: `1.0`) |
| `format` | string | No | `"wav"` (default) or `"ogg"` |

**Response 200:**
- `Content-Type: audio/wav` (or `audio/ogg` when `format=ogg`)
- Body: raw audio bytes

**Response 400 — unknown voice:**

```json
{
  "error": "unknown_voice",
  "detail": "nonexistent_voice is not a valid Kokoro voice"
}
```

**Response 500 — synthesis error:**

```json
{
  "error": "synthesis_failed",
  "detail": "..."
}
```

**Example — WAV synthesis:**

```bash
curl -s -X POST http://127.0.0.1:8084/tts \
  -H "Content-Type: application/json" \
  -d '{"text":"Hola Axi","voice":"if_sara"}' \
  -o /tmp/test.wav
aplay /tmp/test.wav
```

**Example — OGG for SimpleX:**

```bash
curl -s -X POST http://127.0.0.1:8084/tts \
  -H "Content-Type: application/json" \
  -d '{"text":"Hola","voice":"if_sara","format":"ogg"}' \
  -o /tmp/test.ogg
```

---

## Default Voices

| Voice | Language | Gender | Notes |
|-------|----------|--------|-------|
| `if_sara` | English (US) | Feminine | **System default** — shipped in image |
| `im_nicola` | English (US) | Masculine | Alternative default option |

The system default is configured via `LIFEOS_TTS_DEFAULT_VOICE` in
`/etc/lifeos/tts-server.env`. Users can select any voice from the
50+ bundled Kokoro voices via the dashboard (see [Voice Selector](#voice-selector-in-dashboard)).

---

## Voice Selector in Dashboard

The LifeOS dashboard at `http://127.0.0.1:8081/dashboard` includes a **TTS settings
section** that lets each user pick their preferred Kokoro voice.

**Steps:**

1. Open the dashboard in your browser.
2. Navigate to the **Voz** (Voice) settings section.
3. Select a voice from the dropdown — voices are grouped by language.
4. Optionally edit the preview text in the text field.
5. Click **▶ Escuchar** to preview the voice playing through your speakers.
6. Click **Guardar** to save it as your personal default.

**Scope:** the saved voice applies globally — both direct voice responses through
your speakers and OGG voice attachments sent in SimpleX replies.

If the TTS server is unreachable, the preview button is disabled and a warning
is shown. The save button remains active — you can still save a voice name even
without previewing.

---

## Modality Mirroring Rule

LifeOS applies automatic modality mirroring for SimpleX conversations:

| Input type | Axi output |
|------------|-----------|
| Text message | Text reply only |
| Voice note | Text reply **+** OGG voice attachment |

This behavior is automatic and requires no configuration.

---

## Capability Probe y Voice Prewarm

Dos detalles operativos relevantes para entender por qué el dashboard y la lista
de voces se mantienen estables:

- **Prewarm de voces en build-time.** El script `image/scripts/prewarm-kokoro.py`
  usa `snapshot_download` del repo `hexgrad/Kokoro-82M` y baja **todas** las
  voces (`voices/*.pt`, 50+) dentro del venv de Kokoro. Antes solo se precargaba
  `if_sara.pt`, por lo que `GET /voices` devolvía una lista vacía en imágenes
  recién instaladas y el selector del dashboard aparecía sin opciones. Ahora la
  imagen ya trae todas las voces listas en `/opt/lifeos/kokoro-env/lib/python3.12/site-packages/kokoro/voices/`.

- **Carry-forward en el capability probe.** `daemon/src/sensory_pipeline.rs`
  sondea Kokoro cada ~5 min, pero el loop de refresh de capacidades tickea cada
  ~5 s. Cuando el probe está en cooldown (throttled), `detect_capabilities`
  ahora devuelve `ProbeOutcome::Throttled` y **arrastra las capacidades TTS
  previas** en lugar de marcar al servicio como no disponible. Resultado: el
  dashboard ya no parpadea a "TTS no disponible" mientras Kokoro está sano; sólo
  se marca caído cuando el probe real lo confirma (`ProbeOutcome::Unavailable`).

---

## Troubleshooting

### Service not starting

1. Check the service status and logs:

```bash
systemctl status lifeos-tts
journalctl -u lifeos-tts -n 50
```

2. Verify the Python venv exists:

```bash
ls /opt/lifeos/kokoro-env/bin/python3
```

3. Verify the env file exists:

```bash
ls /etc/lifeos/tts-server.env
```

4. Check available memory — Kokoro requires up to 1 GB RAM:

```bash
free -h
```

### Voice not available (unknown_voice)

1. Confirm the voice name is correct:

```bash
curl -s http://127.0.0.1:8084/voices | python3 -m json.tool | grep '"name"'
```

2. If the voices manifest is empty or missing, check the build:

```bash
ls /opt/lifeos/kokoro-env/lib/python3.12/site-packages/kokoro/voices/
```

3. If missing, the image may not have been built with the `kokoro-builder` stage.
   Run a `bootc upgrade` to pull the latest image.

### OGG transcode failures

1. Confirm `ffmpeg` is installed:

```bash
ffmpeg -version | head -1
```

2. If missing (unexpected for a correctly built image), the voice reply will fall back
   to WAV internally. The SimpleX voice bubble may not render correctly.

3. Check for disk space issues under `/var/lib/lifeos/tts-output/`:

```bash
df -h /var/lib/lifeos/
ls -lh /var/lib/lifeos/tts-output/
```

   Stale `.ogg` files here indicate a cleanup task that failed. They are safe to delete.

### Memory pressure

The TTS service has a `MemoryMax=1G` systemd limit. If the system is running low
on memory, the service may be OOM-killed and restarted by systemd.

To check:

```bash
systemctl status lifeos-tts | grep Memory
journalctl -u lifeos-tts | grep -i "oom\|killed\|memory"
```

If the service is being killed repeatedly, consider closing other memory-intensive
workloads, or check if a large LLM is running simultaneously.

---

## Rollback

If you need to revert to a pre-0.7.0 image (which used Piper TTS), use the
standard bootc rollback:

```bash
sudo bootc rollback
```

Then reboot. The previous deployment is preserved and will be activated on next boot.

> **Note:** `bootc` always keeps the last two deployments. Rollback is always available
> without any additional downloads.

See [System Updates](../user/user-guide.md#system-updates) for the full
check → stage → apply → rollback workflow.
