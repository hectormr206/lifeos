# TTS Service — Kokoro

> Updated: 2026-04-15

## Overview

LifeOS ships **Kokoro-82M** as its text-to-speech engine. Kokoro is an open-weight
model released under the Apache 2.0 license with 50+ high-quality voices across
multiple languages.

The engine runs as a **system service** (`lifeos-tts-server.service`) that exposes
a local HTTP API on `127.0.0.1:8083`. The service starts automatically at boot
and is ready before `lifeosd.service` launches.

| Property | Value |
|----------|-------|
| Model | Kokoro-82M |
| License | Apache 2.0 |
| Backend | Python 3.12 venv at `/opt/lifeos/kokoro-env/` |
| Listen address | `127.0.0.1:8083` (loopback only) |
| Default voice | `if_sara` (feminine, English) |
| Inference | CPU-only (no CUDA dependency) |
| Config | `/etc/lifeos/tts-server.env` |

---

## Architecture

```
                                  ┌──────────────────────┐
                                  │  lifeos-tts-server   │
  lifeosd ──POST /tts────────────►│  (Kokoro-82M, :8083) │──► pw-play / aplay
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
systemctl status lifeos-tts-server
```

### View logs

```bash
journalctl -u lifeos-tts-server -f
journalctl -u lifeos-tts-server --since "10 minutes ago"
```

### Start / stop / restart

```bash
# These require appropriate polkit / sudo permissions:
systemctl start lifeos-tts-server
systemctl stop lifeos-tts-server
systemctl restart lifeos-tts-server
```

### Health check

```bash
curl -s http://127.0.0.1:8083/health | python3 -m json.tool
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
curl -s -X POST http://127.0.0.1:8083/tts \
  -H "Content-Type: application/json" \
  -d '{"text":"Hola Axi","voice":"if_sara"}' \
  -o /tmp/test.wav
aplay /tmp/test.wav
```

**Example — OGG for SimpleX:**

```bash
curl -s -X POST http://127.0.0.1:8083/tts \
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

## Troubleshooting

### Service not starting

1. Check the service status and logs:

```bash
systemctl status lifeos-tts-server
journalctl -u lifeos-tts-server -n 50
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
curl -s http://127.0.0.1:8083/voices | python3 -m json.tool | grep '"name"'
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
systemctl status lifeos-tts-server | grep Memory
journalctl -u lifeos-tts-server | grep -i "oom\|killed\|memory"
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
