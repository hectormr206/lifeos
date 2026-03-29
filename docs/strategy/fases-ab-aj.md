# Fases AB-AL — Roadmap Activo + Vision Futura

Este archivo es parte de la Estrategia Unificada de LifeOS. Ver [docs/strategy/](.) para el indice.

---

## OpenClaw vs LifeOS: Analisis de Paridad (ingenieria inversa, 2026-03-28)

### Gaps criticos a cerrar (de OpenClaw)

| Gap | Severidad | En OpenClaw | En LifeOS | Fase |
|-----|-----------|-------------|-----------|------|
| Gateway WS control plane | ALTO | WS tipado, roles/scopes, event bus con seq | REST-only, polling | AB |
| Session durability + compaction | ALTO | Transcripts JSONL, compaction, tool truncation | Ad-hoc en memoria | AB |
| Deterministic channel routing | MEDIO | 8 niveles prioridad, session keys | Per-bridge hardcoded | AB.3 |
| Plugin SDK + boundaries | MEDIO | SDK publico, baseline CI, contract tests | Skills sin SDK formal | AC |
| Config migration + doctor | MEDIO | Audit trail, lastKnownGood, doctor incremental | Basico | AB.4 |
| Architecture guardrails | MEDIO | 6+ scripts custom en CI | Solo fmt+clippy | AD |

### Ventajas de LifeOS sobre OpenClaw (17 capacidades unicas)

| Capacidad | Detalle |
|-----------|---------|
| **ES el OS** | Acceso a kernel, systemd, bootc, hardware — irreplicable |
| **Immutabilidad + rollback** | bootc atomic updates, 3 canales |
| **GPU Game Guard** | Auto-offload LLM a CPU cuando detecta juego |
| **Meeting assistant** | Auto-detect triple, transcripcion, diarization, resumen |
| **Health monitoring** | 12 checks (CPU/GPU/SSD/battery/ergonomia/audio/privacy) |
| **Security AI daemon** | 4 detectores, auto-isolation, forensic reports |
| **Voz local completa** | Wake word + Whisper + Piper + TTS emocional + conversacion continua |
| **Computer use real** | ydotool/xdotool, 14 funciones, vision-guided |
| **Desktop automation** | Visual grounding, action loop, workspace aislado, kill switch |
| **Gaming agent** | Game state analysis, sugerencias, virtual gamepad uinput |
| **Knowledge graph local** | Entity graph, 5 ingestores, temporal reasoning, privacy layers |
| **Battery manager** | sysfs + UPower, charge thresholds, NVIDIA RTD3 |
| **Privacy filter** | 4 niveles sensibilidad, routing por proveedor, audit |
| **Translation engine** | Argos + LLM, subtitulos, voice interpreter |
| **MCP (estandar industria)** | 9 tools, client Y server — OpenClaw usa protocolo propietario |
| **OCR local** | Tesseract multilingue sin API |
| **Presencia/biometricas** | Fatiga, postura, breaks, hidratacion, vista 20-20-20 |

---

### Fase AB — Gateway WebSocket + Session Durability

**Objetivo:** Plano de control WebSocket bidireccional con sesiones durables, protocolo versionado, y event streaming. Prerequisito para UX rica.

**AB.1 — WebSocket Control Plane**
- [x] WebSocket endpoint `ws://127.0.0.1:8081/ws` en Axum (coexiste con REST)
- [x] Protocol versioning: `connect` frame con protocolVersion, role, scopes[], capabilities[]
- [x] Auth por frame: primer frame = `connect` con token. Timeout 5s. Cierre duro si invalido
- [x] Roles: `operator` (dashboard, CLI, bridges) y `node` (futuro multi-dispositivo)
- [x] Event streaming: push de task.started/completed/failed, agent.typing, llm.streaming, health.alert, game_guard.changed
- [x] Sequence numbers para resync en reconexion
- [x] Slow consumer handling: drop + snapshot si >30s sin consumir

**AB.2 — Session Durability**
- [x] Session store con sessionId estable y sessionKey tipado (`agent:axi:telegram:dm:123456`)
- [x] Transcript persistente JSONL en `~/.local/share/lifeos/sessions/<sessionId>.jsonl`
- [x] Compaction via LLM cuando transcript supera N tokens
- [x] Tool result truncation (>2000 tokens)
- [x] Session metadata: lastChannel, lastPeerId, deliveryContext, lastActiveAt
- [x] Disk budget configurable con auto-prune de sesiones viejas

**AB.3 — Unified Channel Routing**
- [x] Session key contract para todos los bridges: `agent:axi:<channel>:<scope>:<peerId>`
- [x] Cross-channel context: misma sesion entre Telegram/voz/CLI
- [x] Inbound dedupe por (channel, peerId, messageId)
- [x] Routing determinista: respuesta va al canal de origen

**AB.4 — Doctor Mejorado**
- [x] Config migration automatica entre versiones
- [x] Config backup rotado (max 5) antes de escribir
- [x] Stale reference cleanup (skills/providers que ya no existen)
- [x] Health check at boot con reporte via evento

### Fase AC — Plugin SDK + Capability Registry

**Objetivo:** Plataforma de extensiones con contratos formales, SDK, registry, y boundaries.

**AC.1 — Skill Manifest v2**
- [x] JSON Schema para skill.json: name, version, capabilities[], permissions[], triggers[]
- [x] Capabilities tipadas: tool, channel, provider, hook, sensor
- [x] Permissions declaradas: filesystem.read/write, network, shell.execute, llm.query
- [x] Validacion al cargar: manifest invalido = skill no carga

**AC.2 — Skill Registry Central**
- [x] SkillRegistry centralizado en daemon
- [x] Runtime snapshot inmutable por tarea del supervisor
- [x] Conflict resolution: user > workspace > system > bundled
- [x] Hot-reload seguro con verificacion de referencias activas

**AC.3 — Boundaries Arquitectonicas**
- [x] Check CI: skills no importan modulos internos del daemon
- [x] Contract tests: registry acepta validos, rechaza invalidos
- [x] Baseline de superficie publica de APIs
- [x] `life skills doctor` para detectar/reparar skills rotos

**AC.4 — Discovery Seguro**
- [x] Rutas: user skills > workspace skills > system skills
- [x] Ownership check: no cargar de directorios world-writable
- [x] Signature opcional en manifest para skills verificados

### Fase AD — Anti-Breakage Engineering

**Objetivo:** Guardrails CI, config contracts, y observabilidad para prevenir regresiones.

**AD.1 — Guardrails Custom**
- [x] check-dead-code.sh: modulos .rs no referenciados ni feature-gated
- [x] check-orphan-api-routes.sh: endpoints sin test ni uso documentado
- [x] check-event-bus-consumers.sh: eventos sin consumidor
- [x] check-skill-boundaries.sh: skills no importan daemon/src/

**AD.2 — Config como Contrato**
- [x] JSON Schema generado desde structs Rust de config
- [x] Config baseline doc autogenerado. CI detecta drift
- [x] Migration framework: lista ordenada de transformaciones version_from → version_to

**AD.3 — CI Mejorada**
- [x] Scope-aware CI: solo compilar/testear lo que cambio
- [x] Regression tests nombrados con ID del bug de origen
- [x] Live test suite: daemon real + HTTP requests + verificacion

**AD.4 — Observabilidad de Runtime**
- [x] Structured logging con campos queryables (session_id, task_id, provider, latency_ms)
- [x] Metrics exporter Prometheus-compatible
- [x] `life audit query --since 24h --type llm_call`

**Orden recomendado:** AE (first-boot, rapido) → AD (anti-breakage) → AB (gateway) → AC (ecosistema) → AF (canales extra)

### Fase AE — First-Boot User Creation + Welcome Wizard

**Objetivo:** Que al instalar LifeOS, el usuario cree su propia cuenta y contraseña — como cualquier OS moderno. Sin usuarios/passwords hardcodeados.

**Por que es critico:** Hoy el ISO crea usuario `lifeos` con password `lifeos`. Cualquiera que descargue el ISO conoce las credenciales. Es un problema de seguridad grave para distribucion publica.

**Investigacion (2026-03-28):** Anaconda (el instalador de Fedora) ya tiene un "spoke" de creacion de usuario. Si el kickstart no incluye la linea `user`, Anaconda lo pide interactivamente. Bazzite, Aurora y Universal Blue hacen exactamente esto. `cosmic-initial-setup` (paquete Fedora `cosmic-initial-setup-1.0.8`) da wizard post-login para tema/layout/accesibilidad.

**AE.1 — Anaconda Interactive User Creation (ISO builds)**
- [x] **Quitar usuario hardcodeado del kickstart:** Remover `user --name=lifeos --password=...` de `generate-iso-simple.sh` y `generate-iso.sh`. Anaconda mostrara el spoke "User Creation" obligatorio
- [x] **Quitar `chage -d 0` del %post:** Ya no es necesario si el usuario elige su password durante la instalacion
- [x] **Actualizar mensajes de build:** Quitar "user: lifeos / password: lifeos" de los mensajes de output
- [x] **Adaptar sudoers:** El sudoers actual usa `lifeos ALL=(root)`. Para soportar cualquier username, cambiar a `%wheel ALL=(root) NOPASSWD:` para los comandos especificos, ya que el usuario se agrega a wheel durante la instalacion

**AE.2 — cosmic-initial-setup (Post-Login Personalization)**
- [x] **Verificar que cosmic-initial-setup esta en la imagen:** Confirmar que el paquete viene con `@cosmic-desktop-environment` o agregarlo al Containerfile
- [x] **Welcome wizard post-login:** Al primer login, cosmic-initial-setup muestra: accesibilidad, layout (panel arriba/abajo + dock), seleccion de tema
- [ ] **LifeOS-specific pages:** FUTURO (requiere GUI libcosmic) Considerar extender el wizard con paginas para: configurar Telegram bot token, elegir modelo de IA preferido, nivel de privacidad

**AE.3 — Fallback para builds raw/qcow2/vmdk (sin Anaconda)**
- [x] **Mantener `enforce_password_change` en first-boot.sh:** Para deployments donde no hay Anaconda (testing, VMs), el usuario default `lifeos` sigue existiendo pero se fuerza cambio de password
- [x] **Documentar claramente:** Builds raw/qcow2 son solo para desarrollo/testing, no para usuarios finales

**AE.4 — Sudoers Dinamico**
- [x] **Migrar de `lifeos ALL=` a `%wheel ALL=`:** Para que cualquier username funcione con los permisos de Axi
- [x] **Polkit rules por grupo:** Actualizar las reglas polkit para usar grupo `wheel` en vez de usuario `lifeos` especifico
- [x] **Daemon ownership:** lifeosd debe correr como el UID del usuario creado, no hardcoded UID 1000. O usar un usuario de sistema `axi` dedicado para el daemon

### Fase AF — Canales de Mensajeria Adicionales (Paridad OpenClaw Channels)

**Objetivo:** OpenClaw soporta 21+ canales de mensajeria. LifeOS tiene 4 (Telegram, WhatsApp, Matrix, Signal). Agregar los canales mas demandados.

**AF.1 — Slack Integration**
- [x] Slack Bot API via `slack-api` crate o HTTP
- [x] Soporte texto, threads, reactions, file uploads
- [x] Feature flag `slack`

**AF.2 — Discord Integration**
- [x] Discord Bot via `serenity` crate
- [x] Soporte texto, embeds, slash commands, voice channels
- [x] Feature flag `discord`

**AF.3 — Email como Canal Conversacional**
- [x] El email_bridge existente (IMAP+SMTP) ya lee/envia, pero no es conversacional
- [x] Convertir emails entrantes en mensajes del agentic loop (como Telegram)
- [x] Responder emails en hilo manteniendo contexto

**AF.4 — SMS/iMessage (futuro)**
- [ ] SMS via Twilio — FUTURO (requiere API externa) API o similar
- [ ] iMessage — FUTURO (requiere bridge de terceros) bridge de terceros (no hay API oficial)

**Prioridad:** Slack > Discord > Email conversacional > SMS. Los 2 primeros cubren el 90% de la demanda empresarial.

### Gaps Menores (documentados, ya resueltos o incrementales)

| Gap | Estado | Nota |
|-----|--------|------|
| **Session target validation** | RESUELTO | Cron failure tracking en AG.2 |
| **Inbound message dedupe** | RESUELTO | message_dedupe.rs en AG.1 |
| **Transcript export** | RESUELTO | export_conversation tool en AG.3 |
| **Pairing system** | FUTURO | Implementar cuando soporte multi-dispositivo |
| **Native apps (iOS/Android)** | FUTURO | Requiere equipo, post-lanzamiento |

### Fase AJ — LifeOS Cloud: Hosting Multi-Tenant + Acceso Movil 24/7 (FUTURA)

**Objetivo:** Ofrecer LifeOS como servicio cloud para que usuarios accedan a Axi desde sus celulares 24/7 sin necesidad de tener su PC encendida. Modelo SaaS con tiers gratuito y de pago.

**Por que es critico para crecimiento:** La mayoria de usuarios interactuan desde el celular. Tener la PC encendida 24/7 no es viable para la mayoria. Un servicio cloud con acceso via Telegram/PWA resuelve ambos problemas.

**Investigacion completada (2026-03-28):** Analisis de costos GPU vs CPU-only, precios Hetzner/Vast.ai/RunPod, limites free tier Cerebras/Groq, arquitectura multi-tenant Podman, competencia (OpenClaw $24-40/mes, Devin $20/mes), sync local-cloud con cr-sqlite, privacidad con AMD SEV/Intel TDX.

**Descubrimiento clave:** CPU-only + Cerebras/Groq (zero data retention) = costo por usuario ~$0.50-2/mes. No se necesita GPU en servidores. El LLM router ya rutea a 13+ providers remotos.

**AJ.1 — Infraestructura Multi-Tenant**
- [ ] Imagen Docker/Podman de `lifeosd` sin desktop (solo daemon + bridges) — <200MB
- [ ] Podman rootless: un contenedor por usuario con namespaces aislados
- [ ] Orquestacion: auto-start al recibir mensaje de Telegram, idle timeout 30min, auto-stop
- [ ] Almacenamiento: bind-mount `/data/users/{userId}/` por usuario con SQLite propias
- [ ] Hetzner CX23 (EUR 3.49/mes) soporta ~50+ usuarios con uso tipico

**AJ.2 — Tiers de Servicio**

| Tier | Precio | Incluye | COGS estimado |
|------|--------|---------|---------------|
| **Self-hosted** | Gratis | LifeOS completo en tu hardware | $0 |
| **Free Cloud** | $0 | Telegram bot, 50 msgs/dia, BYOK para LLM | ~$0.50/user |
| **Starter** | $5/mes | 500 msgs/dia, Cerebras inference incluido, 5GB, sync | ~$2/user |
| **Pro** | $15/mes | Ilimitado, modelos rapidos, 25GB, PWA dashboard, sync bidireccional | ~$4/user |
| **GPU** | $30/mes | Todo Pro + GPU dedicada (Hetzner GEX44, time-sliced entre ~20 users) | ~$9/user |

Break-even: 12 usuarios Starter cubren los $60/mes de presupuesto actual.

**AJ.3 — Sync Local ↔ Cloud (cr-sqlite)**
- [ ] Integrar cr-sqlite para sync bidireccional de memory.db, calendar.db, knowledge_graph
- [ ] Syncthing "untrusted device" mode para archivos (datos cifrados en el servidor)
- [ ] Flujo: usuario usa Axi en Telegram (cloud) de dia, laptop sincroniza al encender

**AJ.4 — PWA Dashboard Movil**
- [ ] Dashboard web responsive que habla con la API REST de lifeosd
- [ ] Instalable en home screen (iOS/Android)
- [ ] Push notifications via service workers
- [ ] Complementa a Telegram (dashboard para config, metricas, historial — chat en Telegram)

**AJ.5 — Privacidad en Cloud**
- [ ] Cifrado at-rest con clave derivada del password del usuario (el servidor no ve datos en disco)
- [ ] LLM inference solo via providers zero-data-retention (Cerebras, Groq)
- [ ] Tier premium futuro: AMD SEV / Intel TDX para VMs con cifrado en RAM
- [ ] Logs sin contenido de usuario (solo metadata: timestamps, token counts)

**AJ.6 — Facturacion y Onboarding**
- [ ] Stripe para pagos recurrentes
- [ ] Onboarding: usuario se registra, vincula Telegram, Axi responde en <1 minuto
- [ ] Trial 14 dias de Starter sin tarjeta

**Competencia directa:**
- OpenClaw managed: $24-40/mes SIN inference — LifeOS Starter es 5x mas barato CON inference
- Devin: $20/mes base + $2.25/ACU — solo coding, no asistente de vida
- Replit Agent: $25/mes — solo desarrollo web

**Prerequisitos:** Fases AB (gateway WS para streaming) y AC (plugin SDK) ya completadas. Falta: imagen Docker headless, orquestacion Podman, cr-sqlite, PWA, Stripe.

**Prioridad:** FUTURA — ejecutar cuando haya demanda validada (50+ usuarios interesados).

### Fase AK — Project Axolotl: Self-Healing Engine (PROXIMA PRIORIDAD)

**Objetivo:** Que Axi sea verdaderamente indestructible — como un ajolote que regenera cualquier parte de su cuerpo. Si Axi se rompe a si mismo (por self-improvement, config corrupta, o cualquier razon), debe auto-repararse sin intervencion humana, sin reiniciar el ordenador, sin ejecutar comandos manuales.

**Por que es critico:** OpenClaw tiene `doctor` y `repair`, pero cuando el agente se modifica a si mismo lo suficiente, puede entrar en un "death spiral" donde ni siquiera su propio reparador funciona. Esto le paso al usuario con OpenClaw en WSL. LifeOS NUNCA debe llegar a ese estado — la esencia del ajolote es que siempre se regenera.

**Investigacion (2026-03-28):** Analisis de patrones de auto-reparacion: Erlang supervisors ("let it crash"), Kubernetes liveness/readiness probes, circuit breaker pattern, bootc immutable rollback, biologia del ajolote (5 fases de regeneracion), OpenClaw death spirals documentados, SQLite WAL crash resilience.

**La metafora del ajolote mapeada a software:**

| Fase biologica | Equivalente software | Componente LifeOS |
|---|---|---|
| **Epitelio de herida** (sello inmediato) | Watchdog detecta crash, systemd reinicia con config anterior | systemd WatchdogSec + Restart |
| **Capa apical (AEC)** (centro de señalizacion) | Health probes diagnostican que esta roto y que estrategia usar | /api/v1/health/deep + HealthMonitor |
| **Desdiferenciacion** (celulas revierten a estado madre) | Rollback a checkpoint anterior — config, prompts, skills | Git versionado en /var/lib/lifeos/config.git |
| **Formacion de blastema** (celulas progenitoras) | Config factory-default embebida en el binario, siempre disponible | DEFAULT_CONFIG compilado con include_str! |
| **Rediferenciacion** (celulas se especializan de nuevo) | El loop de self-improvement re-aprende gradualmente | SelfImprovingDaemon con guardrails |

**AK.0 — Watchdog systemd (epitelio de herida)**
- [x] Agregar `WatchdogSec=30` y `Restart=on-watchdog` a `lifeosd.service`
- [x] Background task en main.rs que envia `sd_notify::Watchdog` cada 15 segundos
- [x] `StartLimitBurst=5` + `StartLimitIntervalSec=300` — max 5 reinicios en 5 min, despues para
- [x] Si el daemon se congela (deadlock tokio, loop infinito en LLM), systemd lo mata y reinicia

**AK.1 — Boot Counter + Safe Mode (prevencion death spiral)**
- [x] `/var/lib/lifeos/boot_count`: incrementa en cada arranque, reset a 0 tras 10 min estable
- [x] Si `boot_count > 3` al arrancar → entrar en **safe mode** automaticamente
- [x] Safe mode desactiva: SelfImprovingDaemon, PromptTuner, SkillGenerator, AutonomousAgent
- [x] Safe mode mantiene: API, Telegram (respond-only), health checks, comandos basicos
- [x] Notificacion Telegram: safe mode' cuando quieras"
- [x] Comando `life safe-mode status` y `life safe-mode exit`

**AK.2 — Config Time Machine (git versionado)**
- [ ] `/var/lib/lifeos/config.git/`: repositorio git local con toda la config mutable
- [x] Archivos versionados: config.toml, llm-providers.toml, prompts/, skills/, identity.json
- [x] `checkpoint(msg)`: git add + commit ANTES de cualquier auto-modificacion
- [x] `validate_and_commit(msg)`: checkpoint + validar. Si falla, auto-rollback a HEAD~1
- [x] `rollback_to_last_good()`: buscar el commit mas reciente taggeado `known-good`
- [x] `tag_known_good()`: se tagea automaticamente tras 10 min de health checks exitosos
- [x] **Probation timer**: si el daemon crashea dentro de 5 min de una auto-modificacion, rollback automatico al checkpoint pre-modificacion

**AK.3 — Circuit Breaker para Self-Modification**
- [x] Estado: Closed (normal) → Open (tras 3 fallos) → HalfOpen (tras cooldown 6h)
- [x] Closed: auto-modificaciones proceden con checkpoint/validate/rollback
- [x] Open: TODAS las auto-modificaciones bloqueadas. Axi corre en modo estable
- [x] HalfOpen: permite 1 modificacion de prueba. Si exito → Closed. Si fallo → Open con backoff exponencial (max 48h)
- [x] Integrar con self_improving.rs, prompt tuner, skill generator

**AK.4 — Health Probes (diagnostico estructurado)**
- [x] `/api/v1/health/alive` — solo "estoy vivo?" (sin DB, sin config, solo event loop)
- [x] `/api/v1/health/ready` — subsistemas inicializados? (config, DBs, LLM router, Telegram)
- [x] `/api/v1/health/deep` — diagnostico completo: integridad SQLite, config hashes, skill manifests, disk space
- [x] Background task cada 60s: deep probe. Si detecta degradacion → trigger rollback (AK.2)

**AK.5 — Factory Default (blastema compilado)**
- [x] `defaults/config.toml`, `defaults/prompts/*.md` embebidos en el binario con `include_str!`
- [x] Secuencia de arranque con cascading fallback:
  1. Config de config.git → 2. Rollback to last-good → 3. .bak files → 4. Factory defaults
- [x] Si llega a factory defaults, notificacion: "Tuve que resetear a configuracion de fabrica. Mis personalizaciones se perdieron pero estoy vivo"
- [x] Factory defaults viven en /usr (inmutable via bootc) — IMPOSIBLE de corromper

**AK.6 — Sentinel (proceso independiente out-of-band)**
- [x] `lifeos-sentinel.service`: proceso separado, minimo, sin dependencias de lifeosd
- [x] Checa `/api/v1/health/alive` cada 30s via curl
- [x] Escalation ladder:
  - 1 fallo: log warning
  - 3 fallos: `systemctl restart lifeosd`
  - 5 fallos: `life doctor --repair` (trigger factory reset si necesario)
  - 10 fallos: notificacion Telegram directa (bypassing lifeosd) diciendo "Axi no puede recuperarse"
- [x] El sentinel NO tiene logica de negocio, NO usa LLM, NO parsea config — es tan simple que no puede romperse

**AK.7 — Proteccion SQLite**
- [x] WAL mode habilitado en todas las DBs (crash resilience nativo)
- [x] `PRAGMA integrity_check` en el deep health probe cada 60s
- [x] Backup automatico cada hora via `sqlite3_backup_init` (hot backup, sin locking)
- [x] Pre-modification snapshot antes de cada ciclo de self-improvement

**Arquitectura completa (5 capas independientes):**
```
Layer 4: Sentinel (out-of-band, proceso separado)
  ↓ Monitorea lifeosd externamente
Layer 3: Factory Default (compilado en el binario, en /usr inmutable)
  ↓ Ultimo recurso, IMPOSIBLE de corromper
Layer 2: Config Time Machine (git local con checkpoints)
  ↓ Rollback automatico tras fallos de auto-modificacion
Layer 1: Health Probes (liveness + readiness + deep diagnosis)
  ↓ Detecta degradacion, trigger rollback
Layer 0: Heartbeat (systemd watchdog)
  ↓ Detecta proceso congelado, reinicio automatico
[Hardware/OS: bootc — rollback del OS completo]
```

**Cada capa es INDEPENDIENTE de las demas.** Si Layer 2 esta rota (git corrupt), Layer 3 funciona. Si el daemon entero no responde, Layer 4 (sentinel) funciona. Si el sentinel tambien fallo, Layer 0 (systemd) funciona. Y debajo de todo, bootc puede rollback el OS completo.

**Diferenciador unico:** Ningun competidor (OpenClaw, Devin, Replit) tiene este nivel de self-healing. OpenClaw tiene doctor+repair pero depende del mismo proceso que esta roto. LifeOS tiene 5 capas independientes — como el ajolote que puede regenerar extremidades completas.

**Prioridad:** ALTA — implementar AK.0 (watchdog) y AK.1 (safe mode) primero, son cambios pequenos con impacto maximo.

---

### Fase AL — Hardening Operativo (inspirado en NemoClaw, complementa Axolotl AK)

**Objetivo:** Cerrar los gaps de seguridad interna, observabilidad de progreso, y experiencia de troubleshooting que NemoClaw (ingenieria inversa 2026-03-29) resuelve bien y que LifeOS aun no cubre.

**Investigacion (2026-03-29):** Analisis profundo de NemoClaw (10 documentos, 953 lineas). NemoClaw es una capa de operacion para OpenShell con fortalezas en onboarding guiado, policy desde dia uno, recovery clasificado, y tests de seguridad del propio sistema. LifeOS es superior en 9 areas (LLM routing, plugins, self-healing, OS control, Telegram, migrations, CI guardrails, privacy filter, bootc), pero NemoClaw expone 6 gaps valiosos.

**AL.1 — SSRF Guard para LLM Router**
- [x] `validate_endpoint(url)` en `llm_router.rs`: rechaza RFC1918, loopback, link-local, metadata (169.254.169.254)
- [x] Solo permitir http:// y https:// como schemes
- [x] Excepcion explicita para 127.0.0.1:8082 (llama-server local)
- [x] Validacion al registrar providers y al cambiar endpoint via API
- [x] Test: endpoint `http://10.0.0.1:8080` debe ser rechazado

**AL.2 — Tests de Seguridad Interna**
- [x] `test_api_keys_not_in_logs`: provider con API key → structured logs no contienen la key
- [x] `test_config_backup_no_secrets`: config con tokens → .bak files no tienen tokens en claro
- [x] `test_bootstrap_token_entropy`: token generado tiene minimo 128 bits de entropia
- [x] `test_telegram_chat_id_enforcement`: mensajes de chat_ids no autorizados son rechazados
- [x] `test_audit_ledger_no_message_content`: audit registra acciones pero no contenido de usuario

**AL.3 — Coverage Ratchet en CI**
- [x] Agregar `cargo-llvm-cov` o `cargo-tarpaulin` al workflow de PR
- [x] Script `check-coverage-ratchet.sh` que compara con ultimo valor y falla si baja >1%
- [x] Badge de cobertura en README (cuando sea publico)

**AL.4 — Progreso Observable en Supervisor**
- [x] Evento WebSocket `task.progress` con `{task_id, step_index, total_steps, step_label, percent}`
- [x] Evento `task.step_completed` con resultado parcial al terminar cada step
- [x] Telegram: tareas con 3+ steps → mensaje "Paso 2/5: ejecutando tests..."
- [x] Dashboard: barra de progreso por tarea activa

**AL.5 — Doctor Mejorado (complementa AK.4)**
- [x] PRAGMA integrity_check en cada SQLite DB
- [x] Test de conectividad a provider LLM activo (timeout 5s)
- [x] Validacion de token de Telegram si configurado
- [x] Verificacion de skill manifests en directorio de skills
- [x] Disk space check (warning <1GB, error <500MB)
- [x] Verificar que llama-server responde en :8082 si provider local activo
- [x] Clasificacion de estados: healthy, degraded, impaired, unreachable, safe_mode

**AL.6 — Guia de Troubleshooting para Usuario Final**
- [x] `docs/user/troubleshooting.md` con formato problema-diagnostico-solucion
- [x] Cubrir: "Axi no responde", "Telegram no conecta", "Modelo local lento", "Permiso denegado", "Actualizacion fallo"
- [x] Cada entrada con comando concreto (`life doctor`, `systemctl status lifeosd`)

**Prioridad:** MEDIA. AL.1 y AL.2 son rapidos y de alto impacto (seguridad). AL.4 mejora UX perceptiblemente. Puede ejecutarse en paralelo con AK.

### NemoClaw vs LifeOS — Resumen Comparativo

| Capacidad | NemoClaw | LifeOS | Ventaja |
|-----------|----------|--------|---------|
| LLM Routing | 6 perfiles estaticos | 13+ providers, privacy-aware, complexity-aware | **LifeOS** |
| Plugin System | JSON simple | SkillManifest v2 con capabilities, permissions, hot-reload | **LifeOS** |
| Self-Healing | Recovery de gateway/sandbox (mismo proceso) | Project Axolotl: 5 capas independientes | **LifeOS** |
| Control de OS | Sandbox limitado (OpenShell) | ES el OS (kernel, systemd, bootc, GPU) | **LifeOS** |
| Telegram | Bridge JS por SSH | Crate Rust integrado, 851 LOC, voz, fotos, grupos | **LifeOS** |
| Schema migrations | JSON plano sin migraciones | ALTER TABLE idempotente en cada modulo SQLite | **LifeOS** |
| CI Guardrails | PR lint + coverage ratchet | 6 scripts custom de arquitectura | **LifeOS** |
| Privacy Filter | No tiene | 4 niveles sensibilidad + audit trail | **LifeOS** |
| Inmutabilidad | No (host mutable) | bootc atomic rollback | **LifeOS** |
| SSRF Guard | Si, bloquea rangos privados | No tiene (gap) | **NemoClaw** |
| Tests seguridad interna | Si (credential leak, injection) | No tiene (gap) | **NemoClaw** |
| Coverage ratchet | Si en CI | No tiene (gap) | **NemoClaw** |
| Progreso observable | Runner con PROGRESS events | Supervisor sin progreso granular (gap) | **NemoClaw** |
| Onboarding AI | Wizard de provider + validacion | Solo onboarding de OS (gap parcial) | **NemoClaw** |

**Conclusion:** LifeOS gana 9 a 5 en capacidades. Los 5 gaps de NemoClaw (SSRF, tests seguridad, coverage, progreso, onboarding AI) son todos resolubles y estan planificados en Fase AL.

---

### Post Fases — Lanzamiento Publico (REQUIERE HUMANO)

- [ ] Grabar video demo de 2 minutos — REQUIERE HUMANO (screen recording + Telegram)
- [ ] Grabar video demo "agente agentico" — REQUIERE HUMANO
- [ ] Actualizar README.md para publico — REQUIERE HUMANO (screenshots reales del dashboard)
- [ ] Hacer repo publico bajo org lifeos-ai — REQUIERE HUMANO (GitHub settings)
- [ ] Post en X/Twitter con video — REQUIERE HUMANO
- [ ] Post en r/linux, r/LocalLLaMA, r/selfhosted, Hacker News — REQUIERE HUMANO
- [ ] Post en comunidades hispanohablantes — REQUIERE HUMANO
- [ ] Preparar ISO descargable para early adopters — REQUIERE HUMANO (`sudo bash scripts/build-iso.sh`)

---

## Vision Futura (NO bloquea lanzamiento, revisar post-launch)

Estas fases se sacaron del roadmap activo porque no son necesarias para que LifeOS compita con OpenClaw al lanzamiento. Se revisaran cuando el producto este estable y en manos de usuarios.

### Firefox AI Local-First (ex-Fase AH, exploratoria)

Extension/sidebar de Firefox para "Ask Axi about this page". Requiere: extension .xpi, endpoint local llama.cpp, permisos por sitio, modo local-first vs remoto. Se documenta para no perder la idea.

### LibreOffice AI + UNO/MCP (ex-Fase AI, exploratoria)

Extension .oxt para Writer/Calc/Impress con resumir, reescribir, traducir, expandir texto. Conecta al modelo local via UNO bridge. Posible branding "Axi for Documents". Se documenta para cuando haya demanda.

### LifeOS Cloud: Hosting Multi-Tenant (ex-Fase AJ, futura)

Servicio cloud para acceso movil 24/7. Podman rootless multi-tenant, CPU-only + Cerebras/Groq, 5 tiers ($0-$30/mes), cr-sqlite sync local-cloud. Ejecutar cuando haya 50+ usuarios interesados. Investigacion completa ya realizada (costos, arquitectura, pricing).

### Pairing System Multi-Dispositivo (futura)

Codigo 8 chars con TTL 1h para vincular nuevo dispositivo/usuario. Prerequisito: soporte multi-dispositivo y cloud hosting.

### Native Apps iOS/Android (futura)

Requiere equipo de desarrollo. PWA es el camino intermedio (ya planificado en AJ.4). App nativa solo si hay revenue para justificar el costo de mantenimiento de 2 app stores.
