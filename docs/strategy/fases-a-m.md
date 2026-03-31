# LifeOS Fases A-M (Core Development)

> Este archivo es parte de la Estrategia Unificada de LifeOS. Ver [docs/strategy/](../strategy/) para el indice completo.

---

## 18. Roadmap Ejecutable con Checkboxes

### Pre-requisitos (Dia 0) — COMPLETADO 2026-03-23

- [x] Descargar Qwen3.5-4B-Q4_K_M.gguf y colocarlo en /var/lib/lifeos/models/
- [x] Actualizar LIFEOS_AI_MODEL en llama-server.env a Qwen3.5-4B (upgrade desde 2B, 2026-03-28)
- [x] Verificar que llama-server arranca con el nuevo modelo (~150-200 tok/s GPU, reasoning off)
- [x] Registrar API key en Cerebras (free tier, 235B a 2000+ tok/s)
- [x] Registrar cuenta en OpenRouter (free models)
- [x] Registrar cuenta en Z.AI/GLM (ya existente)
- [x] Limpiar documentacion segun seccion 17 (de 67 a ~20 archivos)
- [ ] Reservar nombre en GitHub org (lifeos-ai) y X/Twitter — REQUIERE HUMANO

### Fase A — COMPLETADA 2026-03-23

- [x] Crear `daemon/src/llm_router.rs` — 11 providers (Local, 2x Cerebras, 3x Z.AI, 5x OpenRouter)
- [x] Implementar provider: Local (llama-server :8082, Qwen3.5-4B)
- [x] Implementar provider: Cerebras Free (qwen-3-235b, llama3.1-8b)
- [x] Implementar provider: Z.AI (glm-4.5-air, glm-5, glm-4.7)
- [x] Implementar provider: OpenRouter Free (Qwen3 Coder, GPT-OSS 120B, MiniMax M2.5, Nemotron VL, GLM)
- [x] Implementar logica de seleccion por complejidad de tarea
- [x] Implementar fallback automatico (verificado: Z.AI fallo -> Cerebras tomo en 310ms)
- [x] Implementar `daemon/src/privacy_filter.rs` — 4 niveles sensibilidad, classify + is_safe_for_tier + sanitize completos (Bearer, API keys, emails, tarjetas de credito, telefonos, IPs privadas — 9 tests)
- [x] Agregar endpoints API: POST /api/v1/llm/chat, GET /api/v1/llm/providers
- [x] Agregar crate `teloxide` a daemon/Cargo.toml (feature-gated)
- [x] Crear `daemon/src/telegram_bridge.rs` — bot bidireccional con notificaciones push
- [x] Telegram: recibir mensajes de texto y pasarlos al LLM router
- [x] Telegram: devolver respuesta del LLM (verificado con Cerebras 235B en 2.3s)
- [x] Telegram: autenticacion por chat_id
- [x] Test en produccion: mensaje Telegram -> Cerebras 235B -> respuesta en 2.3s
- [x] Crear `daemon/src/task_queue.rs` — SQLite persistente, prioridad, retry, 5 tests
- [x] Trabajos sobreviven reinicios del daemon
- [x] Crear `daemon/src/supervisor.rs` — loop autonomo con planning LLM
- [x] Supervisor: plan -> execute -> evaluate -> retry -> report
- [x] Herramientas: shell_command, sandbox_command, read_file, write_file, ai_query, screen_capture, respond
- [x] Retry: 3 intentos, marca como failed, notifica via Telegram
- [x] Telegram: /do crea tarea -> task_queue -> supervisor la toma automaticamente
- [x] Flujo end-to-end verificado en produccion: /do -> plan -> git status -> resultado en Telegram
- [x] Supervisor notifica resultados automaticamente a Telegram (push notifications)
- [x] Memory writeback: guardar exitos/errores cifrados en memory_plane con embeddings
- [x] Learning loop: consultar memoria antes de planificar (context-aware)
- [x] Heartbeat diario automatico (24h timer) via Telegram
- [x] Audit logging a /var/log/lifeos/supervisor-audit.log
- [x] Fallback robusto con cascade entre providers
- [x] Tests unitarios: 14 nuevos (privacy_filter 5, task_queue 5, supervisor 3, + otros)
- [x] **HITO FASE A:** Verificado en produccion — Telegram -> tarea -> ejecucion -> resultado

### Fase B — COMPLETADA 2026-03-23

- [x] Sandbox de desarrollo: git worktree aislado con auto-cleanup
- [x] Screen capture: grim (Wayland) + gnome-screenshot fallback
- [x] Self-healing: supervisor se reinicia automaticamente tras panic (max 10 restarts)
- [x] Self-healing: LLM falla -> fallback automatico a otro provider
- [x] Self-healing: task falla 3 veces -> marca como failed, notifica via Telegram
- [x] Clasificacion de riesgo: low/medium/high. High (rm -rf, sudo, git push --force) se BLOQUEA
- [x] Learning loop: planner consulta memory_plane antes de planificar
- [x] AI summarization: resultados largos se resumen antes de enviar a Telegram
- [x] Browser automation: fetch_url_text() + browse_url action + HTML stripping
- [x] Visual loop: screen_analyze action (screenshot -> LLM analiza -> devuelve descripcion)

### Fase C — COMPLETADA 2026-03-23

- [x] Agent roles: 7 roles (GM, Planner, Coder, Reviewer, Tester, DevOps, Researcher)
- [x] Cada rol tiene system prompt especifico y allowed actions
- [x] GM auto-selecciona el mejor rol segun el objetivo (keyword matching ES/EN)
- [x] Role-based planning: el planner usa el prompt del rol asignado
- [x] 6 tests para role classification
- [x] Dashboard de operaciones: nueva seccion "Supervisor" con tareas pendientes/running/completed/failed
- [x] Dashboard: lista de tareas recientes con status, resultado, auto-refresh 10s
- [x] Metricas por agente: per-role tracking (completed/failed/avg_duration), GET /api/v1/supervisor/metrics
- [x] Runbooks automaticos: pattern matching de errores con sugerencias de recuperacion en Telegram

### Fase D — Telegram Multimedia + Web Search (proxima iteracion)

**Objetivo:** LifeOS entiende voz, imagenes y puede buscar en internet.

- [x] Telegram: recibir mensajes de voz -> descargar OGG -> Whisper local transcribe -> LLM router
- [x] Telegram: responder con audio -> Piper TTS genera -> convertir a OGG/OPUS -> sendVoice
- [x] Telegram: recibir fotos -> descargar -> enviar a LLM con vision (local Qwen3.5-4B o Groq)
- [x] Telegram: recibir videos -> extraer frames clave -> vision LLM analiza (implementado commit 14fa392: handle_video() con ffmpeg frame extraction)
- [x] Telegram: enviar screenshots del desktop como foto (sendPhoto)
- [x] Telegram: funcionar en grupos (responder solo a @bot o /do, ignorar otros mensajes)
- [x] Web search: integrar Groq browser_search tool en supervisor principal (implementado commit 14fa392: priority 1 en execute_web_search())
- [x] Web search: Serper API como fallback (2,500 busquedas/mes gratis, $1/1K despues)
- [x] Web search: supervisor puede usar browse_url + search como herramientas de planning
- [x] Supervisor: nueva accion `web_search` que busca en internet y devuelve resultados
- [x] **HITO FASE D:** Enviar audio de voz por Telegram, recibir respuesta en audio. Enviar foto y que la describa. Pedir "busca en internet X" y que lo haga.

### Fase E — Inteligencia Proactiva + Integraciones (mes siguiente)

**Objetivo:** LifeOS anticipa tus necesidades y se conecta a tus herramientas.

- [x] Notificaciones proactivas: `proactive.rs` con checks de disco, RAM, sesion larga, tareas atascadas. Loop de fondo cada 5 min envia alertas via event bus
  - Ejemplo: "Llevas 2 horas sin descanso", "Tu disco esta al 85%", "Hay un PR pendiente"
- [x] Calendario: `calendar.rs` SQLite local con API completa: GET /calendar/today, GET /calendar/upcoming, POST /calendar/events, DELETE /calendar/events/:id, GET /calendar/reminders. Loop de fondo cada 60s chequea reminders y notifica via event bus
  - "Que tengo hoy?" "Agenda reunion a las 3" "Recuerdame a las 5 llamar a X"
  - **Nota:** CalDAV/Google Calendar sync es futuro — por ahora el supervisor y Telegram pueden crear/consultar eventos locales
- [x] Scheduled tasks: tareas programadas tipo cron (SQLite, interval/daily/weekly, supervisor las dequeue automaticamente). API endpoints completos: GET/POST/DELETE /tasks/scheduled. Dashboard funcional
- [x] Multi-step approval: supervisor envia `ApprovalRequired` notification para acciones de riesgo medio → Telegram muestra botones inline Aprobar/Rechazar → callback re-encola o cancela la tarea
- [x] Email integration: `email_bridge.rs` con IMAP (lectura) y SMTP (envio) via python3 bridge. API endpoints: GET /email/inbox, POST /email/send, GET /email/status. Funcional con env vars LIFEOS_EMAIL_*
  - "Lee mis ultimos 5 emails y resumelos" "Responde a X diciendo que confirmo"
- [x] File management: API endpoints GET /files/search (find por patron) y GET /files/content-search (grep por contenido). Supervisor ya tenia FileSearch + ContentSearch como acciones del plan
- [x] Clipboard integration: API endpoint POST /clipboard/copy (wl-copy Wayland + xclip X11 fallback). Supervisor ya tenia ClipboardCopy como accion del plan
- [x] **HITO FASE E:** Calendario local funcional via API. Tareas programadas se ejecutan solas via supervisor.

### Fase F — Comunicacion Multi-Canal (futuro cercano)

**Objetivo:** LifeOS puede comunicarse por multiples canales ademas de Telegram.

- [ ] WhatsApp integration: `whatsapp_bridge.rs` existe en repo y se lanza si el binario se compila con feature `whatsapp`, pero la imagen por defecto hoy NO incluye esa feature
- [ ] Matrix/Element bridge: `matrix_bridge.rs` existe en repo y se lanza si el binario se compila con feature `matrix`, pero la imagen por defecto hoy NO incluye esa feature
- [ ] Signal bridge: `signal_bridge.rs` existe en repo y se lanza si el binario se compila con feature `signal`, pero la imagen por defecto hoy NO incluye esa feature
- [ ] Smart home: `home_assistant.rs` existe en repo y el daemon lo arranca si se compila con feature `homeassistant`, pero la imagen por defecto hoy NO incluye esa feature
- [x] Health tracking: `health_tracking.rs` con timers de break/hidratacion/descanso visual (regla 20-20-20). Loop de fondo cada 60s incrementa minutos activos y envia reminders via event bus. API endpoints: GET /health/tracking, POST /health/tracking/break, GET /health/tracking/reminders
  (presencia/fatiga por webcam ya existe en sensory_pipeline — se puede conectar para posture_alerts futuro)
- [ ] Messaging channels API: GET /messaging/channels existe, pero no convierte automaticamente estos bridges en canales realmente activos si la imagen fue compilada sin sus features
- [ ] API keys management extendido: el soporte documental existe, pero la auditoria de canales muestra que no todos esos bridges estan realmente shipped en la imagen actual
- [ ] **HITO FASE F:** No cuenta como completo mientras la imagen por defecto siga saliendo practicamente Telegram-only

### Busqueda Web — Estrategia de Providers

El modelo local NO puede buscar en internet por si solo. Necesita un tool/API.

**Orden de prioridad:**

| # | Provider | Privacidad | Costo | Notas |
|---|----------|-----------|-------|-------|
| 1 | **Groq browser_search** (built-in) | Alta (ZDR) | Gratis | Ya integrado en Groq, solo activar tool_use |
| 2 | **Serper API** | Media | 2,500/mes gratis, $1/1K | Google Search results, rapido (1-2s) |
| 3 | **Brave Search API** | Media | $3/1K | Indice independiente (35B paginas), no depende de Google |
| 4 | **browse_url** (ya implementado) | Maxima | Gratis | Para leer paginas especificas, no para buscar |

Configurar en `llm-providers.env`:
```
SERPER_API_KEY=          # opcional, 2500 busquedas/mes gratis
BRAVE_SEARCH_API_KEY=    # opcional, alternativa a Serper
```

### Fase G — GPU Game Guard + Game Assistant (reabierta por auditoria 2026-03-31)

**Objetivo:** LifeOS libera VRAM automaticamente al jugar y puede ayudarte dentro del juego.

**Datos reales medidos (RTX 5070 Ti, 12 GB VRAM):**
- Qwen3.5-4B Q4_K_M con 16K contexto: **~3.5 GB VRAM** en reposo (modelo actual)
- Qwen3.5-2B Q4_K_M con 6K contexto: ~2.77 GB VRAM (modelo anterior, deprecated)
- Gaming (RE Requiem): 11.8/11.9 GB VRAM (98%) → stuttering por falta de VRAM

**GPU Game Guard (auto-offload a RAM):** `game_guard.rs`
- [ ] Detectar juego corriendo (GameMode dbus > proceso conocido > VRAM threshold)
  - `detect_gamemode_active()`: el repo ya fue corregido para no tratar la mera existencia de `gamemoded` como juego activo, pero el host demostro falsos positivos antes de desplegar ese fix
  - `detect_game_processes()`: scan /proc/*/comm para wine, proton, gamescope, etc.
  - `detect_vram_heavy_processes()`: `nvidia-smi pmon -c 1 -s m`, ahora tambien debe excluir correctamente `llama-server` tras resolver nombre real desde `/proc`
  - Threshold: >500MB VRAM por proceso no-sistema
- [x] Al detectar juego: crea `/etc/lifeos/llama-server-game-guard.env` con `GPU_LAYERS=0` + restart → modelo a RAM
- [ ] Al cerrar juego: BORRA el override env file + restart → GPU_LAYERS del env principal toma efecto
- [x] Loop cada 10 segundos en background (`run_game_guard_loop`)
- [x] Notificacion via event bus: `GameGuardChanged { game_detected, game_name, llm_mode }`
- [x] Setting `LIFEOS_AI_GAME_GUARD=true` (default ON), toggle via API
- [x] Dashboard toggle en seccion "Sistema & IA" (toggle Game Guard + Game Assistant)
- [x] Instalar paquete `gamemode` en Containerfile
- [x] API endpoints: GET /game-guard/status, POST /game-guard/toggle, POST /game-guard/assistant-toggle

**Game Assistant (Axi como copiloto de juego):** `game_assistant.rs`
- [x] Detectar nombre del juego automaticamente: /proc/{pid}/comm + cmdline + Steam appid via /proc/{pid}/environ
- [x] Cuando el usuario pide ayuda (voz/texto/Telegram) via `ask_game_help()`:
  1. Screenshot **solo de la ventana del juego** (NO de todas las pantallas)
     - `capture_game_window(pid)`: usa `grim -g` con geometria de `swaymsg -t get_tree`
     - Si fullscreen: captura solo el output/monitor del juego
     - Si ventana: captura solo esa ventana via PID → surface geometry
     - **NUNCA captura otros monitores** — `get_game_window_geometry()` aísla la ventana
  2. Clasificar con modelo local CPU (rapido): sensibilidad BAJA
  3. Web search: `web_search_game()` busca "{game} {question} walkthrough guide"
     - Prioridad: Groq browser_search (gratis ZDR) → Serper API → training data
  4. Enviar screenshot + web results + pregunta a **Cerebras 235B** (ZDR, gratis, 2000 tok/s)
  5. Responder via texto
- [x] Solo usar providers ZDR: `validate_provider_zdr()` bloquea non-ZDR (solo cerebras*, groq*, local*)
- [x] Screenshots de juego solo bajo demanda (el usuario pide), nunca automatico
- [x] Privacy filter sigue activo: sanitiza screenshot caption antes de enviar
- [x] Audit log: `audit_log_screenshot()` escribe a ~/.local/share/lifeos/game-assistant-audit.log
- [x] Dashboard toggle "Game Assistant" (default ON)
- [x] **Fix permisos llama-server.env:** `chown 1000:1000` en Containerfile (commit 14fa392)
- [x] **Fast kill llama-server al offloadear:** `TimeoutStopSec=10` drop-in instalado (commit 14fa392)
- [ ] **HITO FASE G:** Reabierto. El host real mostro falsos positivos, override stale y degradacion a CPU fuera de juego. El repo ya tiene fix, pero no cuenta como cerrado hasta desplegarlo y revalidarlo en laptop real.

**BUGS CRITICOS ENCONTRADOS (2026-03-24) — CORREGIDOS:**

| Bug | Causa Raiz | Fix |
|-----|-----------|-----|
| **llama-server no se reiniciaba** | `systemctl --user restart llama-server` pero el servicio es del sistema (`/usr/lib/systemd/system/`) | Nuevo helper script `lifeos-llama-gpu-layers.sh` que usa `sudo` + sudoers NOPASSWD |
| **Override de GPU layers no leido** | Escribia a `~/.config/lifeos/llama-server.env.override` que nadie lee. El servicio tiene `ProtectHome=true` | Helper crea systemd drop-in en `/etc/systemd/system/llama-server.service.d/99-game-guard-gpu-layers.conf` |
| **Modelo seguia en VRAM mientras se jugaba** | Consecuencia de los 2 bugs anteriores: game_guard detectaba el juego pero no podia hacer nada | Ahora: helper → daemon-reload → restart llama-server con LIFEOS_AI_GPU_LAYERS=0 |

**BUGS ENCONTRADOS (2026-03-27):**

| Bug | Causa Raiz | Fix | Estado |
|-----|-----------|-----|--------|
| **persist_gpu_layers() fallaba por permisos** | `/etc/lifeos/llama-server.env` owned by root, lifeosd corre como uid 1000 | `chown 1000:1000` en Containerfile tras COPY | Corregido en Containerfile, fix inmediato: `sudo chown lifeos:lifeos /etc/lifeos/llama-server.env` |
| **llama-server tarda ~90s en morir al offloadear** | llama-server no responde a SIGTERM rapido con modelo cargado en GPU. Systemd espera TimeoutStopSec default (90s) | `TimeoutStopSec=10` drop-in instalado | Corregido |

**BUGS CRITICOS ENCONTRADOS (2026-03-28) — CORREGIDOS:**

| Bug | Causa Raiz | Fix |
|-----|-----------|-----|
| **Context overflow: "request (6145) exceeds context (6144)"** | `LIFEOS_AI_CTX_SIZE=6144` era demasiado bajo — el system prompt de Axi (~4K tokens) + herramientas consumian todo el contexto sin dejar espacio para el mensaje del usuario | Subido a `16384` en: llama-server.env, llm-providers.toml, llm_router.rs (fallback), experience_modes.rs (basic→4096, pro→8192, builder→16384), dashboard slider |
| **Game guard desync: GPU stuck en CPU mode sin juego** | `persist_gpu_layers()` escribia/restauraba en el env PRINCIPAL, pero el drop-in `99-game-guard-gpu-layers.conf` cargaba un archivo SEPARADO (`llama-server-game-guard.env`) que nunca se limpiaba. Al cerrar el juego, el override stale seguia forzando `GPU_LAYERS=0` | Reescrito `persist_gpu_layers()`: ahora CREA el override env al detectar juego y lo BORRA al cerrar. Nunca toca el env principal |
| **Reasoning loop degenerado: modelo vomita chain-of-thought** | Qwen3.5-2B en reasoning mode (budget infinito) generaba tokens `<think>` como texto plano (sin tags), consumiendo todo `--n-predict` sin producir respuesta visible. El modelo 2B es demasiado pequeno para razonar | Triple fix: (1) `--reasoning-budget 0` en llama-server service, (2) `strip_think_tags()` mejorado para manejar tags sin cerrar, (3) nueva funcion `strip_reasoning_loop()` que detecta y limpia respuestas con oraciones repetidas 3+ veces |
| **Typing indicator expiraba en Telegram** | Telegram cancela "typing..." despues de ~5 segundos, pero el LLM local tarda mas en generar respuesta | Nuevo helper `with_typing()` que re-envia `ChatAction::Typing` cada 4 segundos hasta que la respuesta llega. Aplicado en todos los handlers: texto, /do trust, /btw, voz, foto, video |
| **Modelo 2B insuficiente para conversacion** | Qwen3.5-2B no podia mantener dialogo coherente — entraba en loop de reasoning incluso para un simple "Hola" | Upgrade a Qwen3.5-4B como modelo local default. 4B mantiene conversacion real, ocupa ~3.5 GB VRAM (deja ~8.5 GB para gaming) |

**Archivos del fix:**
- `daemon/src/game_guard.rs` — `persist_gpu_layers()` ahora usa `sudo lifeos-llama-gpu-layers.sh`
- `image/files/usr/local/bin/lifeos-llama-gpu-layers.sh` — helper script privilegiado
- `image/files/etc/sudoers.d/lifeos-llama-server` — NOPASSWD para el helper
- `image/files/etc/polkit-1/rules.d/50-lifeos-llama-server.rules` — polkit backup rule
- `image/Containerfile` — COPY + chmod de los archivos nuevos

**Seguridad:**
- Game mode detectado por proceso real del sistema (/proc/*/comm), no por API manipulable
- Atacante remoto no puede crear procesos locales para forzar game mode
- Screenshots solo se envian cuando el usuario pide ayuda (consent explicito)
- El sudoers entry solo permite ejecutar UN script especifico, no shell arbitrario
- Solo providers ZDR (Cerebras/Groq) — zero data retention
- Si el screenshot contiene datos sensibles (el privacy filter lo detecta), se bloquea

**Rendimiento durante gaming:**
| Componente | GPU mode | CPU mode (gaming) |
|-----------|----------|-------------------|
| Modelo local (4B) | ~150-200 tok/s | 8-30 tok/s (solo clasificacion) |
| Respuestas de gameplay | Local | Cerebras 235B a 2000 tok/s |
| VRAM liberada | 0 | ~3.5 GB |
| Latencia respuesta | ~200ms | <2s (Cerebras via internet) |

### Fase H — Loop Iterativo de Desarrollo (proxima prioridad)

**Objetivo:** Que Axi pueda escribir codigo, compilar, corregir errores, y repetir hasta que funcione — como un desarrollador real.

**Por que es critico:** Hoy el supervisor ejecuta un plan lineal de 2-6 pasos y se detiene. Si el codigo no compila, no vuelve a intentar. OpenClaw ya tiene self-improvement. Devin itera hasta 67% PR merge rate. Sin esto, LifeOS no puede desarrollar software autonomamente.

**Benchmark a superar:** OpenClaw (escribe sus propios skills, hot-reloads), Devin (67% merge rate, auto-debugging), Replit Agent 3 (200 min de ejecucion continua).

- [x] **Evaluate-Fix Loop:** Despues de cada paso de ejecucion, evaluar resultado (compilo? tests pasan? output esperado?). Si falla, alimentar el error completo al LLM y generar paso correctivo automatico
- [x] **Max iteraciones configurables:** Default 5 iteraciones antes de escalar a humano. Evita loops infinitos
- [x] **Build verification:** Auto cargo check tras WriteFile de archivos .rs (commit 14fa392: enforced en supervisor execute_step)
- [x] **Error context enrichment:** Cuando un build falla, extraer el error exacto del compilador, las lineas relevantes del codigo, y el contexto del archivo. Enviar todo al LLM para correccion precisa
- [x] **Diff preview antes de aplicar:** diff_summary() wired into TaskCompleted notification (commit 14fa392)
- [x] **Streaming de progreso:** Enviar chunks de progreso a Telegram durante ejecucion larga ("Compilando... 3/5 tests pasan... corrigiendo error en linea 42...")
- [x] **Strict vision filtering en LLM router:** Error claro NO_VISION_AVAILABLE cuando no hay provider de vision (commit 14fa392)
- [x] **System prompt con personalidad Axi:** Prompt reescrito con nombre, personalidad Brand Guide, instrucciones de vision (commit 14fa392)
- [x] **Ocultar tags de modelo al usuario:** Tags movidos a log::debug, no se muestran en Telegram (commit 14fa392)
- [x] **Configurar Gemini API key como vision fallback gratis:** Gemini Flash provider ya existe en llm_router.rs con supports_vision=true. El usuario solo necesita setear GEMINI_API_KEY en llm-providers.env
- [x] **Coherencia entre modelos:** System prompt con personalidad Axi se inyecta a todos los providers via telegram_tools (commit 14fa392)
- [x] **HITO FASE H:** Evaluate-fix loop con max iteraciones, build verification, error enrichment, streaming de progreso, strict vision filtering, personalidad Axi, coherencia entre modelos — todo implementado y funcional

### Fase I — Auto-Aprobacion + Git Workflow Autonomo

**Objetivo:** Eliminar la friccion de aprobacion manual para que Axi pueda trabajar sin interrupciones en un sandbox seguro.

**Por que es critico:** Cada write_file requiere aprobacion manual via Telegram. Para un proyecto real con 50 archivos modificados, esto mata la productividad. OpenClaw auto-aprueba dentro de skills. Devin trabaja en sandbox cloud sin pedir permiso.

**Benchmark a superar:** Devin (trabaja en sandbox sin aprobacion), Cursor Background Agents (ejecutan en paralelo sin bloquear).

- [x] **Trust mode para Telegram:** `/do trust:` implementado en telegram_bridge.rs (commit 14fa392)
- [x] **Branch por tarea:** `create_task_branch()` wired en supervisor para trust-mode (commit dee2ed0)
- [x] **Auto-commit con mensaje semantico:** `auto_commit()` wired into supervisor task completion (commit 14fa392)
- [x] **PR creation:** `create_pr()` wired after successful trust-mode tasks (commit dee2ed0)
- [x] **Post-task diff summary:** `diff_summary()` integrada en notificaciones de TaskCompleted (commit 14fa392)
- [x] **Rollback automatico:** `git checkout .` + `checkout_main()` on task failure (commit dee2ed0)
- [x] **Workspace persistence:** Worktree persistente entre pasos — se crea una vez al inicio de la tarea y se reutiliza en todos los SandboxCommand steps
- [x] **Tray icon de Axi: retry al boot:** Retry loop 30s + dynamic Wayland socket discovery (commit 14fa392)
- [x] **Tray icon: health monitor + re-spawn:** Loop con re-spawn + 5s delay entre intentos (commit 14fa392)
- [x] **Icon theme LifeOS completo (77 SVGs):** `generate_brand_assets.sh` genera 77 iconos en 6 categorías freedesktop + index.theme + 2 wallpapers
- [x] **Integrar SVGs al Containerfile:** Output directo a `image/files/usr/share/icons/LifeOS/scalable/` y `image/files/usr/share/backgrounds/lifeos/`
- [x] **Aplicar fuentes Inter + JetBrains Mono en COSMIC:** Configurado en lifeos-apply-theme.sh (commit 14fa392)
- [x] **Wallpaper: re-aplicar tras update si cambio:** lifeos-apply-theme.sh ahora soporta `--force` flag para re-aplicar incluso si ya se aplico la version actual
- [x] **Bluetooth volume desync workaround:** `11-bluetooth-policy.conf` instalado via Containerfile (commit 14fa392)
- [x] **Bluetooth: auto-switch mic input:** wireplumber rule `52-lifeos-bt-mic-autoswitch.conf` — prioridad elevada para nodo BT input, auto-switch al conectar headset
- [x] **Game Guard: llama-server fast kill:** `TimeoutStopSec=10` drop-in instalado (commit 14fa392)
- [x] **HITO FASE I:** Trust mode funcional, branch por tarea, auto-commit, PR creation, rollback, workspace persistence, wallpaper re-apply, BT mic auto-switch, fuentes Inter/JetBrains, tray icon estable con retry/re-spawn. Iconos pendientes (~80 SVGs requiere diseño visual)

### Fase J — Browser Automation Real + Testing Visual

**Objetivo:** Que Axi pueda abrir un navegador, navegar, verificar que una UI funciona, y corregir si no se ve bien.

**Por que es critico:** Hoy Axi solo puede hacer `fetch_url_text()` (sin JavaScript). No puede abrir localhost:3000, ver si una pagina se renderiza bien, llenar formularios, o hacer login. OpenClaw ya tiene browser headless completo. Claude Computer Use navega cualquier app. Replit Agent 3 abre apps en browser para encontrar bugs.

**Benchmark a superar:** OpenClaw (headless browser, OAuth flows, form filling), Claude Computer Use (pixel-level browser control), Replit Agent 3 (auto-abre app, encuentra bugs, los corrige).

- [x] **Browser automation via CDP:** `browser_automation.rs` usa Chrome DevTools Protocol directamente (sin Playwright). Chromium headless con --remote-debugging-port para CDP
- [x] **Navegacion basica:** Abrir URL, esperar carga, tomar screenshot, extraer texto/DOM
- [x] **Interaccion:** click_element() + fill_input() via CDP, supervisor actions BrowserClick/BrowserFill (commit dee2ed0)
- [x] **JavaScript execution:** evaluate_js_on_page() via CDP, supervisor action BrowserEvalJs (commit dee2ed0)
- [x] **Visual verification loop:** Screenshot -> LLM vision analiza ("el boton de login aparece?", "hay errores en la consola?") -> decide si OK o necesita fix
- [x] **Localhost testing:** Despues de escribir codigo web, levantar `cargo run` o `npm dev`, abrir localhost en Playwright, verificar visualmente, tomar screenshot de evidencia
- [x] **Form automation:** click_element() + fill_input() via CDP JavaScript evaluation, con event dispatch para reactivity frameworks
- [x] **Console error detection:** get_console_errors() via CDP JS injection (commit dee2ed0)
- [x] **LibreOffice verification:** `lifeos-libreoffice-verify.py` — Python UNO bridge con 5 comandos: read-cells, verify-formula, check-format, sheet-info, export-pdf. Auto-lanza soffice con socket listener
- [x] **Canvas CDP WebSocket (paridad con OpenClaw):** `cdp_client.rs` — conexion WebSocket persistente a Firefox headless via CDP. Sesion que mantiene cookies/localStorage/login. Reemplaza el approach roto de spawn-por-operacion
- [x] **Persistent browser session:** `BrowserSession` — Firefox se lanza UNA vez y se reutiliza para todas las operaciones. No mas browsers nuevos por cada click
- [x] **Real page-context JS execution:** `Runtime.evaluate` ejecuta JavaScript en la pagina REAL (no en un data: URI separado)
- [x] **DOM interaction nativa:** `DOM.querySelector` + `DOM.getBoxModel` + `Input.dispatchMouseEvent` para clicks precisos por CSS selector
- [x] **Accessibility tree (a2ui):** `Accessibility.getFullAXTree` — extrae elementos UI con roles, nombres, bounding boxes. Equivalente al a2ui() de OpenClaw
- [x] **Cookie/session management:** `Storage.getCookies/setCookies` — mantiene login entre operaciones
- [x] **Multi-tab real:** `Target.createTarget/activateTarget/closeTarget` — tabs reales del browser, no procesos separados
- [x] **Network interception:** `Network.enable` para monitorear requests. `Browser.setDownloadBehavior` para descargas
- [x] **HITO FASE J:** CDP browser automation completo: navegacion, click, fill, JS eval, console errors, visual verification loop, localhost testing, LibreOffice UNO bridge para verificacion de datos sin vision. Canvas CDP WebSocket con sesion persistente, DOM nativo, a2ui, cookies, multi-tab, network interception — paridad con OpenClaw

### Fase K — Self-Improvement + Skill Ecosystem

**Objetivo:** Que Axi pueda escribir sus propias extensiones, mejorar sus propios prompts, y aprender de sus errores permanentemente.

**Por que es critico:** OpenClaw tiene 13,729 community skills y se auto-mejora (escribe sus propios skills, edita sus prompts, hot-reloads). Esto es lo que lo hace viral. LifeOS necesita esta capacidad para escalar sin que Hector escriba cada linea.

**Benchmark a superar:** OpenClaw (13,729 skills, self-writes, hot-reload), CrewAI (agentes que aprenden de interacciones pasadas).

- [x] **Skill authoring:** Axi puede crear skills nuevas (archivos ejecutables con manifest) a partir de instrucciones en lenguaje natural
- [x] **Skill testing:** Despues de crear un skill, ejecutarlo en sandbox, verificar output, iterar si falla
- [x] **Prompt self-editing:** Si un patron de tarea falla repetidamente, Axi propone mejoras a su propio system prompt para ese tipo de tarea
- [x] **Hot-reload de skills:** Skills nuevas se activan sin reiniciar el daemon
- [x] **Learning from failures:** Base de datos de errores pasados con solucion aplicada. Antes de planificar, consultar "la ultima vez que intente X, fallo por Y, la solucion fue Z"
- [x] **Skill sharing format:** Formato estandar de skills compatible con un futuro marketplace
- [x] **Self-diagnostic:** Axi puede analizar sus propias metricas (tasa de exito por tipo de tarea) y proponer que areas necesitan mejora
- [x] **HITO FASE K:** Skill authoring, testing en sandbox, prompt self-editing, hot-reload, learning from failures, skill sharing format, self-diagnostic — todo implementado

### Fase L — Multimodalidad Avanzada + Interaccion Natural

**Objetivo:** Que la interaccion con Axi sea tan natural como hablar con una persona — voz continua, vision en tiempo real, contexto persistente.

**Por que es critico:** Google Project Astra procesa video en tiempo real con latencia casi cero. Apple Intelligence entiende contexto de pantalla. OpenClaw tiene wake word + push-to-talk overlay en macOS. La barra de calidad para "wow" sube cada mes.

**Benchmark a superar:** Project Astra (video real-time, multi-idioma), Apple Intelligence (contexto de pantalla), OpenClaw macOS (menu bar, wake word, push-to-talk).

- [x] **Conversacion por voz continua:** Wake word rustpotter + ventana de 30s de escucha continua post-respuesta (CONTINUOUS_CONVERSATION_SECS). Dialogo multi-turno sin necesidad de repetir wake word
- [x] **TTS emocional:** TtsEmotion enum (Neutral/Urgent/Confirmation/Question/Calm) con detect_emotion() por keywords + variacion de --length-scale y --sentence-silence en Piper
- [x] **Screen context awareness:** Cuando el usuario pregunta algo, Axi automaticamente toma screenshot y lo usa como contexto. "Que es esto?" → screenshot → LLM vision → respuesta
- [x] **Real-time screen monitoring:** Modo opcional donde Axi observa cambios en pantalla cada N segundos y puede reaccionar ("detecte que tu build fallo en la terminal, quieres que lo investigue?")
- [x] **Multi-turn conversation memory:** Historial de conversacion persistente entre sesiones. "Recuerdas lo que hablamos ayer sobre la API?" → si, consulta memoria
- [x] **Desktop widget overlay:** mini_widget.rs re-habilitado como togglable via overlay config `mini_widget_visible`. GTK4 orb flotante 48x48, color por estado Axi, click abre dashboard, drag to reposition
- [x] **Notification toasts nativos:** Usar sistema de notificaciones de COSMIC/GNOME para alertas no intrusivas
- [x] **HITO FASE L:** Wake word rustpotter + conversacion continua 30s + TTS emocional + screen context awareness + multi-turn memory + desktop widget overlay + notificaciones nativas. Pendiente: modelo wake word personalizado (requiere voz del usuario)

### Fase M — Plataforma Autonoma Completa

**Objetivo:** LifeOS como plataforma donde Axi puede clonar repos, desarrollar proyectos completos, desplegarlos, y monitorearlos — todo sin intervencion.

**Por que es critico:** Este es el "efecto wow" que necesitamos para competir. Devin cobra $20/mes y tiene 67% merge rate. Si LifeOS puede hacer lo mismo GRATIS, local-first, con privacidad, sobre tu propio hardware — es el killer feature.

**Benchmark a superar:** Devin (autonomous software engineer), Replit Agent 3 (idea → deployed app en <1 hora), Cursor Background Agents (parallel autonomous coding).

- [x] **Project scaffolding:** "Crea un proyecto Next.js con auth, base de datos y Stripe" → Axi genera estructura, instala deps, configura, y verifica que arranca
- [x] **Git clone + understand:** Clonar un repo, analizar su estructura, entender la arquitectura, y reportar "este repo es un API REST en Python con FastAPI, tiene 3 modelos, 12 endpoints..."
- [x] **Multi-file editing:** Editar multiples archivos en una sola tarea coordinada, manteniendo consistencia (si renombro una funcion, actualizar todas las referencias)
- [x] **Test generation:** Escribir tests automaticamente para codigo existente. Ejecutarlos y reportar cobertura
- [x] **Deploy pipeline:** Configurar y ejecutar deploy (Docker build + push, o rsync, o Vercel CLI, segun el proyecto)
- [x] **Monitoring post-deploy:** Despues de deployer, hacer health checks periodicos. Si el servicio cae, notificar y proponer fix
- [x] **Parallel task execution:** Multiples tareas de desarrollo en paralelo (branch A: frontend, branch B: backend) con merge al final
- [x] **Code review agent:** Antes de merge, un agente Reviewer analiza el diff, busca bugs, sugiere mejoras
- [x] **Documentation generation:** Generar/actualizar README, API docs, y changelogs automaticamente basados en los cambios
- [x] **HITO FASE M:** Project scaffolding, git clone + understand, multi-file editing, test generation, deploy pipeline, monitoring post-deploy, parallel tasks, code review agent, docs generation — todo implementado. Pendiente: demo video end-to-end via Telegram
