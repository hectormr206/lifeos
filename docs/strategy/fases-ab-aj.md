# Fases AB-AJ — OpenClaw Gaps, Cloud, Security

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

### Fase AH — Firefox AI Local-First (exploratoria, pendiente)

**Objetivo:** Evaluar una experiencia de IA privada dentro de Firefox en LifeOS, aprovechando el modelo local ya expuesto via `llama.cpp` y manteniendo el hardening/privacy defaults del navegador.

**Estado:** Idea estrategica a considerar a futuro. No esta planteada a fondo ni implementada. La meta aqui es dejarla visible en el roadmap para cuando toque priorizar producto.

**AH.1 — Companion de Axi dentro de Firefox**
- [ ] Explorar una extension/sidebar de Firefox para "Ask Axi about this page"
- [ ] Soportar resumen de pagina, reescritura de texto seleccionado, traduccion y extraccion estructurada
- [ ] Evaluar acceso a DOM/seleccion actual sin romper privacidad ni endurecimiento actual del perfil

**AH.2 — Integracion con modelo local de LifeOS**
- [ ] Conectar la extension a un endpoint local de Axi/LifeOS que hable con `llama.cpp` OpenAI-compatible en loopback
- [ ] Definir limites de contexto: pagina completa, seleccion, formularios, PDFs, pestaña actual
- [ ] Diseñar controles de permisos claros: por sitio, por accion, por tipo de dato

**AH.3 — Modos local y remoto**
- [ ] Priorizar modo local-first como experiencia por defecto
- [ ] Mantener opcionalmente un modo remoto para casos donde el modelo local no alcance
- [ ] Dejar DuckDuckGo como buscador y Duck.ai como opcion remota separada, sin plan actual de integrarlo al flujo local de LifeOS

**AH.4 — Agente web a futuro**
- [ ] Evaluar puente entre extension de Firefox y capacidades existentes de browser automation/CDP para tareas mas agenticas
- [ ] Explorar prompts de "sobre esta pestaña" y "completa esta accion en la web" con aprobaciones y audit trail

### Fase AI — LibreOffice AI + UNO/MCP (exploratoria, pendiente)

**Objetivo:** Evaluar una integracion de IA para LibreOffice en LifeOS, idealmente local-first, que combine extension nativa para usuario final con herramientas estructuradas para Axi.

**Estado:** Idea estrategica a considerar a futuro. No esta planteada a fondo ni implementada. Se documenta para no perder la oportunidad de producto.

**AI.1 — Extension nativa para LibreOffice**
- [ ] Explorar una extension `.oxt` para Writer como primer objetivo
- [ ] Casos iniciales: resumir, reescribir, traducir, expandir texto, cambiar tono, explicar contenido
- [ ] Evaluar crecimiento posterior hacia Calc e Impress

**AI.2 — Integracion con modelo local**
- [ ] Conectar la extension al modelo local de LifeOS via `llama.cpp`, preferentemente a traves de un endpoint de Axi/LifeOS y no directo al runtime
- [ ] Diseñar fallback remoto opcional solo si aporta valor real y con privacidad claramente etiquetada
- [ ] Definir limites de tamaño/contexto para documentos y selecciones grandes

**AI.3 — UNO como camino principal**
- [ ] Priorizar UNO para lectura/escritura estructurada del documento, en vez de depender solo de teclado y raton
- [ ] Reutilizar y expandir el puente existente de LibreOffice/UNO en LifeOS
- [ ] Evaluar comandos estructurados: leer seleccion, reemplazar seleccion, leer/escribir celdas, exportar PDF, explicar formulas

**AI.4 — MCP interno para Axi**
- [ ] Diseñar un MCP interno o set de tools de LifeOS para que Axi manipule LibreOffice de forma segura y auditable
- [ ] Separar dos modos: herramientas estructuradas via UNO y fallback universal via desktop operator (teclado/raton/screenshot)
- [ ] Explorar skills por app para Writer/Calc/Impress, usando Axi como operador y verificador

**AI.5 — Vision de producto**
- [ ] Posicionar a LibreOffice + LifeOS como alternativa privada/local-first frente a Office con copilotos cloud
- [ ] Evaluar si esta experiencia merece branding propio tipo "LibreOffice AI for LifeOS" o "Axi for Documents"

### Gaps Menores de OpenClaw (documentados, no requieren fase propia)

| Gap | Severidad | Accion | Donde |
|-----|-----------|--------|-------|
| **Pairing system** (codigo 8 chars para vincular nuevo dispositivo/usuario) | BAJO | Implementar cuando soporte multi-dispositivo | Fase Z |
| **Session target validation** (cron jobs validan destino de delivery) | BAJO | Agregar a scheduled_tasks.rs | Mejora incremental |
| **Inbound message dedupe** (evitar procesar mismo mensaje 2 veces) | BAJO | Agregar cache en telegram_bridge.rs | Mejora incremental |
| **Transcript export** (exportar conversaciones como PDF/HTML) | BAJO | Agregar como tool del supervisor | Mejora incremental |
| **Native apps (iOS/Android)** | BAJO hoy | Requiere equipo, post-lanzamiento | Fase Z+ |

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

### Post Fases — Lanzamiento Publico (REQUIERE HUMANO)

- [ ] Grabar video demo de 2 minutos — REQUIERE HUMANO (screen recording + Telegram)
- [ ] Grabar video demo "agente agentico" — REQUIERE HUMANO
- [ ] Actualizar README.md para publico — REQUIERE HUMANO (screenshots reales del dashboard)
- [ ] Hacer repo publico bajo org lifeos-ai — REQUIERE HUMANO (GitHub settings)
- [ ] Post en X/Twitter con video — REQUIERE HUMANO
- [ ] Post en r/linux, r/LocalLLaMA, r/selfhosted, Hacker News — REQUIERE HUMANO
- [ ] Post en comunidades hispanohablantes — REQUIERE HUMANO
- [ ] Preparar ISO descargable para early adopters — REQUIERE HUMANO (`sudo bash scripts/build-iso.sh`)
