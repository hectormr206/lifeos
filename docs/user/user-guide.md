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
- **Dashboard:** Open `http://127.0.0.1:8081/dashboard` in your browser for the local web UI (runs on localhost only, no external exposure).
- **SimpleX:** The privacy-first remote channel — E2E encrypted, no phone number or email required, no account on the server side. Configure in Settings → AI → SimpleX. The SimpleX profile (Axi name, avatar, description) is auto-configured when you connect, so Axi shows up with the correct identity out of the box. Preferred remote channel — aligns with LifeOS's local-first, privacy-first philosophy.

## Memory and Context

```bash
life memory add "Recordar: revisar logs de build"
life memory search "logs build" --mode hybrid
life memory graph --limit 50
```

## Cambiar la voz de Axi

Axi usa **Kokoro-82M** como motor de texto a voz con 50+ voces de alta calidad.
Podés elegir la voz que más te guste desde el dashboard — se aplica globalmente tanto
para las respuestas directas por bocina como para los mensajes de voz en SimpleX.

**Pasos:**

1. Abrí el dashboard en tu navegador: `http://127.0.0.1:8081/dashboard`
2. Navegá a la sección **Voz** dentro de los ajustes.
3. Seleccioná la voz del dropdown — las voces aparecen agrupadas por idioma.
4. (Opcional) Editá el texto de preview en el campo de texto.
5. Hacé click en **▶ Escuchar** para escuchar la voz con ese texto por tus bocinas.
6. Hacé click en **Guardar** para guardarla como tu voz por defecto.

La voz guardada se aplica a todas las interacciones de Axi:
- Respuestas directas por voz (desktop).
- Mensajes de voz OGG en respuestas de SimpleX.

Si el servidor TTS no está disponible, el botón de preview aparece deshabilitado
con un aviso. El botón de guardar sigue activo — podés guardar una voz sin necesidad
de previsualizar.

---

## Respuestas por voz en SimpleX

Axi aplica **espejado de modalidad** en SimpleX: el formato de entrada determina el
formato de la respuesta.

| Mensaje entrante | Respuesta de Axi |
|-----------------|-----------------|
| Texto escrito | Solo texto |
| Nota de voz | Texto **+** archivo de voz OGG |

**¿Cómo funciona?**

1. Enviás una nota de voz a Axi en SimpleX.
2. Whisper transcribe el audio localmente.
3. El LLM genera la respuesta.
4. Axi envía primero la respuesta como texto.
5. Kokoro sintetiza la respuesta como audio OGG.
6. Axi adjunta el OGG como burbuja de voz en la conversación.
7. El archivo OGG se elimina automáticamente 60 segundos después del envío.

**No requiere ninguna configuración** — el espejado es automático.

**Límites y comportamiento ante fallas:**

- El archivo OGG no puede superar **1 MB**. Si es más grande, se envía solo el texto.
- Si el servidor Kokoro no está disponible, se envía la respuesta de texto igualmente —
  nunca se pierde la respuesta por un fallo de voz.
- Los archivos temporales de voz se guardan en `/var/lib/lifeos/tts-output/` y se
  eliminan solos. No requieren mantenimiento manual.

---

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

**Dashboard UI:** The "Reuniones" section in the LifeOS dashboard (under the Operaciones tab) shows all recorded meetings with summaries, action items, screenshots, and full transcripts. You can search meetings by content, filter by time period (this week / this month / all), and export any meeting as Markdown. Click a meeting card to see its full detail view, including a screenshot gallery with click-to-enlarge.

## Vision/OCR

OCR from existing image:

```bash
life ai ocr --source /tmp/screen.png --language eng
```

OCR from live screen capture:

```bash
life ai ocr --capture-screen
```

## Web Search (Brave)

Axi puede consultar la web cuando se lo pedís. Usa la tool `web_search`
contra la API de Brave Search (free tier, ~2.000 queries por mes).

Configurá la clave de una de estas dos formas:

- Variable de entorno:

  ```bash
  export BRAVE_SEARCH_API_KEY=<tu_token>
  ```

- O en `/var/lib/lifeos/config-checkpoints/working/config.toml`:

  ```toml
  [web_search]
  brave_api_key = "tu_token"
  ```

Obtené una API key gratis en
<https://api.search.brave.com/app/subscriptions/subscribe>.

La tool está disponible en todos los canales (CLI, dashboard, Telegram,
SimpleX). Si no hay clave configurada, Axi te lo dice y te recuerda
cómo setearla.

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

## Security Alerts Feed

The LifeOS security monitor keeps a rolling buffer of the 50 most recent security events (unexpected listeners, suspicious processes, etc.) and exposes them through a read-only HTTP endpoint. The endpoint is bound to localhost only (no external exposure) and requires no bootstrap token — same policy as the dashboard bootstrap endpoint.

```bash
curl http://127.0.0.1:8081/api/security/alerts
```

Sample response:

```json
{
  "alerts": [
    {
      "id": "…",
      "severity": "medium",
      "alert_type": "…",
      "description": "…",
      "process_name": "…",
      "process_pid": 1234,
      "remote_addr": null,
      "evidence": ["…"],
      "action_taken": "logged",
      "timestamp": "2026-04-14T12:34:56Z"
    }
  ],
  "count": 1
}
```

The dashboard consumes this endpoint to render the "Seguridad" panel. If you are not on the host, the daemon returns `403` — the feed is not reachable remotely by design.

## System Updates

LifeOS updates use a **check → stage → apply** model. Nothing happens without your
knowledge — the system downloads updates in the background but never reboots automatically.

### Checking update status

```bash
life update status            # Human-readable summary
life update status --json     # Structured JSON
```

Output includes the currently booted image digest, whether a newer image is available,
and whether a deployment is already staged and ready to activate.

### Checking for new updates

```bash
life update check
```

Triggers `lifeos-update-check.service`, which probes GHCR without downloading anything.
Also runs automatically via `lifeos-update-check.timer` (daily).

### Staging an update

```bash
life update stage
```

Triggers `lifeos-update-stage.service`, which downloads and stages the new deployment
(via `bootc upgrade` without `--apply`). The current running system is not changed.
Also runs automatically every Sunday at 04:00 via `lifeos-update-stage.timer`.

### Activating a staged update

`life update apply` prints the manual command — it never executes anything:

```bash
life update apply
# Prints:
#   sudo bootc upgrade --apply
# Then reboot at your convenience.
```

Run the printed command when you are ready, then reboot to activate the new deployment.

### Rolling back

```bash
life update rollback
# Prints:
#   sudo bootc rollback
# Then reboot to activate the previous deployment.
```

`bootc` always keeps the last two deployments, so rollback is always available.

### Full update reference

See [`docs/operations/update-flow.md`](../operations/update-flow.md) for the complete
check → stage → apply documentation, state file schemas, and dashboard interaction.

---

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

---

## Dashboard CRUD: Workers, Conversations, Providers

The local dashboard at `http://127.0.0.1:8081/dashboard` now manages three resources end-to-end (no terminal needed):

- **Workers** — the *Workers* card lists in-flight async LLM tasks and lets you cancel any of them with one click. The list reconciles itself with the backend on every poll, so even after a page reload you can still see what is running. Backed by `GET /api/v1/workers` and `POST /api/v1/workers/:id/cancel`.
- **Conversations** — the *Historial* card shows a unified view of recent chats across SimpleX and Telegram. Click an entry to expand the full message thread; entries are sourced from `~/.local/share/lifeos/conversation_history.json`. Backed by `GET /api/v1/conversations`, `GET /api/v1/conversations/:chat_id`, and `DELETE /api/v1/conversations/:chat_id`.
- **LLM Providers** — the *Proveedores* card lets you add a new provider (name + API base + model + env var holding the key), toggle existing user-defined providers on/off, and delete entries. Built-in providers shipped with the OS image are read-only because `/usr` is immutable on bootc. Edits are persisted to `~/.config/lifeos/llm-providers.toml` (active) and `~/.config/lifeos/llm-providers.disabled.toml` (stash for toggled-off entries). Backed by `POST /api/v1/llm/providers`, `POST /api/v1/llm/providers/:name/toggle`, and `DELETE /api/v1/llm/providers/:name`.

All endpoints require the `x-bootstrap-token` header that the dashboard already injects automatically.

---

## Vida Plena: detail views, shopping lists, vault

The *Vida Plena* section of the dashboard now exposes three interactive surfaces (no terminal needed):

- **Per-pillar detail views** — every pilar card in the unified summary (Salud, Crecimiento, Ejercicio, Nutricion, Social, Sueno, Espiritual, Finanzas, Relaciones) is now clickable. Selecting a card opens a detail panel underneath that fetches the corresponding `GET /api/v1/vida-plena/<pillar>/summary` and renders the full structured payload (counts, recent entries, raw fields). Use the *Cerrar* button to dismiss.
- **Shopping lists** — manage the live editable list end-to-end:
  - *Recargar lista activa* refreshes from `GET /api/v1/vida-plena/shopping/active`.
  - *Generar semanal* prompts for a name and calls `POST /api/v1/vida-plena/shopping/generate-weekly`.
  - The inline form adds items via `POST /api/v1/vida-plena/shopping/lists/:id/items` (name + quantity + unit).
  - Each row has a checkbox (toggles via `POST .../check-by-name`) and a delete button (`DELETE .../items/:idx`).
  - *Quitar marcados* clears completed items via `POST .../clear-completed`.
- **Vault control** — the encrypted vault that protects sensitive Vida Plena data is now driven from the UI:
  - *Estado* fetches `GET /api/v1/vida-plena/vault/status` and shows configured/unlocked flags plus idle timeout.
  - *Configurar* sets a passphrase (and optional idle-timeout-secs) via `POST .../vault/set-passphrase`.
  - *Desbloquear* / *Bloquear* call `POST .../vault/unlock` and `POST .../vault/lock` respectively.
  - *Reset* (with confirmation) calls `POST .../vault/reset` to clear the configured passphrase.

All Vida Plena endpoints require the same `x-bootstrap-token` header. Vault errors map to `403` (locked / wrong passphrase) and `400` (missing/invalid input) so the UI surfaces the actual reason on failure.

## Freelance Dashboard (Clientes, Sesiones, Facturas, Tarifas, Resumen)

The dashboard at `http://127.0.0.1:8081/dashboard` includes a *Freelance* group in the sidebar with five tabs that consume the `/api/v1/freelance/*` endpoints:

- **Resumen** — month picker (defaults to current month) shows horas trabajadas, horas comprometidas, clientes activos, cuentas por cobrar, facturado emitido, facturado pagado, plus a top-clientes table and any active `alertas`. Backed by `GET /api/v1/freelance/overview` and `GET /api/v1/freelance/top-clientes`.
- **Clientes** — list with filter by estado (activo/pausado/terminado/todos), inline edit and "terminar" actions, plus a *+ Nuevo cliente* dialog covering nombre, modalidad (horas/retainer/proyecto), tarifa por hora, retainer mensual, horas comprometidas/mes, fecha inicio, contacto, email, telefono, RFC, notas. Edit also lets you change estado. Backed by `GET/POST/PATCH/DELETE /api/v1/freelance/clientes(/:id)`.
- **Sesiones** — filter by cliente, fecha desde/hasta. *+ Registrar sesion* dialog logs cliente + fecha + hora_inicio/fin + horas + descripcion + facturable flag. Each row has delete. Backed by `GET/POST/PATCH/DELETE /api/v1/freelance/sesiones(/:id)`.
- **Facturas** — filter by cliente y estado. *+ Nueva factura* dialog (cliente, subtotal, IVA, fechas emision/vencimiento, numero externo, concepto). Per-row actions: *Marcar pagada* (prompts fecha de pago) y *Cancelar* (prompts razon). Backed by `GET/POST/PATCH /api/v1/freelance/facturas(/:id)`.
- **Tarifas** — tabla de clientes con su tarifa por hora actual. El boton *Cambiar tarifa* hace `PATCH /clientes/:id` con la nueva `tarifa_hora`; el backend archiva automaticamente el cambio en `freelance_tarifas_history`.

Todos los dialogos usan `<dialog>` nativo. Los montos se muestran en MXN (`Intl.NumberFormat`).

## Nutrition pipeline (photo / voice → `nutrition_log`)

Item BI.3 turns food photos and voice notes into structured entries in the existing `nutrition_log` table without a manual form.

Two HTTP entry points (both behind the standard `x-bootstrap-token`):

- `POST /api/v1/vida-plena/nutrition/log/from-image` — body `{ "image_path": "/abs/path.jpg", "photo_attachment_id": "<opt>", "notes": "<opt>" }`. The daemon reads the file from disk, hands it to the local multimodal model (Qwen 4B by default), parses the strict JSON schema, validates each entry, and writes one row per detected item. Returns `{ extraction, logged_ids, count }`.
- `POST /api/v1/vida-plena/nutrition/log/from-voice` — body `{ "transcript": "comi tres tacos al pastor", "voice_attachment_id": "<opt>", "notes": "<opt>" }`. Caller is responsible for producing the transcript (Whisper STT in `sensory_pipeline.rs` already does this for the wake-word flow).

Same pipeline is also exposed to Axi as the `nutrition_log_from_capture` tool with `kind: "image" | "voice"` so the assistant can log meals during a normal conversation.

Validation is strict: empty names, non-positive quantities, negative kcal, or implausible kcal estimates (> 5,000 per item) are rejected before they touch storage. When the model cannot detect a meal in the input, the endpoint returns an empty `entries` list and writes nothing.

Privacy: extraction stays local — the image is sent inline to `127.0.0.1:8082` (llama-server). Routing the request to a remote vision provider only happens if the user has explicitly configured one in the LLM router; this endpoint never opts in on its own.
