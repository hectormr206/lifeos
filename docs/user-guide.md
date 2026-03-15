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

## Assistant Channels

- Terminal: `life assistant ask "..."`.
- Launcher: `life assistant install-launcher`.
- Overlay: `life assistant open`.

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
