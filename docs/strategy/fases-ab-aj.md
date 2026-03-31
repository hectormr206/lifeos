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
| **Meeting assistant** | Auto-detect + grabacion basica. Transcripcion, diarizacion y resumen siguen pendientes de cableado end-to-end |
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
- [ ] Protocol versioning: `connect` frame con protocolVersion, role, scopes[], capabilities[]
- [x] Auth por frame: primer frame = `connect` con token. Timeout 5s. Cierre duro si invalido
- [ ] Roles: `operator` (dashboard, CLI, bridges) y `node` (futuro multi-dispositivo)
- [x] Event streaming: push de task.started/completed/failed, agent.typing, llm.streaming, health.alert, game_guard.changed
- [x] Sequence numbers para resync en reconexion
- [ ] Slow consumer handling: drop + snapshot si >30s sin consumir

**AB.2 — Session Durability**
- [ ] Session store con sessionId estable y sessionKey tipado (`agent:axi:telegram:dm:123456`)
- [ ] Transcript persistente JSONL en `~/.local/share/lifeos/sessions/<sessionId>.jsonl`
- [ ] Compaction via LLM cuando transcript supera N tokens
- [ ] Tool result truncation (>2000 tokens)
- [ ] Session metadata: lastChannel, lastPeerId, deliveryContext, lastActiveAt
- [ ] Disk budget configurable con auto-prune de sesiones viejas

**AB.3 — Unified Channel Routing**
- [ ] Session key contract para todos los bridges: `agent:axi:<channel>:<scope>:<peerId>`
- [ ] Cross-channel context: misma sesion entre Telegram/voz/CLI
- [ ] Inbound dedupe por (channel, peerId, messageId)
- [ ] Routing determinista: respuesta va al canal de origen

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
- [ ] `life skills doctor` para detectar/reparar skills rotos

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
- [ ] `life audit query --since 24h --type llm_call`

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
- [ ] Slack Bot API via `slack-api` crate o HTTP
- [ ] Soporte texto, threads, reactions, file uploads
- [x] Feature flag `slack`

**AF.2 — Discord Integration**
- [ ] Discord Bot via `serenity` crate
- [ ] Soporte texto, embeds, slash commands, voice channels
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
| **Transcript export** | REABIERTO / NO COMPROBADO | No aparecio evidencia clara de `export_conversation` como capacidad real del producto |
| **Pairing system** | PARCIAL | Existe pairing basico en Telegram para usuarios adicionales, pero no el pairing multi-dispositivo mas amplio |

### Fase AG — Mejoras Incrementales de Robustez

**Objetivo:** Cerrar huecos pequenos pero importantes de operacion diaria sin inflar una fase mayor. Esta fase sirve para registrar fixes reales de robustez que hoy si tienen evidencia concreta.

**AG.1 — Inbound Message Dedupe**
- [x] `message_dedupe.rs` evita procesar mensajes duplicados en Telegram usando una llave estable por mensaje

**AG.2 — Validacion Basica de Cron**
- [x] Validacion minima en `telegram_tools.rs`: una expresion cron invalida es rechazada si no tiene 5 campos
- [ ] Validacion cron completa y mas rica: no quedo demostrada una capa mas profunda de lint/normalizacion de cron fuera de ese baseline

**AG.3 — Pairing Basico de Usuarios en Telegram**
- [x] `/pair` genera codigo temporal y el bridge puede redimirlo para agregar usuarios dinamicamente
- [ ] Pairing multi-dispositivo o con metadatos de superficie: sigue siendo futuro

**AG.4 — Export de Conversaciones**
- [ ] No aparecio evidencia clara de un flujo end-to-end de export de transcript/conversation como capability operativa ya disponible
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
- [ ] Comando `life safe-mode status` y `life safe-mode exit`

**AK.2 — Config Time Machine (git versionado)**
- [x] `/var/lib/lifeos/config-checkpoints/`: repositorio git local con toda la config mutable
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
- [x] `/api/v1/health` — reporte agregado de salud del sistema disponible via API
- [ ] `/api/v1/health/alive` — solo "estoy vivo?" (sin DB, sin config, solo event loop)
- [ ] `/api/v1/health/ready` — subsistemas inicializados? (config, DBs, LLM router, Telegram)
- [ ] `/api/v1/health/deep` — diagnostico completo: integridad SQLite, config hashes, skill manifests, disk space
- [ ] Background task cada 60s: deep probe. Si detecta degradacion → trigger rollback (AK.2)

**AK.5 — Factory Default (blastema compilado)**
- [x] `defaults/config.toml`, `defaults/prompts/*.md` embebidos en el binario con `include_str!`
- [x] Secuencia de arranque con cascading fallback:
  1. Config de config.git → 2. Rollback to last-good → 3. .bak files → 4. Factory defaults
- [x] Si llega a factory defaults, notificacion: "Tuve que resetear a configuracion de fabrica. Mis personalizaciones se perdieron pero estoy vivo"
- [x] Factory defaults viven en /usr (inmutable via bootc) — IMPOSIBLE de corromper

**AK.6 — Sentinel (proceso independiente out-of-band)**
- [x] `lifeos-sentinel.service`: proceso separado, minimo, sin dependencias de lifeosd
- [x] Checa `/api/v1/health` cada 30s via curl
- [x] Escalation ladder:
  - 1 fallo: log warning
  - 3 fallos: `systemctl restart lifeosd`
  - [ ] 5 fallos: `life doctor --repair` (trigger factory reset si necesario)
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
- [ ] Evento WebSocket `task.progress` con `{task_id, step_index, total_steps, step_label, percent}`
- [ ] Evento `task.step_completed` con resultado parcial al terminar cada step
- [x] Telegram: tareas con 3+ steps → mensaje "Paso 2/5: ejecutando tests..."
- [ ] Dashboard: barra de progreso por tarea activa

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
- [ ] Cada entrada con comando concreto (`life doctor`, `systemctl status lifeosd`)

**Prioridad:** MEDIA. AL.1 y AL.2 son rapidos y de alto impacto (seguridad). AL.4 mejora UX perceptiblemente. Puede ejecutarse en paralelo con AK.

---

### Fase AN — Provider Marketplace: Modelos al Dia sin Esperar Updates (PROXIMA)

**Objetivo:** Que el usuario pueda agregar, quitar y actualizar modelos LLM sin esperar una actualizacion de LifeOS. Tres niveles: via Telegram (natural language), via dashboard, y via TOML manual.

**Por que es critico:** Los proveedores de LLM lanzan modelos nuevos cada semana. Si el usuario tiene que esperar a que LifeOS lance un update para usar un modelo nuevo, pierde competitividad. Debe poder decirle a Axi: "agrega este modelo" y que funcione inmediatamente.

**AN.1 — Agregar Modelos via Telegram (natural language)**
- [x] Tool `add_provider` en telegram_tools.rs: "Axi, agrega el modelo nvidia/nemotron-ultra de OpenRouter"
- [x] Axi parsea: provider base (OpenRouter/Cerebras/Groq/custom), model name, estima context size y capabilities
- [x] Valida endpoint con SSRF guard (AL.1)
- [x] Escribe al `llm-providers.toml` del usuario sin tocar los defaults del sistema
- [x] Hot-reload: el router recarga providers sin reiniciar el daemon
- [x] Confirma: "Modelo nvidia/nemotron-ultra agregado a OpenRouter. Contexto: 128K. Privacy: variable. Listo para usar."

**AN.2 — Quitar/Deshabilitar Modelos via Telegram**
- [x] Tool `remove_provider`: "Axi, quita el modelo de Z.AI, no lo quiero"
- [x] Tool `disable_provider`: "Axi, deshabilita Gemini" (no borra, solo desactiva)
- [x] Tool `list_providers`: "Axi, que modelos tengo configurados?"

**AN.3 — Dashboard de Modelos**
- [x] Seccion en el dashboard web para ver/agregar/quitar/reordenar providers
- [x] Formulario: provider name, API base, model, API key env var, tier, privacy
- [x] Toggle enable/disable por provider
- [x] Test de conectividad (enviar request de prueba)

**AN.4 — Hot-Reload del Router sin Reiniciar**
- [x] `LlmRouter::reload_providers()` — re-lee el TOML y actualiza la lista en memoria
- [x] Signal handler: `SIGHUP` al daemon trigger reload (estandar Unix)
- [x] API endpoint: `POST /api/v1/llm/reload` para trigger manual
- [x] Watcher de archivo: detectar cambios en llm-providers.toml y auto-reload

**AN.5 — User TOML vs System TOML**
- [x] System defaults: `/usr/share/lifeos/llm-providers.toml` (read-only, viene con la imagen)
- [x] User overrides: `/etc/lifeos/llm-providers.toml` (editable, persiste en updates)
- [x] Merge strategy: user TOML tiene prioridad. Si el user define un provider con el mismo nombre, gana el del user
- [x] Nuevos providers del system TOML se agregan automaticamente sin borrar los del user

**AN.6 — Auto-Discovery de Modelos Nuevos (futuro)**
- [ ] Periodicamente consultar `/v1/models` endpoint de cada provider activo
- [ ] Detectar modelos nuevos que no estan en la config
- [ ] Notificar: "Cerebras tiene un modelo nuevo: qwen3-405b. Quieres agregarlo?"
- [ ] El usuario aprueba → se agrega automaticamente

**Prioridad:** AN.1-AN.2 son los mas importantes (Telegram). AN.4 es prerequisito tecnico. AN.3 y AN.5 son mejoras de UX. AN.6 es futuro.

---

### Fase AO — Telegram UX: De Bot Funcional a Asistente Pulido (PROXIMA)

**Objetivo:** Cerrar las brechas de UX entre LifeOS y OpenClaw en Telegram, adoptando SOLO lo que mejora la experiencia del usuario real. LifeOS ya esta ADELANTE en voz, vision, video, 35 tools, computer use, knowledge graph y smart home. Lo que falta es "plomeria" que hace al bot sentirse profesional.

**Investigacion (2026-03-29):** Comparacion profunda OpenClaw Telegram (194 archivos, extension completa) vs LifeOS (telegram_bridge.rs + telegram_tools.rs). LifeOS gana en 10+ capacidades tecnicas. OpenClaw gana en 9 aspectos de infraestructura/UX.

**Nota legal:** Ningun codigo de OpenClaw fue copiado. Las features son funcionalidad generica de la API publica de Telegram Bot. Nuestra implementacion es 100% propia en Rust/teloxide.

**AO.1 — P0: Critico para lanzar a otros usuarios**
- [x] **Reply-to-bot como trigger en grupos** — si el usuario responde a un mensaje de Axi, tratarlo como mencion directa. Agregar check en `is_addressed_to_bot()` para `msg.reply_to_message()` (3 lineas)
- [x] **Registrar bot commands** — `bot.set_my_commands()` al inicio: /help, /new, /status, /btw, /do. Aparecen como menu cuando el usuario escribe "/" (3 lineas)
- [x] **/status sin LLM** — comando rapido que muestra uptime, disco, memoria, servicios, modelo activo sin pasar por el agentic loop (respuesta instantanea)

**AO.2 — P1: Primera semana post-launch**
- [x] **Threads/topics en grupos forum** — usar `(chat_id, thread_id)` como clave de historial para mantener contexto separado por topic
- [x] **Markdown en respuestas** — usar `ParseMode::MarkdownV2` para negritas, codigo, listas. Escapar caracteres especiales del LLM
- [x] **Envio de archivos** — tool `send_file` que use `bot.send_document()` para enviar PDFs, logs, configs cuando el usuario los pida
- [x] **Politica de grupos configurable** — `LIFEOS_TELEGRAM_GROUP_POLICY`: mention_only (default), reply_only, all_messages
- [x] **Grupos permitidos via config** — `LIFEOS_TELEGRAM_GROUP_IDS` separado del chat_id personal

**AO.3 — P2: Polish**
- [ ] **Webhook transport** — `LIFEOS_TELEGRAM_WEBHOOK_URL` hoy solo se detecta/loguea; el bridge real sigue en polling y no aparecio webhook end-to-end
- [x] **Cola de mensajes con steering** — si llega mensaje mientras se procesa otro, encolar y alimentar como contexto al terminar
- [x] **Pairing para usuarios adicionales** — /pair genera codigo 6 digitos, nuevo usuario lo manda, se agrega a allowed_ids
- [x] **Notificaciones con acciones** — inline keyboards en notificaciones: "Disco al 90%" -> boton "Limpiar" + boton "Ignorar"
- [x] **Streaming de respuestas** — enviar mensaje parcial y editarlo conforme llega la respuesta del LLM (`bot.edit_message_text`)

**Donde LifeOS ya esta ADELANTE de OpenClaw:**

| Capacidad LifeOS | OpenClaw |
|-------------------|----------|
| Voz nativa (Whisper STT + Piper TTS) | Requiere plugin separado |
| Video analysis (frame extraction) | No tiene |
| 35 tools agenticos | Depende de plugins |
| Computer use (ydotool/xdotool) | Solo macOS (Peekaboo) |
| Knowledge graph local | No nativo |
| Smart home (Home Assistant) | No nativo |
| Memory consolidation (6h cycle) | Archivos planos |
| Traduccion (Argos + LLM) | No nativo |
| Typing indicator persistente (4s) | Desconocido |
| Deduplicacion de mensajes | Similar |

**Prioridad:** AO.1 es critico (P0, ~30 lineas de codigo total). AO.2 es importante para la primera semana. AO.3 es polish para despues.

---

### Fase AP — Axi Siempre Libre: Async Workers + Sub-Agentes (CRITICA)

**Objetivo:** Que Axi NUNCA se bloquee esperando una tarea. Cuando le pides algo que tarda (resumen de PDF, busqueda web, ejecucion de codigo), Axi delega a un worker asincrono y queda libre al instante para atender tu siguiente mensaje. Los workers pueden tener sub-workers para tareas complejas.

**Por que es critico:** Hoy Axi se bloquea 3-120 segundos por cada mensaje. Si le pides algo pesado, no puedes ni preguntarle la hora mientras tanto. Esto destruye la experiencia de "asistente siempre disponible". OpenClaw y Claude Code procesan multiples tareas en paralelo — LifeOS debe hacer lo mismo.

**Arquitectura:**
```
Usuario manda mensaje
  ↓
Axi (coordinator) — SIEMPRE libre, responde en <1 segundo
  ├── Mensaje simple? (saludo, hora, status) → responde directo
  └── Tarea larga? → spawn worker asincrono
       ↓
       Worker ejecuta: LLM call + tools + iteraciones
       ├── Sub-tarea? → spawn sub-worker
       │    └── Sub-sub-tarea? → spawn otro sub-worker
       └── Termina → envia resultado a Telegram
           (Axi ya respondio otros 5 mensajes mientras tanto)
```

**AP.1 — Clasificador Rapido (Axi como Coordinador)**
- [x] Antes de llamar agentic_chat, clasificar el mensaje en <100ms:
  - `instant`: saludos, hora, status, help → responder directo sin LLM
  - `quick`: preguntas simples → LLM call rapido (max 5s timeout)
  - `task`: tareas que requieren tools → delegar a worker asincrono
- [x] Heuristicas de clasificacion: longitud del mensaje, keywords (haz, ejecuta, busca, resume, analiza), presencia de archivos/fotos
- [x] Si es `task`, responder inmediatamente: "Estoy en eso, te aviso cuando termine" y hacer spawn del worker

**AP.2 — Worker Pool Asincrono**
- [x] `tokio::spawn` por cada tarea larga — no bloquea el handler de Telegram
- [x] Cada worker tiene su propio contexto (chat_id, history, tools)
- [x] Limite de workers concurrentes por usuario (default: 3)
- [x] Cuando el worker termina, envia el resultado al chat via `bot.send_message()`
- [x] Si el worker falla, notifica: "No pude completar la tarea: {error}"
- [x] Progress updates: el worker envia mensajes parciales ("Analizando archivo... Buscando en internet... Generando resumen...")

**AP.3 — Sub-Agentes con Delegacion**
- [ ] Un worker puede crear sub-workers para sub-tareas:
  - "Investiga X" → worker principal delega a sub-worker de busqueda web
  - "Resume este PDF y busca articulos relacionados" → 2 sub-workers en paralelo
- [ ] Sub-workers reportan al worker padre, no directamente al usuario
- [ ] El worker padre consolida resultados y envia respuesta unificada
- [ ] Profundidad maxima: 3 niveles (Axi → worker → sub-worker → sub-sub-worker)

**AP.4 — Cola de Mensajes Inteligente**
- [x] Si llega un nuevo mensaje mientras un worker procesa, NO esperar — procesarlo inmediatamente
- [x] Cada mensaje se clasifica y rutea independientemente
- [x] Si el usuario manda "cancela" o "para", cancelar el worker activo
- [ ] Si el usuario manda un mensaje relacionado con la tarea en curso, alimentarlo como contexto al worker (steering)

**AP.5 — Dashboard de Workers**
- [ ] Seccion en el dashboard mostrando workers activos con:
  - Tarea en ejecucion
  - Tiempo transcurrido
  - Sub-workers activos
  - Boton "Cancelar"
- [ ] Evento WebSocket `worker.started`, `worker.progress`, `worker.completed`, `worker.failed`

**AP.6 — Respuestas Instantaneas sin LLM**
- [x] Mapa de respuestas rapidas que NO necesitan LLM:
  - "hola/hi/hey" → "Hola! En que te puedo ayudar?"
  - "que hora es" → current_time() directo
  - "/status" → system metrics directo (ya implementado en AO.1)
  - "/help" → texto de ayuda estatico
  - "gracias" → "De nada! Aqui estoy."
- [x] Estas respuestas se dan en <50ms, sin latencia de LLM

**Prioridad:** CRITICA — AP.1 y AP.2 son los mas importantes. Sin esto, cada mejora que hagamos a Axi (mas tools, mas providers) solo lo hace MAS LENTO. Con workers asincronos, Axi escala horizontalmente.

---

### Fase AM — Reloj Perfecto: Timezone-Aware Time Handling (CRITICA)

**Objetivo:** Que Axi SIEMPRE sepa la fecha, hora y zona horaria exacta del usuario. Que nunca se equivoque al programar recordatorios, consultar memorias por fecha, o interpretar expresiones como "mañana a las 3pm". Que todas las memorias guarden la hora correcta para consultas futuras precisas.

**Por que es critico:** Los LLMs no tienen reloj interno — si no les inyectas la hora, no la saben. OpenClaw tenia este problema constantemente: el usuario tenia que recordarle la hora. Esto destruye la confianza. Un asistente que no sabe qué hora es no sirve para organizar tu vida.

**Investigacion (2026-03-29):** Analisis del estado actual de LifeOS + investigacion de mejores practicas (ChatGPT inyecta hora en system prompt, Claude también, produccion requiere UTC storage + local display).

**Estado actual (BUG CRITICO):**
- NINGUNO de los 7+ system prompts inyecta fecha/hora/timezone
- Mezcla de `Utc::now()` y `Local::now()` sin patron consistente
- memory_plane usa UTC (correcto), calendar usa Local (inconsistente)
- No hay deteccion de timezone IANA (solo depende de /etc/localtime)
- No existe herramienta `current_time` para el LLM
- Cron jobs mezclan UTC y Local en comparaciones de tiempo

**AM.1 — Inyeccion de Tiempo en System Prompts (P0)**
- [x] Crear funcion `time_context()` que genera bloque de contexto temporal:
  ```
  [Contexto temporal]
  Fecha y hora actual: 2026-03-29 10:45:23
  Zona horaria: America/Mexico_City (CST, UTC-6)
  Dia de la semana: sabado
  ```
- [x] Inyectar `time_context()` en TODOS los system prompts:
  - `telegram_tools.rs` → `agentic_chat()` (prompt principal de Axi)
  - `supervisor.rs` → `create_plan_with_role()` (planificacion de tareas)
  - `autonomous_agent.rs` → `action_loop()` (agente autonomo)
  - `overlay.rs` → prompt del overlay
  - `sensory_pipeline.rs` → prompt de percepcion
  - `knowledge_graph.rs` → prompt de extraction
  - `telegram_tools.rs` → sub-agent calls
- [x] El tiempo se genera FRESCO en cada llamada al LLM (no cacheado)

**AM.2 — Herramienta `current_time` para el LLM**
- [x] Agregar tool #34 `current_time` en telegram_tools.rs:
  - Sin parametros, devuelve fecha/hora/timezone/dia de la semana
  - Permite al LLM pedir la hora explicitamente cuando necesita precision
- [x] Agregar al SYSTEM_PROMPT la instruccion:
  ```
  Cuando el usuario use expresiones de tiempo relativo ("manana", "en 2 horas", "el lunes"),
  calcula la fecha/hora exacta usando el contexto temporal y confirma:
  "Perfecto, te recuerdo el lunes 31 de marzo a las 15:00 (CST)."
  ```

**AM.3 — Deteccion de Timezone IANA**
- [x] Agregar crate `iana-time-zone` a daemon/Cargo.toml
- [x] Detectar timezone automaticamente al arrancar el daemon (`iana_time_zone::get_timezone()`)
- [x] Guardar en config: `~/.config/lifeos/timezone` como fallback
- [x] Permitir override manual via API: `POST /api/v1/settings/timezone`

**AM.4 — Estandarizar Storage: UTC + Timezone**
- [x] **Regla:** Todas las DBs almacenan timestamps en UTC (RFC3339 con +00:00)
- [x] **calendar.rs:** Migrar `start_time` a UTC. Agregar columna `timezone TEXT DEFAULT 'UTC'` para cada evento
- [x] **memory_plane.rs:** Ya usa UTC — correcto, no cambiar
- [x] **scheduled_tasks.rs:** Verificar que `next_run` se calcula en local pero se almacena en UTC
- [x] **telegram_tools.rs (cron):** Estandarizar `last_run` a UTC, comparar contra UTC

**AM.5 — Memory Queries por Rango de Tiempo**
- [x] Agregar `search_by_time_range(from: DateTime<Utc>, to: DateTime<Utc>)` a memory_plane.rs
- [x] Cuando el usuario pregunta "que hice ayer a las 6pm":
  1. Axi sabe su timezone (AM.3)
  2. Calcula "ayer 18:00-18:59" en hora local
  3. Convierte a UTC
  4. Busca en memory_entries con `WHERE created_at BETWEEN ?1 AND ?2`
- [x] Agregar herramienta `search_memories_by_date` al LLM con parametros `{date, time_from, time_to}`

**AM.6 — Calendario Timezone-Aware**
- [x] Cada evento almacena `timezone` del creador
- [x] Al mostrar eventos: convertir UTC → timezone del evento
- [x] Al crear evento: si el usuario dice "3pm", usar SU timezone
- [x] Soportar eventos en diferentes zonas (ej: "reunion a las 3pm hora de Madrid")

**Arquitectura de tiempo:**
```
Usuario dice "recuerdame mañana a las 3pm"
  ↓
LLM lee [Contexto temporal] del system prompt
  ↓ sabe que hoy es 2026-03-29 y timezone es America/Mexico_City
Calcula: mañana = 2026-03-30, 3pm CST = 2026-03-30T21:00:00Z (UTC)
  ↓
Crea scheduled_task con next_run = "2026-03-30T21:00:00Z"
  ↓
Confirma: "Te recuerdo el domingo 30 de marzo a las 3:00 PM (CST)"
  ↓
A las 3pm CST, el cron matcher ejecuta y envia recordatorio
```

**Prioridad:** CRITICA — AM.1 y AM.2 se deben implementar INMEDIATAMENTE. Sin esto, Axi es un asistente ciego al tiempo. Los demas items (AM.3-AM.6) son mejoras incrementales importantes pero menos urgentes.

---

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
