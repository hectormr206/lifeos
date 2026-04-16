# Axi on SimpleX

> Documentation for all Axi interaction features via SimpleX Chat.
> Updated: 2026-04-13

## Overview

SimpleX Chat is a privacy-first messenger that requires no phone number, no
email address, and no server-side account. Every conversation uses a fresh
pair of one-time keys — there are no persistent user identifiers anywhere on
the network. The connection is end-to-end encrypted and routed through
SimpleX relay servers that never learn who is talking to whom.

Axi connects to a local `simplex-chat` process running in headless/WebSocket
mode on `ws://127.0.0.1:5226`. All messages are dispatched through the shared
agentic tool system in `daemon/src/axi_tools.rs` — same LLM, same tools, same
conversation memory across SimpleX and the dashboard.

On first connect, the SimpleX profile is auto-configured (name: **Axi**,
avatar, description) so Axi appears with the correct identity out of the box.

## Setup

### Requirements

- `simplex-chat` binary installed and runnable on the host.
- The `simplex-chat` process must be started in WebSocket mode on port 5226.
- `ffmpeg` available for audio conversion and camera capture.
- `whisper-cli` or `whisper-cpp` + model at
  `/usr/share/lifeos/models/whisper/ggml-small.bin` for voice transcription.
- `grim` (Wayland) or `gnome-screenshot` for screen capture.

### Environment

No environment variables are required. The bridge activates automatically
when `lifeosd` detects the SimpleX CLI WebSocket is reachable on startup.

If the socket is not reachable, the bridge silently skips — it does not crash
the daemon.

### Connecting your SimpleX client

On first start, the bridge requests an invitation link from the CLI and saves
it to `/var/lib/lifeos/simplex-invite-link` (permissions 0600). The dashboard
reads this file and displays a QR code or link you can scan from the SimpleX
mobile app to connect.

The invitation link is only generated once. If you delete the file, a new
link will be created on next daemon restart.

### Starting simplex-chat in WebSocket mode

```bash
simplex-chat -p 5226
```

This must run as the same user as `lifeosd`. You can manage it as a user
systemd service:

```bash
systemctl --user enable --now simplex-chat.service
```

## Features

### Chat

Send any natural language message and Axi processes it through the full
agentic loop — same LLM, same 80+ tools, same conversation history shared
with the local dashboard. Conversation history is keyed per-channel so
SimpleX and the dashboard do not share context.

### Commands

| Command | Alias | Action |
|---------|-------|--------|
| `/help` | `/menu`, `/ayuda`, `/start`, `?` | Show capabilities menu |
| `/foto` | `/camera`, `/cam` | Capture and send a webcam photo |
| `/pantalla` | `/screenshot`, `/screen` | Capture and send a screenshot |

Natural language works too — "tomá una foto", "qué hay en mi pantalla",
"take a photo", "show me the screen" all trigger the corresponding action
without needing slash commands.

### Voice notes

1. Auto-accept the incoming OGG/OPUS file via XFTP.
2. Convert to WAV (16 kHz mono) with `ffmpeg`.
3. Transcribe with Whisper (`ggml-small` model, Spanish language).
4. Dispatch the transcript through the agentic loop as text.
5. Reply with the text response.

The bridge acknowledges receipt immediately ("🎤 Recibido, transcribiendo...")
so you know the file was accepted.

> Voice replies are enabled: when Axi receives a voice note, it sends back
> both a text reply and an OGG voice attachment. See [Voice Reply Feature](#voice-reply-feature)
> below for details.

### Voice Reply Feature

Axi applies **modality mirroring** for voice conversations: when the incoming
message is a voice note, Axi sends both a text reply and an OGG voice
attachment. Text messages receive text replies only.

**Trigger:** incoming `MsgContent::Voice` (a SimpleX voice note, not a text
message).

**Flow:**

1. The OGG/OPUS voice note is auto-accepted via XFTP.
2. `ffmpeg` converts it to WAV (16 kHz mono).
3. Whisper transcribes the WAV locally.
4. The transcript is dispatched through the agentic loop.
5. `send_message` delivers the text reply (this always happens first).
6. Kokoro (`lifeos-tts-server.service` on `127.0.0.1:8084`) synthesizes the
   reply as OGG/Vorbis via `POST /tts` with `format=ogg`.
7. `send_file` attaches the OGG as a voice bubble in SimpleX.
8. The OGG file is deleted 60 seconds after `send_file` returns.

**File lifecycle:**

- Files are saved as `/var/lib/lifeos/tts-output/simplex-<uuid>.ogg`.
- Deleted by a background task 60 seconds after delivery.
- If the cleanup task fails, stale files can be removed manually — they are
  safe to delete.

**Limits and failure behavior:**

| Condition | Behavior |
|-----------|----------|
| OGG file > 1 MB | Voice attachment skipped, text reply still sent, WARN logged |
| Kokoro server unreachable | Voice attachment skipped, text reply still sent, WARN logged |
| `send_file` fails | Handler continues normally, no panic, text reply already delivered |

In all failure cases, the text reply is always sent first and is never lost.

**No configuration needed** — modality mirroring is automatic for all voice-originated
messages.

### Images

- **Inline thumbnail**: processed immediately from the base64 data-URI
  embedded in the message — Axi responds before the full file finishes
  downloading.
- **Full-resolution file**: auto-accepted via XFTP in the background;
  processed through the multimodal LLM if no thumbnail was available.
- Captions attached to images are passed to the LLM as context.

### Video

The thumbnail frame is extracted and analyzed by the multimodal LLM. Full
video playback/analysis is not yet supported.

### Files

Any file you send is automatically accepted via XFTP and saved to
`/var/lib/lifeos/simplex-downloads/`. The bridge confirms receipt by name.

### Camera photo

Axi captures a single frame from `/dev/video0` using `ffmpeg` and sends it
back as a file. Requires a V4L2-compatible webcam.

### Screenshot

Axi captures your current screen using `grim` (Wayland) with a fallback to
`gnome-screenshot`. The image is sent back as a file.

### Cron tasks and system tools

Because SimpleX uses the shared `ToolContext` from `axi_tools.rs`, all 80+
tools are available via natural language — cron job creation, service
management, system monitoring, memory plane queries, calendar, and so on.
There is no feature difference at the tool layer between SimpleX and the
dashboard.

### Incoming calls

SimpleX voice/video calls are not supported in headless CLI mode. If you
initiate a call from the mobile app, Axi will reply with a message explaining
the limitation and suggesting voice notes instead.

## Why SimpleX

SimpleX is the only remote chat channel shipped with LifeOS, chosen because
it aligns with the local-first, privacy-first philosophy of the project:

| Property | SimpleX |
|----------|---------|
| Phone number required | No |
| Server-side account | No |
| Persistent user ID | No — each contact uses ephemeral keys |
| Metadata visible to server | No — server only routes encrypted blobs |
| End-to-end encrypted by default | Always |
| Open protocol | Yes |
| Self-hostable relay | Yes |
| Local client required | Yes (simplex-chat binary) |

For in-host interaction, use the dashboard at
`http://127.0.0.1:8081/dashboard` — it is bound to localhost and not exposed
to the network.

## Troubleshooting

### Bridge does not start

Check that `simplex-chat` is running and listening on port 5226:

```bash
ss -tlnp | grep 5226
```

If not running, start the service:

```bash
systemctl --user start simplex-chat.service
```

The bridge retries the WebSocket connection every 15 seconds — no daemon
restart is needed once the CLI is up.

### No invitation link in the dashboard

Check if the file exists:

```bash
cat /var/lib/lifeos/simplex-invite-link
```

If missing, it means the invitation request failed or has not been processed
yet. Restart `lifeosd` to trigger a new request. The bridge retries the `/c`
command up to 3 times with 5-second delays.

### Voice transcription fails

Verify the Whisper binary and model:

```bash
ls /usr/local/bin/whisper-cli /usr/local/bin/whisper-cpp 2>/dev/null
ls /usr/share/lifeos/models/whisper/ggml-small.bin
```

Also confirm `ffmpeg` is installed:

```bash
ffmpeg -version | head -1
```

### Camera photo fails

Verify the webcam device exists:

```bash
ls /dev/video0
```

Check that `ffmpeg` can read it:

```bash
ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 /tmp/test.jpg
```

### Screenshot fails

On Wayland, `grim` must be installed. On X11, `gnome-screenshot` is the
fallback. If neither is available, the command returns an error message.

```bash
which grim gnome-screenshot
```

### Messages not being received

The bridge only processes incoming (`directRcv`) direct messages. Group chats
are not supported. Confirm you are messaging Axi directly in a 1:1 chat.
