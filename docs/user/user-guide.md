# LifeOS User Guide (Phase 2)

## Quick Start

1. Check system health:

```bash
life check
life status --detailed
```

2. Verify AI runtime:

```bash
life ai status --verbose
life ai ask "Resume mi estado del sistema"
```

3. Optional trust/autonomy setup:

```bash
life onboarding trust-mode status
```

## Development Containers (Toolbox)

LifeOS is immutable by design. Install development dependencies inside `toolbox` containers:

```bash
toolbox create dev-node
toolbox enter dev-node
sudo dnf install -y nodejs npm
node --version
npm --version
```

Exit toolbox with:

```bash
exit
```

## Desktop Environment

LifeOS uses **COSMIC Desktop** — a Wayland-native, GPU-accelerated desktop built by System76. It launches automatically after login. No configuration needed; it works out of the box with both integrated and discrete GPUs.

Keyboard shortcut reference: open the COSMIC Settings app → **Keyboard** → **Shortcuts**.

## Assistant Channels

Axi (the LifeOS AI assistant) is reachable through multiple channels:

- **Terminal:** `life assistant ask "..."`.
- **Launcher:** `life assistant install-launcher` — adds a system-wide launcher shortcut.
- **Overlay:** `life assistant open` — floating overlay on the COSMIC desktop.
- **Telegram:** Connect your bot token in Settings → AI → Telegram to chat with Axi from your phone or any Telegram client.
- **SimpleX:** For privacy-first messaging without phone numbers or identifiers. Configure in Settings → AI → SimpleX. Axi responds through a SimpleX address you control — no account required on the server side.

## Memory and Context

```bash
life memory add "Recordar: revisar logs de build"
life memory search "logs build" --mode hybrid
life memory graph --limit 50
```

## Voice and Sensory Runtime (Consent-Gated)

1. Grant consent for monitoring:

```bash
life follow-along consent
```

2. Start sensory runtime:

```bash
life intents sensory start --audio --screen
life intents sensory status
```

3. Capture one sensory snapshot:

```bash
life intents sensory snapshot --audio-file /tmp/note.wav
```

## Always-On and Model Routing

```bash
life intents always-on enable --wake-word "axi"
life intents always-on classify "axi open terminal"
life intents model-route critical --preferred-model Qwen3.5-9B-Q4_K_M.gguf
```

## Wake Word Detection (experimental)

Axi listens for a wake word so you can trigger the assistant hands-free. The default wake word is **"Axi"**.

**How it works:** The daemon uses [rustpotter](https://github.com/GiviMAD/rustpotter) for on-device keyword spotting. Audio is streamed from the microphone via PipeWire (`pw-record`) and processed entirely on your machine — no audio data ever leaves the device.

**Enabling it:**

```bash
life intents always-on enable --wake-word "axi"
```

**Pre-trained model:** A pre-built model for "Axi" ships with the image at `/usr/share/lifeos/models/rustpotter/axi.rpw`. On first use it is copied to `/var/lib/lifeos/models/rustpotter/axi.rpw` so you can refine it without touching the read-only image.

**Training a custom wake word:** If you want to use a different word or improve accuracy for your voice, record enrollment samples and train:

```bash
life intents always-on train-wake-word
```

After training, the detector hot-reloads the new model without a restart.

**Privacy note:** Detection runs fully locally. The microphone is only open while always-on mode is active; disable it at any time with `life intents always-on disable`.

> **Note:** Wake word detection is experimental. False-positive rate depends on microphone quality and ambient noise. Accuracy improves after custom enrollment.

## Meeting Assistant (experimental)

> **Status: experimental — behavior and output quality are still being validated.**

LifeOS can automatically detect when you join a video call and assist with recording, transcription, and summarization. No manual trigger is needed; detection is passive.

**Detection signals (combined for confidence):**

- PipeWire audio streams from known conferencing apps (Zoom, Google Meet, Microsoft Teams, Discord, Slack Huddle, Jitsi, WebEx)
- Webcam usage (`/dev/video0` held by a browser or meeting app)
- Window title patterns matching active meeting state

**Processing pipeline:**

1. **Detect** — meeting start is identified from the signals above
2. **Record** — system audio (and optionally mic) captured via PipeWire
3. **Transcribe** — local Whisper STT processes the audio after the call ends; no audio sent to external services
4. **Diarize** — speaker segments are identified and, if speaker profiles exist, labeled by name
5. **Summarize** — LLM generates a summary, action items, and key points
6. **Archive** — results stored locally in SQLite; raw audio deleted by default after successful processing (set `LIFEOS_KEEP_MEETING_AUDIO=1` to retain it)

The assistant is enabled by default. Set `LIFEOS_MEETING_ASSISTANT=0` to disable it. Real-time captions during a call are opt-in via `LIFEOS_MEETING_CAPTIONS=1`.

Stable CLI commands for querying meeting history and archives will be documented once the interface is finalized.

## Vision/OCR

OCR from existing image:

```bash
life ai ocr --source /tmp/screen.png --language eng
```

OCR from live screen capture:

```bash
life ai ocr --capture-screen
```

## Safety and Self-Defense

```bash
life intents defense status
life intents defense repair --actor user://local/default
```

## Proactive Heartbeats

```bash
life intents heartbeat enable --interval 300
life intents heartbeat tick
life intents heartbeat status
```

## Automatic System Maintenance

LifeOS handles routine maintenance without user intervention:

- **Flatpak auto-updates:** Installed Flatpak apps update daily in the background. Updates are skipped automatically when the system is on battery, on a metered connection, or running a game to avoid interruptions.
- **NVIDIA GL extension sync:** On systems with NVIDIA GPUs, OpenGL and Vulkan extension compatibility layers are synced with the active host driver on every boot. You do not need to manually reinstall or reconfigure GPU components after a driver update.
- **System cleanup:** Old bootc deployment images, orphaned Flatpak runtimes, and stale cache files are cleaned up automatically on a weekly schedule. Disk usage stays bounded without manual `flatpak uninstall --unused` runs.

To check the last maintenance run or trigger it manually:

```bash
life maintenance status
life maintenance run
```
