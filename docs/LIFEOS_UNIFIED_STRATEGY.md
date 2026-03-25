# LifeOS Estrategia Unificada Final

Fecha: 2026-03-23 (ultima revision: 2026-03-25, fases A-Z implementadas, 255/388 checkboxes = 66%)
Sintesis de:

- `docs/LIFEOS_STRATEGIC_REVIEW.md` (Estrategia A — Gemini)
- `docs/ANALISIS_COMPLETO_LIFEOS_2026.md` (Estrategia B — Claude)
- `docs/2026-03-23-lifeos-auditoria-estrategica.md` (Estrategia C — Auditoria Operativa)
- `docs/LLM_ACCESS_STRATEGY.md` (Estrategia de LLMs, APIs, Privacidad y Modelo Local)

---

## 1. Decision Final

### Seguir con LifeOS: SI

### Wedge oficial para los proximos 90 dias

`LifeOS = mi empleado digital local-first que vive en mi laptop, puede trabajar aunque yo no este enfrente, con voz, pantalla, memoria, permisos, recuperacion y control remoto.`

Todo lo que no empuje esa promesa se congela temporalmente.

---

## 2. Donde Coinciden las 3 Estrategias

Las tres llegan a las mismas conclusiones centrales:

| Punto | A (Gemini) | B (Claude) | C (Auditoria) |
|-------|------------|------------|----------------|
| No vas lento construyendo | Si | Si (118+ commits, 82K LOC, 45 modulos Rust, 158 API routes) | Si |
| Vas lento integrando | Si | Si | Si |
| Falta cerrar el loop autonomo | Si (Plan->Execute->Audit->Learn) | Si (agent loop) | Si (supervisor->worker->auditor->recovery) |
| OpenClaw es la referencia inmediata | Mencionado | Si (100K stars, viral) | Si (benchmark, no modelo a copiar) |
| Tu cuello de botella eres tu como scheduler | Si (Orchestra 2.0) | Si (eres gerente+dev+QA+devops) | Si (tres copilotos manuales) |
| Multi-LLM es critico | Si (Claude planifica, Gemini audita) | Si (router con 4 providers) | Si (pipeline, no copilotos) |
| Canal remoto es urgente | No enfatizado | Si (Telegram P0) | Si (interfaz remota first-class) |
| No abrir mas superficie | Si (enfoque total en GG) | Si (no tocar imagen, no mas stubs) | Si (congelar periferia) |
| Primero 1 celula perfecta, luego escalar | Si (Fase 1->2->3) | Si (90 dias antes de enjambre) | Si (1 laptop autonoma antes de mesh) |

**Consenso absoluto en 9 de 9 puntos.** No hay desacuerdo estrategico entre las tres fuentes.

---

## 3. Donde Difieren (y cual tomar)

| Tema | A (Gemini) | B (Claude) | C (Auditoria) | Decision |
|------|------------|------------|----------------|----------|
| **Primer paso** | Documento de arquitectura del GG | Implementar LLM router | Cerrar paridad con OpenClaw | **Implementar. No mas documentos. El LLM router es prerequisito de todo** |
| **Telegram** | No lo menciona | P0 semana 3 | P1 obligatorio | **P0. Moverlo a semana 1-2 en paralelo con router** |
| **Sandbox desarrollo** | No detallado | git worktree + container | Sandbox con aprobaciones | **git worktree primero (simple), container despues** |
| **Self-improvement** | Fase 1 del GG | Semanas 4-8 | No antes de que el loop basico funcione | **Fase B, no antes. Primero que funcione manual, luego que se auto-mejore** |
| **Computer use** | No priorizado | Conectar existente al agent loop | Fase B completa (loop visual robusto) | **Fase B. Lo que ya existe basta para Fase A** |
| **Orchestra 2.0 script** | Propone dev_cycle.sh inmediato | No mencionado | Pipeline de documentos operativos | **Ambos. El script es tactico (hoy). Los documentos son estructura (semana 2)** |
| **Memory/embeddings** | Fase 2 (LanceDB/Qdrant) | Semanas 3-4 | Memory writeback como entregable | **SQLite-vec que ya existe + writeback real. No cambiar de DB todavia** |
| **North Star metrics** | No definidas | No definidas | 9 metricas claras | **Adoptar las 9 metricas de la Auditoria** |

---

## 4. Estado Real de LifeOS Hoy (Datos Duros)

### Metricas del repo

| Metrica | Valor (actualizado 2026-03-24) |
|---------|-------|
| Primer commit | 10 de marzo de 2026 |
| Dias activos de desarrollo | 14 |
| Total commits | 115 |
| Lineas de Rust | 60,559 |
| Subcomandos CLI | ~34 (enum variants en main.rs) |
| Endpoints REST del daemon | 224 route handlers |
| Modulos del daemon | 45 archivos .rs, ~45,650 LOC |
| Servicios systemd | 8+ |
| Workflows CI/CD | 8 |
| Etapas del build de imagen | 6 (Rust + llama-server + whisper + piper-voice + piper-runtime + sistema) |

### Lo que funciona y vale mucho

- **OS base:** Fedora 42 bootc inmutable + COSMIC Desktop + NVIDIA + gaming
- **AI local:** llama-server (Vulkan GPU) + Qwen3.5-0.8B default + catalogo de 7 modelos
- **Voz:** Whisper STT + Piper TTS (voz es_MX) + voice loop completo + wake word (rustpotter)
- **Vision:** Screen capture Wayland/X11 + OCR + similarity skip + presencia por webcam
- **Memoria:** SQLite cifrado AES-256-GCM-SIV + sqlite-vec 768d embeddings
- **Computer use:** ydotool/xdotool para mouse/teclado
- **Seguridad:** Permisos, portal XDG, tokens cifrados, audit ledger, TUF chain of trust
- **Infra:** CI/CD completo, 3 canales (stable/candidate/edge), e2e con KVM, cosign signing

### Lo que falta (actualizado 2026-03-24)

Los 6 cierres decisivos originales — estado actual:

1. ~~**Supervisor autonomo:**~~ **CERRADO.** `supervisor.rs` (1,442 LOC) con loop plan->execute->evaluate->retry->report, 13 acciones, risk classification, memory writeback
2. ~~**Loop asincrono con retries:**~~ **CERRADO.** `task_queue.rs` (572 LOC) SQLite persistente, prioridad, retry configurable, sobrevive reinicios
3. ~~**Canal remoto:**~~ **CERRADO.** `telegram_bridge.rs` (851 LOC) bidireccional, voz, fotos, grupos, /do, screenshots, push notifications
4. ~~**Self-healing:**~~ **CERRADO.** Supervisor auto-restart (max 10), LLM fallback entre 13 providers, task retry 3x, Telegram escalation
5. ~~**Jerarquia de agentes real:**~~ **CERRADO.** `agent_roles.rs` (312 LOC) con 7 roles, prompts especificos, allowed actions, metricas por rol
6. ~~**Valor diario inmediato:**~~ **CERRADO.** Loop remoto via Telegram, notificaciones proactivas (disco/RAM/sesion/tareas atascadas cada 5min), health tracking (break/hidratacion/ojos cada 60s), email (IMAP+SMTP), scheduled tasks con API+dashboard. Pendiente futuro: calendario externo (CalDAV/Google), posture_alerts via webcam

---

## 5. Competencia Real al 23 de Marzo de 2026

### Competencia directa: nadie ha ganado la categoria

| Competidor | Estado | Amenaza | Ventaja de LifeOS |
|------------|--------|---------|-------------------|
| **OpenClaw** | Open-source, viral. Peter Steinberger (PSPDFKit). 21+ canales messaging. 13,729+ community skills en ClawHub. Browser headless, cron, self-improvement (escribe sus propios skills). macOS menu bar app con wake word | **ALTA** — es el benchmark inmediato | Tu ERES el OS. OpenClaw es app dentro de OS. En Linux solo corre como headless gateway (sin desktop). LifeOS tiene desktop overlay, computer use, GPU management |
| **Devin AI** | $20/mes (bajo de $500). 67% PR merge rate. Compro Windsurf por $250M. Goldman Sachs lo usa (20% efficiency gains). Sandbox cloud con IDE+terminal+browser propio | **ALTA** para coding | Solo coding. No es asistente de vida. Cloud-only. Sin privacidad |
| **Replit Agent 3** | 10x mas autonomo que v2. 200 min ejecucion continua. Auto-abre apps en browser, encuentra bugs, los corrige. Deploy con 1 click | **MEDIA** para webapps | Solo web apps. Cloud-only. No es OS. Sin privacidad local |
| **AthenaOS** (kyegomez) | Concepto de OS con millones de agentes swarm. Rust + C++. 1700+ contribuidores de Agora | Baja hoy, potencial en 12-18 meses | Tu tienes producto funcional corriendo en hardware real |
| **MAGI OS** | Distro experimental AI + Debian/MATE. Descargable como ISO | Baja. Proyecto de investigacion | Mucho mas limitado que LifeOS en todo |
| **RHEL AI** | Red Hat enterprise con InstructLab. Produccion | Baja para personal, alta para enterprise | Enfocado en servidor, no desktop personal |
| **deepin 25 AI** | Dos agentes AI nuevos (writing/data), OCR mejorado | Media en Asia | LifeOS tiene multimodalidad completa, no solo writing/OCR |

### Competencia indirecta: herramientas que compiten por tu tiempo

| Competidor | Estado | Diferencia clave |
|------------|--------|-----------------|
| **Claude Computer Use** | Produccion macOS (marzo 2026). Anthropic compro Vercept. Ve pantalla pixel a pixel, controla mouse/keyboard en cualquier app | Es API cloud, no OS. LifeOS ya tiene computer_use local + puede usar Claude API como cerebro premium |
| **Cursor / Windsurf** | Cursor: 50%+ Fortune 500. Background Agents autonomos. Windsurf: #1 en rankings AI dev tools 2026, adquirido por Cognition (Devin) | Son IDEs, no OS. Solo coding. LifeOS puede ser la plataforma donde corren |
| **Open Interpreter** | Open source. 01 Light hardware (ESP32, voice-controlled). Experimental OS mode (screen+mouse). Ejecuta Python/bash local | Es framework, no OS. Menos robusto que LifeOS. Pero la vision es similar |
| **CrewAI** | $18M funding. 100K+ devs certificados. 60% Fortune 500. 60M+ agent executions/mes | Son librerias Python. LifeOS puede usarlas como motor interno |
| **AutoGPT** | 167K+ GitHub stars. Pionero de agentes autonomos | Requiere mucho human oversight. No production-ready |
| **Screenpipe** | Open source MIT, $400 lifetime, graba pantalla/audio 24/7 | Es app no OS. Tu sensory_pipeline hace lo mismo a nivel kernel |

### Lo que los gigantes estan haciendo

| Gigante | Estado Marzo 2026 | Implicacion para LifeOS |
|---------|-------------------|------------------------|
| **Microsoft Copilot+** | Agents como "digital teammates" en M365. Computer Use en Copilot Studio (preview). Work IQ layer con memoria entre sesiones. Pero: RETROCEDIERON en Windows 11 (cancelaron Copilot en Photos/Widgets/Notepad). Recall sigue con problemas de seguridad | Ventana abierta. El mercado rechaza AI invasiva mal hecha. Pero el enterprise se mueve rapido |
| **Apple Intelligence** | Foundation Models framework (Swift API). Visual Intelligence. Siri 2.0 agentico esperado junio 2026. Private Cloud Compute. Partnership con Google para Gemini | No competira con autonomia real por años. Pero la barra de UX sube |
| **Google Project Astra** | Universal AI assistant. Video real-time con latencia ~cero. Project Mariner para tareas web complejas. Android XR smart glasses con Samsung | Solo movil/cloud. Desktop Linux no es target. Pero la calidad multimodal es el benchmark |
| **Samsung/Google Gemini** | Agresivo en movil. Gemini controla apps en Galaxy S26. 800M dispositivos | Solo movil. Desktop Linux es diferente |
| **Limitless (ex-Rewind)** | **MUERTO.** Meta lo compro, servidores apagandose, Pendant descontinuado | Oportunidad: el espacio de "memoria personal AI" quedo huerfano |
| **Humane AI Pin** | **MUERTO.** Discontinuado. HP compro restos por $116M. Overheating + $24/mo subscription fail | Hardware AI dedicado fracaso |
| **Rabbit R1** | Sobrevive con R1 OS 2.0 (card UI, community skills via SDK). $199, sin suscripcion | Leccion: hardware AI necesita software ecosystem fuerte |

### Veredicto competitivo (actualizado 2026-03-24)

**La categoria "AI-first OS funcional, abierto, con agente autonomo" NO TIENE GANADOR.**

- OpenClaw es la amenaza mas seria pero NO es un OS — en Linux solo corre headless
- Devin/Replit son autonomos pero solo para coding, cloud-only, sin privacidad
- Los gigantes avanzan (Apple Foundation Models, Microsoft Copilot Studio, Google Astra) pero en ecosistemas cerrados
- Los dispositivos AI dedicados fracasaron (Humane muerto, Rabbit apenas sobrevive)
- Los frameworks de agentes (CrewAI, LangGraph) son librerias, no productos de usuario final
- El mercado de AI agents crece: $14.89B en 2025, proyectado $35.74B en 2030, 72% de enterprises planean deployment en 2026

**Tu ventaja unica que nadie puede replicar facil:**
1. ERES el OS (acceso a kernel, systemd, bootc, hardware)
2. Inmutabilidad + rollback (si la AI rompe algo, bootc te salva)
3. Full sensory stack a nivel de sistema (no una app sandboxeada)
4. Open source + privacidad real (todo local por default)
5. GPU management nativo (Game Guard libera VRAM, ningun competidor hace esto)

**Lo que nos falta para el "efecto wow" (Fases H-M):**
1. Loop iterativo de desarrollo (Fase H) — OpenClaw y Devin ya lo tienen
2. Browser automation real (Fase J) — OpenClaw y Claude Computer Use ya lo tienen
3. Self-improvement (Fase K) — Solo OpenClaw lo tiene, es lo que lo hace viral
4. Plataforma de desarrollo completa (Fase M) — El differentiator final

---

## 6. Estrategia Unificada: "La Celula Perfecta"

### Tesis central

La forma mas rapida de llegar al enjambre de enjambres es NO perseguirlo hoy.

Es construir primero una sola celula perfecta: una laptop, un supervisor autonomo, workers especializados, memoria, control remoto, reportes y recuperacion.

Cuando esa celula funcione, se replica.

### Principio operativo

**No mas documentos de arquitectura. No mas stubs. No mas superficie.**

Cada linea de codigo nueva debe acercar a este test:

> Hector envia un mensaje de Telegram con una tarea.
> LifeOS la planifica, ejecuta, verifica, y reporta el resultado.
> Si algo falla, se recupera solo o pide ayuda con contexto.
> Todo esto sin que Hector toque la laptop.

---

## 7. Roadmap Definitivo de 90 Dias

### Fase A: Loop Autonomo Minimo + Canal Remoto (Semanas 1-4)

**Objetivo:** LifeOS recibe instruccion remota, planea, ejecuta, reporta, sobrevive fallos.

| Semana | Entregable | Detalle |
|--------|-----------|---------|
| 1 | **Migrar a Qwen3.5-2B + LLM Router** | Reemplazar modelo local 0.8B por 2B (1.28 GB, vision, +34pts agentes). Modulo `llm_router` con filtro de privacidad: local para sensible, Gemini free + DeepSeek + GLM free para el resto. Fallback automatico. Tracking de costos |
| 1-2 | **Telegram Bot** | Crate `teloxide`. Bidireccional: recibe texto/voz, pasa a agent_runtime, devuelve resultado. Puede enviar screenshots. Notifica fallos y completados |
| 2 | **Task Queue Persistente** | SQLite. Los trabajos sobreviven reinicios. Estados: pending, running, completed, failed, retrying |
| 2-3 | **Supervisor Loop** | Conectar agent_runtime real: recibe objetivo -> llama LLM para plan -> ejecuta pasos (terminal, computer_use, screen_capture, AI query) -> evalua resultado -> retry si falla -> reporta |
| 3-4 | **Memory Writeback** | Usar sqlite-vec existente con embeddings reales. Guardar: errores cometidos, exitos, contexto de decisiones. Retrieval automatico para dar contexto al planner |
| 4 | **Heartbeat Diario** | Resumen automatico cada 24h via Telegram: que hizo, que fallo, que sigue, bloqueos |

**Hito de cierre Fase A:**

Desde Telegram: `"revisa el estado del repo, resumeme que falta y propon el siguiente paso"`

LifeOS ejecuta analisis, devuelve resumen, sugiere accion, y si autorizas, la toma.

### Fase B: Operador de Escritorio Confiable (Semanas 5-8)

**Objetivo:** LifeOS opera desktop/web sin romperse, con verificacion y sandbox.

| Semana | Entregable | Detalle |
|--------|-----------|---------|
| 5 | **Sandbox de Desarrollo** | git worktree para cambios al propio codigo. Tests automaticos antes de proponer merge. Rollback si falla |
| 5-6 | **Loop Visual Robusto** | screenshot -> LLM comprende -> decide accion -> ejecuta via computer_use -> verifica con nuevo screenshot -> retry |
| 6-7 | **Browser Automation Real** | Elevar `browser.rs` de stub a operador funcional. Tareas: abrir URL, buscar texto, llenar forms, extraer datos |
| 7 | **Self-Healing** | Si un worker muere: reinicio automatico. Si daemon cae: systemd lo levanta. Si LLM falla: fallback a otro. Si task falla 3 veces: escalar a humano via Telegram |
| 7-8 | **Approval por Riesgo** | Clasificar acciones (bajo/medio/alto riesgo). Bajo: ejecutar directo. Medio: ejecutar + notificar. Alto: pedir aprobacion via Telegram antes de ejecutar |
| 8 | **Learning Loop** | Guardar patron exito/fallo por tipo de tarea. El planner consulta memoria antes de planificar: "la ultima vez que intente X, fallo por Y, asi que esta vez hare Z" |

**Hito de cierre Fase B:**

`"entra al dashboard de Axi, toma captura, verifica que todo esta verde, si hay error corrigelo"`

LifeOS completa el loop visual sin rescate manual.

### Fase C: Gerente General Digital (Semanas 9-12)

**Objetivo:** De un agente unico a un equipo coordinado de agentes.

| Semana | Entregable | Detalle |
|--------|-----------|---------|
| 9 | **Sub-agente Spawning** | El supervisor puede crear workers especializados segun la tarea |
| 9-10 | **Roles de Agente** | Executive/GM, Planner, Coder, Reviewer, Tester, DevOps. Cada uno con prompt especifico y herramientas permitidas |
| 10-11 | **Delegacion con Estado** | El GM asigna subtareas. Cada worker reporta estado. El GM detecta bloqueos y reasigna |
| 11 | **Resource Management** | Agentes comparten GPU/CPU sin saturar. Queue de prioridad para inferencia |
| 11-12 | **Dashboard de Operaciones** | Vista unica: que esta haciendo cada agente, que fallo, que sigue. Accesible desde Telegram y web |
| 12 | **Metricas y Runbooks** | Tracking de exito/fallo por agente y tipo de tarea. Runbooks automaticos para fallos recurrentes |

**Hito de cierre Fase C:**

`"mejora el manejo de errores del sensory_pipeline, prueba, audita y presentame el resultado"`

El GM coordina un equipo de agentes para completarlo.

---

## 8. Estrategia de LLMs: Suscripciones, APIs, Privacidad y Modelo Local

Detalle completo en `docs/LLM_ACCESS_STRATEGY.md`.

### 8.1 Realidad de las suscripciones actuales ($140/mes)

| Suscripcion | Costo | Uso programatico? | Veredicto |
|-------------|-------|-------------------|-----------|
| Claude Max | $100/mes | NO como API. SI como Claude Code CLI local (permitido por Anthropic) | Conservar para desarrollo de LifeOS |
| ChatGPT Plus | $20/mes | NO. Prohibido por ToS de OpenAI | **Cancelar. Convertir a $20 de creditos API de OpenAI** |
| Google AI Pro | $20/mes | NO directamente. Pero Gemini API tiene tier GRATUITO separado | Evaluar si usas Workspace. Si no, **cancelar y usar Gemini API free** |

**Leccion clave:** Anthropic baneo masivamente en enero 2026 a todos los que usaban tokens de suscripcion Claude en herramientas terceras (OpenClaw, Cline, etc.). OpenAI prohibe extraccion programatica. Las suscripciones NO son APIs.

### 8.2 Stack de LLMs priorizado por privacidad (actualizado 2026-03-24)

**Principio:** Solo usar providers que NO retienen datos y NO entrenan con tu informacion.

**Prioridad 1 — Local (privacidad maxima):**

| Provider | Modelo | Privacidad | Velocidad |
|----------|--------|-----------|-----------|
| Modelo local | Qwen3.5-2B | Nunca sale de la laptop | 196-263 tok/s GPU |

**Prioridad 2 — Cerebras (zero data retention, gratis):**

| Provider | Modelo | Limite | Velocidad |
|----------|--------|--------|-----------|
| Cerebras | Qwen3 235B | 30 RPM, 1M tok/dia | 2000+ tok/s |
| Cerebras | Llama 3.1 8B | 30 RPM | 2200+ tok/s |

**Prioridad 3 — Groq (zero data retention, gratis):**

| Provider | Modelo | Limite | Velocidad |
|----------|--------|--------|-----------|
| Groq | Llama 3.3 70B | 30 RPM, 14,400 req/dia | 500-1000 tok/s |
| Groq | Qwen3 32B | 30 RPM | 500+ tok/s |
| Groq | DeepSeek R1 70B | 30 RPM | 500+ tok/s |
| Groq | Llama 3.1 8B | 30 RPM | 1000+ tok/s |

**Prioridad 4 — Z.AI paid (privacidad media, requiere saldo):**

| Provider | Modelo | Costo/M tokens |
|----------|--------|----------------|
| Z.AI | GLM-4.7 | $0.55 / $2.20 |

**Prioridad 5 — OpenRouter fallback (privacidad variable):**

| Provider | Modelo | Nota |
|----------|--------|------|
| OpenRouter | Qwen3 Coder, GPT-OSS 120B | Privacidad depende del provider subyacente. Ultima instancia |

**Capacidad gratuita con privacidad alta: Cerebras (~1M tok/dia) + Groq (~14,400 req/dia) + local ilimitado.**

### 8.3 Capa de privacidad obligatoria

Cuando LifeOS envia datos a APIs externas, pasan por un filtro:

```
Dato sensible -> Procesamiento LOCAL (Whisper, OCR, webcam ya son locales)
    -> Filtro de privacidad (detectar/redactar passwords, emails, tokens)
    -> Clasificar sensibilidad: critica/alta/media/baja
    -> Routing segun sensibilidad:
        CRITICA -> SOLO modelo local, nunca sale
        ALTA    -> Local preferido; si necesita potencia: Gemini/OpenAI (mejor track record)
        MEDIA   -> Cualquier provider confiable
        BAJA    -> Cualquier provider incluyendo chinos
    -> Auditoria: loggear todo envio en /var/log/lifeos/llm-audit.log
```

**Reglas duras:**
1. Screenshots sin sanitizar NUNCA van a APIs chinas
2. Transcripciones de voz privada NUNCA salen de la laptop
3. Memoria personal NUNCA se envia completa a ningun provider
4. Todo envio se loggea para revision del usuario
5. El usuario elige nivel: paranoid / careful (default) / balanced / open

**Riesgos documentados de APIs chinas (GLM, DeepSeek, Kimi):**
- Ley china de seguridad nacional obliga cooperacion con gobierno
- DeepSeek tuvo base de datos expuesta con 1M+ logs de chat
- Censura embebida: codigo generado tiene +50% vulnerabilidades en temas sensibles
- **Mitigacion:** Usarlos SOLO para tareas no sensibles (codigo open source, planning generico)

### 8.4 Modelo local: Qwen3.5-2B Q4_K_M (reemplaza al 0.8B actual)

| Aspecto | Qwen3.5-0.8B (actual) | Qwen3.5-2B (nuevo) |
|---------|----------------------|---------------------|
| Tamaño GGUF Q4_K_M | ~0.6 GB | **1.28 GB** |
| VRAM con 6K contexto | ~0.8 GB | **~1.5 GB** |
| VRAM libre para gaming | ~11.2 GB | **~10.5 GB** |
| Vision/multimodal | SI | **SI** |
| Calidad agentes | Basica | **+34 puntos** |
| Razonamiento | Muy limitado | **Significativamente mejor** |
| Idiomas | 200+ | **200+** |
| Contexto nativo | 262K | **262K** |
| Corre en CPU sin GPU | SI (5-15 tok/s) | **SI (12-50 tok/s)** |

**Por que 2B y no otro:**
- Es el **unico modelo sub-2GB con vision multimodal nativa** — critico para analizar screenshots localmente
- 1.28 GB en disco, cabe en 2 GB de VRAM con contexto 6K
- Deja >10 GB libres para gaming en tu RTX 5070 Ti
- En PCs sin GPU corre a 12-50 tok/s en CPU — suficiente para clasificacion y filtrado
- Descartados: Gemma 3 1B (sin vision), SmolLM3-3B (sin vision, 1.92 GB), Phi-4-mini (sin vision, 2.3 GB)

**Configuracion recomendada para llama-server:**
```
LIFEOS_AI_MODEL=Qwen3.5-2B-Q4_K_M.gguf
LIFEOS_AI_CTX_SIZE=6144
LIFEOS_AI_THREADS=4
LIFEOS_AI_GPU_LAYERS=99
```

### 8.5 Presupuesto optimizado

| Opcion | Claude | APIs | Total |
|--------|--------|------|-------|
| A: Minimo | Max $100 | DeepSeek ~$3 + gratis | ~$103/mes |
| B: Balanceado | Max $100 | OpenAI API $20 + DeepSeek $3 + Kimi $2 + gratis | ~$125/mes |
| C: Recorte | Pro $20 | OpenAI API $10 + DeepSeek $3 + Kimi $2 + gratis | ~$35/mes |

### 8.6 Regla de oro

No usar tres asistentes manuales en paralelo. Convertirlos en pipeline automatizado:

1. Tu defines objetivo
2. LLM router selecciona provider optimo (modelo local para sensible, API para el resto)
3. Filtro de privacidad sanitiza antes de enviar
4. Supervisor ejecuta
5. Tu revisas resultado (o no, si el riesgo es bajo)

---

## 9. Documentos Operativos a Crear

| Documento | Proposito | Cuando |
|-----------|-----------|--------|
| `OBJECTIVE.md` | Una sola meta activa con restricciones y criterio de terminado | Semana 1 |
| `QUEUE.md` | Backlog ordenado por impacto en la promesa central | Semana 1 |
| `AUTONOMY_POLICY.md` | Que puede hacer LifeOS sin preguntarte y que requiere aprobacion | Semana 2 |
| `RUNBOOK.md` | Que hacer si falla build, tests, daemon, modelo, browser, voice | Semana 3 |

**Regla de cierre:** Ningun agente termina solo con "done". Siempre: que hizo, como lo verifico, que sigue, y si puede seguir sin ti.

---

## 10. Lo que Se Congela

Durante los proximos 90 dias, baja prioridad a:

- Branding (Plymouth, bootloader, os-release)
- App Store / Skills marketplace
- Themes y polish visual
- Expansion del spec (nuevos subcomandos)
- Mesh multi-dispositivo real
- Swarm distribuido
- Nuevos documentos de arquitectura sin implementacion

No abandonar la vision. Secuenciarla.

---

## 11. North Star Metrics

Para saber si la estrategia funciona, medir solo esto:

| # | Metrica | Objetivo Fase A | Objetivo Fase C |
|---|---------|----------------|-----------------|
| 1 | Tiempo hasta primera accion util despues de pedir tarea | < 60 seg | < 30 seg |
| 2 | % de tareas terminadas sin rescate manual | > 30% | > 70% |
| 3 | Tiempo medio entre intervenciones humanas | > 30 min | > 4 horas |
| 4 | Tiempo de recuperacion despues de fallo | < 5 min | < 1 min |
| 5 | Calidad del resumen diario (util/no util) | Existe | Actionable |
| 6 | Latencia voz -> accion -> confirmacion | < 15 seg | < 8 seg |
| 7 | Tareas cerradas mientras no estas presente | >= 1/dia | >= 5/dia |
| 8 | % acciones sensibles bien auditadas | 100% | 100% |
| 9 | % tareas remotas completadas desde Telegram | >= 1 funciona | > 60% exito |

---

## 12. Riesgos y Mitigaciones

| Riesgo | Probabilidad | Mitigacion |
|--------|-------------|------------|
| Seguir abriendo frentes | Alta (habito natural) | Una sola meta activa. WIP limit de 1. No empezar nuevo sin cerrar anterior |
| Construir infraestructura sin valor diario | Media | Cada semana debe cerrar algo visible en el loop real |
| Dependencia de rescate manual | Alta (estado actual) | Recovery controller + task queue + retries + reportes remotos |
| Tests insuficientes para autonomia | Media | Tests de loop real, no solo parsing. Escenarios: LLM falla, browser falla, daemon cae |
| OpenClaw nos supera en adopcion | Alta | No competir en features. Competir en soberania: "tu OS vs su app" |
| Burn-out de Hector | Alta (1 persona = todo) | El punto del loop autonomo es liberarte. Cada mejora = menos trabajo manual |

---

## 13. Vision Post-90 Dias (No ejecutar ahora, solo contexto)

Una vez que la celula perfecta funcione:

**Meses 4-6:** Sub-agentes especializados como equipo coordinado
**Meses 6-9:** Multi-dispositivo (laptop + VPS via WireGuard mesh)
**Meses 9-12:** Conocimiento compartido entre nodos LifeOS
**Meses 12-18:** Enjambre de enjambres con delegacion bidireccional
**18+ meses:** Plataforma abierta donde otros instalan LifeOS en su hardware

### 13.1 Vision a Largo Plazo: Tu Clon Digital (documentado 2026-03-24)

LifeOS te conoce como nadie: tu vida, gustos, enfermedades, logros, carencias, forma de trabajar, relaciones. Con esa base:

**Fase "Clon Digital" (12-18 meses):**
- LifeOS puede interactuar por ti en Telegram, email, WhatsApp
- Responde con tu estilo y personalidad
- Toma decisiones menores en tu nombre (configurable)
- Te conoce tan bien que descubre patrones que tu no veias

**Fase "Red Social de LifeOS" (18-24 meses):**
- LifeOS-to-LifeOS: tu clon interactua con el clon de otra persona
- Grupos de LifeOS: multiples clones coordinan entre si
- Matching: conectar personas con gustos/habilidades complementarias
- Marketplace de servicios: tu LifeOS ofrece tus skills, otro LifeOS los contrata

**Fase "Economia Autonoma" (24+ meses):**
- Sistema de pagos entre nodos via Lightning Network (Bitcoin) o stablecoins (USDC en L2)
- NO crear cripto propia (percepcion negativa, regulaciones, riesgo de scam)
- Candados de gasto configurables (limite diario, aprobacion para montos altos)
- Stripe Connect como fallback para pagos con tarjeta
- Cada LifeOS puede monetizar las habilidades de su humano autonomamente

**Principio clave:** cada una de estas fases solo se activa cuando la anterior funciona de forma confiable. No adelantar.

Pero nada de esto importa si el loop basico no funciona primero.

---

## 14. Decision que Debes Tomar Hoy

### Aprobar

- [ ] Seguir construyendo LifeOS
- [ ] Adoptar el wedge: "empleado digital local-first con control remoto"
- [ ] Cerrar primero 1 laptop autonoma y confiable
- [ ] Convertir los LLMs en pipeline, no copilotos manuales
- [ ] Priorizar: LLM router -> Telegram -> Supervisor loop -> Memory -> Recovery
- [ ] Usar OpenClaw como benchmark, no como modelo a copiar

### Posponer

- [ ] Mesh multi-dispositivo
- [ ] Swarm distribuido
- [ ] App store / marketplace
- [ ] Branding y polish periferico
- [ ] Nuevos subcomandos sin profundidad

### Rechazar por ahora

- [ ] Seguir aumentando superficie antes de cerrar el loop autonomo
- [ ] Operar el desarrollo dependiendo de ti como scheduler de cada paso
- [ ] Mas documentos de arquitectura sin implementacion inmediata

---

## 15. Primera Orden Ejecutiva

Si aprobamos esta estrategia, empezar por:

```
1. llm_router.rs     — seleccion automatica de LLM por tarea
2. telegram_bridge.rs — bot bidireccional con autenticacion
3. task_queue.rs      — cola persistente en SQLite
4. supervisor.rs      — plan -> execute -> evaluate -> retry -> report
5. memory writeback   — activar embeddings reales en memory_plane.rs
6. heartbeat          — resumen diario automatico via Telegram
```

Este es el camino mas corto entre el LifeOS que tienes y el LifeOS que sueñas.

---

## 16. Juicio Final Unificado

Las tres estrategias, cada una con su enfoque y nivel de profundidad, llegan al mismo lugar:

**LifeOS no necesita mas vision. Necesita disciplina de producto.**

No estas perdiendo la carrera. La perderias si sigues dispersando el esfuerzo antes de lograr una experiencia que ya no puedas soltar.

La meta no es "hacer el primer AI OS del mundo" como eslogan.
La meta es:

> **Hector le dice que hacer, se va, y LifeOS sigue trabajando, reportando y recuperandose solo.**

Si eso funciona en una laptop, todo lo demas — sub-agentes, empresas digitales, nodos, swarm de swarms — se vuelve la consecuencia natural.

Pero no antes.

Ahora cierra el loop.

---

## 17. Indice de Documentacion: Que Conservar y Que No

Este archivo (`LIFEOS_UNIFIED_STRATEGY.md`) es ahora la **fuente de verdad estrategica** del proyecto.
`CLAUDE.md` sigue siendo la guia tecnica para agentes de codigo.

### Documentos VIGENTES (conservar)

| Archivo | Proposito | Notas |
|---------|-----------|-------|
| `CLAUDE.md` | Guia tecnica para Claude Code y agentes de codigo | **No tocar.** Es la referencia de build/arquitectura |
| `GEMINI.md` | Guia tecnica para Gemini | Equivalente a CLAUDE.md para otro LLM |
| `AGENTS.md` | Guia de estructura del repo para agentes | Util como onboarding rapido |
| `README.md` | Entrada principal del repo | Actualizar cuando hagamos publico |
| `docs/LIFEOS_UNIFIED_STRATEGY.md` | **Fuente de verdad estrategica** — este archivo | Todo parte de aqui |
| `docs/LLM_ACCESS_STRATEGY.md` | Detalle de APIs, privacidad, modelo local | Complemento de la seccion 8 |
| `docs/lifeos-ai-distribution.md` | Spec tecnico normativo del producto | Referencia de arquitectura detallada |
| `docs/BOOTC_LIFEOS_PLAYBOOK.md` | Operaciones bootc | Referencia operativa |
| `docs/incident-response-playbook.md` | Runbook de emergencia | Referencia operativa |
| `docs/update-channels.md` | Canales stable/candidate/edge | Referencia operativa |
| `docs/threat_model_stride.md` | Modelo de amenazas | Referencia de seguridad |
| `docs/NVIDIA_SECURE_BOOT.md` | Setup NVIDIA + Secure Boot | Referencia de hardware |
| `docs/INSTALLATION.md` | Guia de instalacion | Para futuros usuarios |
| `docs/user-guide.md` o `USER_GUIDE.md` | Guia de usuario | Conservar uno, eliminar duplicado |
| `docs/SYSTEM_ADMIN.md` | Guia de administracion | Para futuros usuarios |
| `docs/axi-brand-guidelines.md` | Identidad visual de Axi | Para cuando hagamos publico |
| `docs/design-tokens.md` | Tokens de diseño visual | Para cuando hagamos publico |
| `docs/contributor-guide.md` | Guia para contribuidores | Para cuando sea open source |
| `docs/Reconstruir imagen y generar ISO.md` | Workflow de ISO | Referencia operativa |
| `evidence/` (toda la carpeta) | Evidencia de fases cerradas | Historial auditable, no tocar |

### Documentos a ELIMINAR (deprecated, duplicados, o absorbidos por la estrategia unificada)

| Archivo | Razon |
|---------|-------|
| `ROADMAP.md` | Ya dice "Deprecated Snapshot". Reemplazado por este documento |
| `PROJECT_STATUS.md` | Snapshot del 24-feb con datos obsoletos (8,500 LOC, 12 comandos, Ollama) |
| `FINAL_STATUS.md` | Snapshot del 24-feb, mismo contenido obsoleto |
| `DEVELOPMENT_PLAN.md` | Plan inicial con GNOME/Ollama. Completamente superado |
| `PHASE4_SUMMARY.md` | Resumen de fase ya cerrada. La evidencia esta en evidence/ |
| `PHASE45_SUMMARY.md` | Resumen de fase ya cerrada. La evidencia esta en evidence/ |
| `BETA_PROGRAM.md` | Prematuro. No hay beta publica todavia. Recrear cuando sea relevante |
| `docs/LIFEOS_STRATEGIC_REVIEW.md` | Absorbido por LIFEOS_UNIFIED_STRATEGY.md seccion 2-3 |
| `docs/ANALISIS_COMPLETO_LIFEOS_2026.md` | Absorbido por LIFEOS_UNIFIED_STRATEGY.md secciones 4-5 |
| `docs/2026-03-23-lifeos-auditoria-estrategica.md` | Absorbido por LIFEOS_UNIFIED_STRATEGY.md secciones 2-6 |
| `docs/openclaw_analysis.md` | Absorbido por LIFEOS_UNIFIED_STRATEGY.md seccion 5 |
| `docs/deepin_comparison.md` | Absorbido por LIFEOS_UNIFIED_STRATEGY.md seccion 5 |
| `docs/PROJECT_STATE.md` | Reemplazado por este documento como fuente de verdad |
| `docs/PHASE1_IMPLEMENTATION_COMPLETE.md` | Snapshot historico de fase 1. Ya cerrada |
| `docs/PHASE1_IMPLEMENTATION_STATUS.md` | Duplicado del anterior |
| `docs/PHASE1_PROGRESS_SUMMARY.md` | Triplicado del anterior |
| `docs/MODES_COMPLETED.md` | Snapshot de feature completada. No aporta valor operativo |
| `docs/GTK4_OVERLAY_COMPLETED.md` | Snapshot de feature completada |
| `docs/GTK4_OVERLAY_IMPLEMENTATION.md` | Detalle de implementacion ya en el codigo |
| `docs/night-mode-validation.md` | Validacion puntual ya cerrada |
| `docs/LIFEOS_PHASE_SOP.md` | SOP de fases antiguas. Reemplazado por roadmap en este documento |
| `docs/V2_PENDIENTES.md` | Pendientes de branding. Congelado por estrategia seccion 10 |
| `docs/AI_MODEL_SELECTION.md` | Reemplazado por LLM_ACCESS_STRATEGY.md seccion 11 |
| `docs/APP_STORE.md` | Congelado por estrategia seccion 10 |
| `docs/BETA_TESTING.md` | Prematuro. No hay beta publica |
| `docs/CI_CD.md` | Duplicado de CICD_ARCHITECTURE.md |
| `docs/TESTING.md` | Duplicado de TESTING_STRATEGY.md |
| `docs/lifeos_biological_model.md` | Documento conceptual. No operativo |
| `docs/HARDWARE_COMPATIBILITY.md` | Duplicado de hardware-compatibility-matrix.md |
| `docs/ICONS.md` | Congelado por estrategia seccion 10 |
| `docs/THEMES.md` | Congelado por estrategia seccion 10 |
| `docs/UPDATE_STABLE_PRIVATE_QUICKSTART.md` | Instrucciones puntuales, se pueden mover a BOOTC_LIFEOS_PLAYBOOK |
| `docs/USER_GUIDE.md` | Duplicado de user-guide.md. Conservar uno |

### Documentos a CONSERVAR pero MOVER a subcarpeta `docs/archive/`

| Archivo | Razon |
|---------|-------|
| `docs/FIREFOX_HARDENED.md` | Referencia tecnica de hardening, pero no urgente |
| `docs/CICD_ARCHITECTURE.md` | Referencia de CI/CD, consultable cuando sea necesario |
| `docs/TESTING_STRATEGY.md` | Referencia de testing |
| `docs/ARCHITECTURE_FIRST_BOOT.md` | Referencia de first-boot flow |
| `docs/hardware-compatibility-matrix.md` | Referencia de HW |

### Resultado: de 67 archivos a ~20 activos

Despues de la limpieza, la estructura de documentacion seria:

```
lifeos/
├── CLAUDE.md                          # Guia tecnica para agentes
├── GEMINI.md                          # Guia tecnica para Gemini
├── AGENTS.md                          # Onboarding rapido para agentes
├── README.md                          # Entrada del repo
├── docs/
│   ├── LIFEOS_UNIFIED_STRATEGY.md     # FUENTE DE VERDAD ESTRATEGICA
│   ├── LLM_ACCESS_STRATEGY.md         # Detalle APIs/privacidad/modelo local
│   ├── lifeos-ai-distribution.md      # Spec tecnico normativo
│   ├── BOOTC_LIFEOS_PLAYBOOK.md       # Operaciones bootc
│   ├── incident-response-playbook.md  # Emergencias
│   ├── update-channels.md             # Canales de update
│   ├── threat_model_stride.md         # Seguridad
│   ├── NVIDIA_SECURE_BOOT.md          # Hardware NVIDIA
│   ├── INSTALLATION.md                # Para usuarios
│   ├── user-guide.md                  # Para usuarios
│   ├── SYSTEM_ADMIN.md                # Para admins
│   ├── axi-brand-guidelines.md        # Branding (para lanzamiento)
│   ├── design-tokens.md               # Visual (para lanzamiento)
│   ├── contributor-guide.md           # Para contribuidores
│   ├── Reconstruir imagen y generar ISO.md
│   └── archive/                       # Referencia no urgente
│       ├── FIREFOX_HARDENED.md
│       ├── CICD_ARCHITECTURE.md
│       ├── TESTING_STRATEGY.md
│       ├── ARCHITECTURE_FIRST_BOOT.md
│       └── hardware-compatibility-matrix.md
├── evidence/                          # No tocar, historial auditable
└── (archivos eliminados van a git history)
```

---

## 18. Roadmap Ejecutable con Checkboxes

### Pre-requisitos (Dia 0) — COMPLETADO 2026-03-23

- [x] Descargar Qwen3.5-2B-Q4_K_M.gguf y colocarlo en /var/lib/lifeos/models/
- [x] Actualizar LIFEOS_AI_MODEL en llama-server.env a Qwen3.5-2B
- [x] Verificar que llama-server arranca con el nuevo modelo (196-263 tok/s GPU)
- [x] Registrar API key en Cerebras (free tier, 235B a 2000+ tok/s)
- [x] Registrar cuenta en OpenRouter (free models)
- [x] Registrar cuenta en Z.AI/GLM (ya existente)
- [x] Limpiar documentacion segun seccion 17 (de 67 a ~20 archivos)
- [ ] Reservar nombre en GitHub org (lifeos-ai) y X/Twitter

### Fase A — COMPLETADA 2026-03-23

- [x] Crear `daemon/src/llm_router.rs` — 11 providers (Local, 2x Cerebras, 3x Z.AI, 5x OpenRouter)
- [x] Implementar provider: Local (llama-server :8082, Qwen3.5-2B)
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
- [x] Telegram: recibir fotos -> descargar -> enviar a LLM con vision (local Qwen3.5-2B o Groq)
- [x] Telegram: recibir videos -> extraer frames clave -> vision LLM analiza
- [x] Telegram: enviar screenshots del desktop como foto (sendPhoto)
- [x] Telegram: funcionar en grupos (responder solo a @bot o /do, ignorar otros mensajes)
- [x] Web search: integrar Groq browser_search tool (gratis, alta privacidad, built-in)
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

- [x] WhatsApp integration: `whatsapp_bridge.rs` con WhatsApp Cloud API (Meta Graph API). Webhook listener en 127.0.0.1:8085, soporte texto/imagen/vision, /do commands, notificaciones push. Feature flag `whatsapp`. Config: LIFEOS_WHATSAPP_TOKEN, LIFEOS_WHATSAPP_PHONE_ID, LIFEOS_WHATSAPP_VERIFY_TOKEN, LIFEOS_WHATSAPP_ALLOWED_NUMBERS
- [x] Matrix/Element bridge: `matrix_bridge.rs` con Matrix CS API via HTTP (reqwest). Long-polling /sync, soporte texto/imagen/vision, typing indicators, /do commands, notificaciones push a rooms. Feature flag `matrix`. Config: LIFEOS_MATRIX_HOMESERVER, LIFEOS_MATRIX_USER_ID, LIFEOS_MATRIX_ACCESS_TOKEN, LIFEOS_MATRIX_ROOM_IDS
- [x] Signal bridge: `signal_bridge.rs` via signal-cli JSON-RPC (HTTP daemon). Polling cada 2s, soporte texto/imagen, reactions, /do commands, notificaciones push. Feature flag `signal`. Config: LIFEOS_SIGNAL_CLI_URL, LIFEOS_SIGNAL_PHONE, LIFEOS_SIGNAL_ALLOWED_NUMBERS
- [x] Smart home: `home_assistant.rs` con Home Assistant REST API. get_states, call_service, toggle, turn_on/off, set_temperature, trigger_automation, SSE events listener. NLP command parser basico (enciende/apaga/pon). Feature flag `homeassistant`. Config: LIFEOS_HA_URL, LIFEOS_HA_TOKEN
- [x] Health tracking: `health_tracking.rs` con timers de break/hidratacion/descanso visual (regla 20-20-20). Loop de fondo cada 60s incrementa minutos activos y envia reminders via event bus. API endpoints: GET /health/tracking, POST /health/tracking/break, GET /health/tracking/reminders
  (presencia/fatiga por webcam ya existe en sensory_pipeline — se puede conectar para posture_alerts futuro)
- [x] Messaging channels API: GET /messaging/channels muestra estado de todos los canales (Telegram, WhatsApp, Matrix, Signal, Home Assistant) con enabled/configured/status
- [x] API keys management extendido: GET/POST /settings/keys soporta todas las keys de todos los canales
- [x] **HITO FASE F:** Puedes hablar con LifeOS desde Telegram, WhatsApp, Matrix o Signal indistintamente. Home Assistant conectado para smart home.

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

### Fase G — GPU Game Guard + Game Assistant (proxima iteracion)

**Objetivo:** LifeOS libera VRAM automaticamente al jugar y puede ayudarte dentro del juego.

**Datos reales medidos (RTX 5070 Ti, 12 GB VRAM):**
- Qwen3.5-2B Q4_K_M con 6K contexto: **~2.77 GB VRAM** en reposo
- Gaming (RE Requiem): 11.8/11.9 GB VRAM (98%) → stuttering por falta de VRAM

**GPU Game Guard (auto-offload a RAM):** `game_guard.rs`
- [x] Detectar juego corriendo (GameMode dbus > proceso conocido > VRAM threshold)
  - `detect_gamemode_active()`: check `gamemoded --status` o /proc
  - `detect_game_processes()`: scan /proc/*/comm para wine, proton, gamescope, etc.
  - `detect_vram_heavy_processes()`: `nvidia-smi pmon -c 1 -s m`, excluye llama-server/Xorg/cosmic
  - Threshold: >500MB VRAM por proceso no-sistema
- [x] Al detectar juego: `persist_gpu_layers(0)` + restart llama-server → modelo a RAM
- [x] Al cerrar juego: `persist_gpu_layers(-1)` + restart llama-server → modelo a GPU
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
- [x] **HITO FASE G:** Al jugar, VRAM se libera automaticamente. Pides ayuda y Axi analiza tu juego.

**BUGS CRITICOS ENCONTRADOS (2026-03-24) — CORREGIDOS:**

| Bug | Causa Raiz | Fix |
|-----|-----------|-----|
| **llama-server no se reiniciaba** | `systemctl --user restart llama-server` pero el servicio es del sistema (`/usr/lib/systemd/system/`) | Nuevo helper script `lifeos-llama-gpu-layers.sh` que usa `sudo` + sudoers NOPASSWD |
| **Override de GPU layers no leido** | Escribia a `~/.config/lifeos/llama-server.env.override` que nadie lee. El servicio tiene `ProtectHome=true` | Helper crea systemd drop-in en `/etc/systemd/system/llama-server.service.d/99-game-guard-gpu-layers.conf` |
| **Modelo seguia en VRAM mientras se jugaba** | Consecuencia de los 2 bugs anteriores: game_guard detectaba el juego pero no podia hacer nada | Ahora: helper → daemon-reload → restart llama-server con LIFEOS_AI_GPU_LAYERS=0 |

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
| Modelo local | 196-263 tok/s | 12-50 tok/s (solo clasificacion) |
| Respuestas de gameplay | Local | Cerebras 235B a 2000 tok/s |
| VRAM liberada | 0 | ~2.77 GB |
| Latencia respuesta | ~100ms | <2s (Cerebras via internet) |

### Fase H — Loop Iterativo de Desarrollo (proxima prioridad)

**Objetivo:** Que Axi pueda escribir codigo, compilar, corregir errores, y repetir hasta que funcione — como un desarrollador real.

**Por que es critico:** Hoy el supervisor ejecuta un plan lineal de 2-6 pasos y se detiene. Si el codigo no compila, no vuelve a intentar. OpenClaw ya tiene self-improvement. Devin itera hasta 67% PR merge rate. Sin esto, LifeOS no puede desarrollar software autonomamente.

**Benchmark a superar:** OpenClaw (escribe sus propios skills, hot-reloads), Devin (67% merge rate, auto-debugging), Replit Agent 3 (200 min de ejecucion continua).

- [x] **Evaluate-Fix Loop:** Despues de cada paso de ejecucion, evaluar resultado (compilo? tests pasan? output esperado?). Si falla, alimentar el error completo al LLM y generar paso correctivo automatico
- [x] **Max iteraciones configurables:** Default 5 iteraciones antes de escalar a humano. Evita loops infinitos
- [x] **Build verification:** Despues de escribir codigo, ejecutar automaticamente `cargo build` / `cargo test` / `cargo clippy`. Solo marcar como exitoso si compila y tests pasan
- [x] **Error context enrichment:** Cuando un build falla, extraer el error exacto del compilador, las lineas relevantes del codigo, y el contexto del archivo. Enviar todo al LLM para correccion precisa
- [x] **Diff preview antes de aplicar:** Generar diff de los cambios propuestos, enviarlo a Telegram para revision rapida (o auto-aplicar en modo trust)
- [x] **Streaming de progreso:** Enviar chunks de progreso a Telegram durante ejecucion larga ("Compilando... 3/5 tests pasan... corrigiendo error en linea 42...")
- [ ] **HITO FASE H:** Decir a Axi "agrega endpoint GET /api/v1/health que devuelva uptime" y que el solo escriba el codigo, compile, corra tests, corrija errores, y reporte "listo, compila y tests pasan"

### Fase I — Auto-Aprobacion + Git Workflow Autonomo

**Objetivo:** Eliminar la friccion de aprobacion manual para que Axi pueda trabajar sin interrupciones en un sandbox seguro.

**Por que es critico:** Cada write_file requiere aprobacion manual via Telegram. Para un proyecto real con 50 archivos modificados, esto mata la productividad. OpenClaw auto-aprueba dentro de skills. Devin trabaja en sandbox cloud sin pedir permiso.

**Benchmark a superar:** Devin (trabaja en sandbox sin aprobacion), Cursor Background Agents (ejecutan en paralelo sin bloquear).

- [x] **Trust mode para Telegram:** Tasks iniciadas desde Telegram con `/do trust: <objetivo>` auto-aprueban writes dentro del git worktree sandbox. Solo notifica al final con el diff completo
- [x] **Branch por tarea:** Cada tarea crea un feature branch automatico (`axi/<task-id>-<slug>`). Commits automaticos cuando tests pasan
- [x] **Auto-commit con mensaje semantico:** El LLM genera commit messages descriptivos basados en los cambios realizados
- [x] **PR creation:** Cuando la tarea termina exitosamente, crear PR en GitHub via `gh` CLI con descripcion generada por LLM
- [x] **Post-task diff summary:** Enviar a Telegram un resumen del diff total: archivos modificados, lineas cambiadas, tests que pasan
- [x] **Rollback automatico:** Si una tarea falla despues de 5 iteraciones, `git checkout .` en el worktree y notificar con el contexto completo del error
- [x] **Workspace persistence:** Mantener el worktree activo entre pasos de la misma tarea (no recrear cada vez)
- [ ] **HITO FASE I:** Decir "implementa feature X en branch nuevo, prueba y abre PR" y que Axi lo haga completo sin intervenir

### Fase J — Browser Automation Real + Testing Visual

**Objetivo:** Que Axi pueda abrir un navegador, navegar, verificar que una UI funciona, y corregir si no se ve bien.

**Por que es critico:** Hoy Axi solo puede hacer `fetch_url_text()` (sin JavaScript). No puede abrir localhost:3000, ver si una pagina se renderiza bien, llenar formularios, o hacer login. OpenClaw ya tiene browser headless completo. Claude Computer Use navega cualquier app. Replit Agent 3 abre apps en browser para encontrar bugs.

**Benchmark a superar:** OpenClaw (headless browser, OAuth flows, form filling), Claude Computer Use (pixel-level browser control), Replit Agent 3 (auto-abre app, encuentra bugs, los corrige).

- [ ] **Playwright integration:** Instalar Playwright en la imagen. `browser_automation.rs` que lanza Chromium headless
- [x] **Navegacion basica:** Abrir URL, esperar carga, tomar screenshot, extraer texto/DOM
- [ ] **Interaccion:** Click en elementos (por selector CSS o texto), llenar inputs, submit forms, scroll
- [ ] **JavaScript execution:** Evaluar JS en la pagina para extraer datos estructurados
- [x] **Visual verification loop:** Screenshot -> LLM vision analiza ("el boton de login aparece?", "hay errores en la consola?") -> decide si OK o necesita fix
- [x] **Localhost testing:** Despues de escribir codigo web, levantar `cargo run` o `npm dev`, abrir localhost en Playwright, verificar visualmente, tomar screenshot de evidencia
- [ ] **Form automation:** Llenar formularios, hacer login, navegar flujos multi-paso
- [ ] **Console error detection:** Capturar `console.error` y network errors del browser, reportarlos como parte de la evaluacion
- [ ] **LibreOffice verification:** Abrir spreadsheets/docs via Python UNO bridge (`soffice --accept=socket,host=localhost,port=2002;urp;`). Leer celdas, verificar formulas, comprobar formato sin necesidad de vision. PyOO como wrapper de alto nivel
- [ ] **HITO FASE J:** Decir "abre el dashboard de Axi, verifica que todas las secciones cargan, si hay un error corrigelo" y que lo haga solo con evidencia visual

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
- [ ] **HITO FASE K:** Decir "crea un skill que monitoree el precio de Bitcoin y me avise si baja de $50K" y que Axi lo escriba, lo pruebe, lo active, y funcione

### Fase L — Multimodalidad Avanzada + Interaccion Natural

**Objetivo:** Que la interaccion con Axi sea tan natural como hablar con una persona — voz continua, vision en tiempo real, contexto persistente.

**Por que es critico:** Google Project Astra procesa video en tiempo real con latencia casi cero. Apple Intelligence entiende contexto de pantalla. OpenClaw tiene wake word + push-to-talk overlay en macOS. La barra de calidad para "wow" sube cada mes.

**Benchmark a superar:** Project Astra (video real-time, multi-idioma), Apple Intelligence (contexto de pantalla), OpenClaw macOS (menu bar, wake word, push-to-talk).

- [ ] **Conversacion por voz continua:** Modo siempre escuchando (wake word "Axi") -> dialogo fluido sin necesidad de apretar boton. Ya existe rustpotter + Whisper, falta integrar con dialogo multi-turno
- [ ] **TTS emocional:** Piper TTS con variacion de tono/velocidad segun contexto (urgencia, confirmacion, pregunta)
- [x] **Screen context awareness:** Cuando el usuario pregunta algo, Axi automaticamente toma screenshot y lo usa como contexto. "Que es esto?" → screenshot → LLM vision → respuesta
- [x] **Real-time screen monitoring:** Modo opcional donde Axi observa cambios en pantalla cada N segundos y puede reaccionar ("detecte que tu build fallo en la terminal, quieres que lo investigue?")
- [x] **Multi-turn conversation memory:** Historial de conversacion persistente entre sesiones. "Recuerdas lo que hablamos ayer sobre la API?" → si, consulta memoria
- [ ] **Desktop widget overlay:** Widget flotante COSMIC/GTK4 con la orb de Axi, arrastrable, click para expandir panel rapido. Ya existe `overlay.rs` + `mini_widget.rs`, falta pulir
- [x] **Notification toasts nativos:** Usar sistema de notificaciones de COSMIC/GNOME para alertas no intrusivas
- [ ] **HITO FASE L:** Wake word "Axi" → dialogo fluido → Axi entiende contexto de pantalla → responde con voz natural → recuerda conversaciones anteriores

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
- [ ] **HITO FASE M:** Decir "clona este repo de GitHub, arregla los 3 issues abiertos, corre tests, y abre PRs para cada uno" y que Axi lo haga todo solo, reportando progreso por Telegram

---

### Analisis Competitivo Actualizado (Marzo 2026)

**OpenClaw vs LifeOS — donde estamos y que nos falta:**

| Capacidad | OpenClaw | LifeOS | Gap |
|-----------|----------|--------|-----|
| Messaging channels | 21+ (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Teams, Matrix, IRC, LINE, Twitch, Nostr...) | 4 (Telegram, WhatsApp, Matrix, Signal) | **Medio** — tenemos los principales, faltan Slack/Discord/iMessage |
| Skills ecosystem | 13,729+ community skills en ClawHub | Skill generator + auto-learning (Fase K implementada) | **Medio** — sistema funcional, falta contenido |
| Browser automation | Headless browser completo, OAuth, forms, scraping | Headless screenshots + vision LLM analysis (Fase J) | **Medio** — basico funcional, falta interaccion DOM |
| Self-improvement | Escribe sus propios skills, edita prompts, hot-reload | Skill generation + lookup before planning (Fase K) | **Paridad basica** — genera skills, hot-reload |
| Voice | Wake word macOS/iOS, push-to-talk, ElevenLabs | Wake word rustpotter + Whisper STT + Piper TTS | **Paridad** — funcional |
| Desktop integration | Solo macOS menu bar. Linux = headless gateway | COSMIC overlay + widget + systemd nativo | **VENTAJA LifeOS** |
| Privacy | Local-first, BYOK | Local-first, BYOK, privacy filter, sensitivity routing | **VENTAJA LifeOS** |
| OS-level access | App dentro de OS | **ES** el OS (kernel, systemd, bootc, hardware) | **VENTAJA UNICA LifeOS** |
| Immutability/rollback | No | bootc atomic updates + rollback | **VENTAJA UNICA LifeOS** |
| Cron/scheduling | Si, robusto | Si, SQLite + supervisor | **Paridad** |
| Computer use | No nativo | ydotool/xdotool mouse/keyboard | **VENTAJA LifeOS** |
| Phone calls | Si (ElevenLabs voice synthesis) | No | **Gap** — baja prioridad |
| IoT/Smart home | Si (luces, purificadores) | Si (Home Assistant API) | **Paridad** |
| Iterative coding loop | Via skills autoescribidos | Supervisor con retry (max_attempts=3) + skill lookup (Fase H) | **Paridad** — funcional |
| Git workflow automatico | Limitado | Auto-approve medium-risk + shell git (Fase I) | **Paridad basica** — git push auto-aprobado |
| Meeting recording | No | Auto-detect + pw-record + Whisper transcribe (Fase R) | **VENTAJA LifeOS** |
| Desktop automation | No nativo en Linux | Desktop operator + autonomous agent (Fases N, O) | **VENTAJA LifeOS** |
| MCP protocol | No | 7 tools + JSON-RPC 2.0 transport (Fase Q) | **VENTAJA LifeOS** |
| Health monitoring | No | 12 checks: CPU/GPU/SSD/battery/disk/net/SELinux (Fase S) | **VENTAJA UNICA LifeOS** |
| Gaming agent | No | Frame capture + input + Game Guard VRAM offload (Fase P) | **VENTAJA UNICA LifeOS** |

**Prioridad de cierre para "efecto wow":**

1. **Fase H** (loop iterativo) — sin esto nada funciona bien
2. **Fase I** (auto-aprobacion + git) — sin esto cada tarea es manual
3. **Fase J** (browser) — sin esto no puede verificar UIs
4. **Fase K** (self-improvement) — esto es lo que hace viral a OpenClaw
5. **Fase L** (multimodalidad) — polish para el demo
6. **Fase M** (plataforma completa) — el "efecto wow" final

**Demo "wow" objetivo:**

> Hector envia un mensaje de Telegram: "Clona el repo X de GitHub, hay 3 issues abiertos, resuelvelos todos, corre los tests, y abre PRs"
>
> LifeOS:
> 1. Clona el repo en un sandbox
> 2. Lee los issues de GitHub
> 3. Para cada issue: crea branch, escribe codigo, compila, corre tests, itera si falla, abre PR
> 4. Envia screenshots del browser mostrando que la app funciona
> 5. Reporta: "3 PRs abiertos, tests pasan, aqui estan los links"
>
> Todo esto mientras Hector esta jugando RE9 y la GPU esta libre para el juego.

### Fase N — Operador de Desktop Completo (paridad con OpenClaw macOS)

**Objetivo:** Que Axi pueda hacer TODO lo que OpenClaw hace en macOS, pero a nivel de OS Linux: instalar apps, configurar el sistema, controlar ventanas, abrir aplicaciones, manejar archivos — con permisos, aprobaciones, y audit trail.

**Por que es critico:** OpenClaw en macOS tiene: menu bar app, wake word, shell elevado con whitelisting, camera, screen recording, browser canvas, Apple Shortcuts integration. En Linux solo corre como headless gateway sin desktop. LifeOS debe superar eso aprovechando que SOMOS el OS.

**Benchmark a superar:** OpenClaw macOS (TCC permissions, elevated bash, Shortcuts, camera/mic/screen), Apple Intelligence (Siri contextual, on-screen understanding).

**N.1 — System Management (instalar, configurar, mantener)**
- [x] **Flatpak management:** Instalar/actualizar/remover Flatpak apps via `flatpak install -y`. "Axi, instala Firefox" → `flatpak install -y flathub org.mozilla.firefox`
- [x] **Flatpak permission overrides:** Configurar permisos de apps programaticamente via `flatpak override --user`. "Dale acceso a ~/Documents a LibreOffice"
- [ ] **System settings:** Cambiar configuraciones de COSMIC via `cosmic-settings` CLI o D-Bus (wallpaper, tema, displays, keyboard shortcuts, default apps)
- [x] **Package queries:** "Que apps tengo instaladas?", "Cuanto espacio usan los flatpaks?", "Hay updates pendientes?"
- [x] **Service management:** Listar, iniciar, detener servicios systemd del usuario. "Reinicia el daemon de LifeOS", "Que servicios estan activos?"
- [x] **Firewall / network:** Consultar estado de red, VPN, puertos abiertos via NetworkManager D-Bus
- [x] **Permission approval system:** Acciones de sistema clasificadas por riesgo. Instalar flatpak = medio (notificar). Borrar app = alto (pedir aprobacion). Configurar red = medio
- [x] **Exec approval whitelist:** Como OpenClaw, mantener lista de comandos pre-aprobados en config. Comandos nuevos requieren aprobacion una vez, luego se recuerdan

**N.2 — COSMIC Desktop Control (ventanas, workspaces, apps)**
- [ ] **COSMIC Wayland client:** Modulo `cosmic_control.rs` que conecta via `cosmic-protocols` crate (wayland-client) al compositor para:
  - Listar ventanas abiertas (`zcosmic_toplevel_info`)
  - Mover ventanas entre workspaces (`zcosmic_toplevel_manager.move_to_ext_workspace`)
  - Activar/enfocar ventanas (`activate`)
  - Minimizar/maximizar/cerrar ventanas
  - Crear/renombrar/activar workspaces (`zcosmic_workspace_manager`)
- [x] **App launcher:** Abrir cualquier app instalada: `flatpak run`, `gtk-launch`, o exec directo. "Axi, abre Firefox", "Abre LibreOffice con este archivo"
- [ ] **Window search:** Encontrar ventana por titulo o app_id. "Donde esta mi terminal?", "Pon el editor al frente"
- [ ] **Multi-monitor awareness:** Saber en que monitor esta cada ventana, mover ventanas entre monitores
- [ ] **Workspace dedicado para Axi:** Crear workspace "Axi" automaticamente donde Axi hace su trabajo visual sin interrumpir los workspaces del usuario

**N.3 — Input Simulation mejorado**
- [x] **ydotool robusto:** Asegurar que `ydotoold` corre como servicio. Wrapper en Rust con reintentos y verificacion
- [ ] **Coordenadas inteligentes:** En vez de pixel absoluto, usar vision LLM para encontrar elementos ("click en el boton que dice Guardar") → screenshot → LLM devuelve coordenadas → ydotool click
- [x] **OCR para lectura de pantalla:** Integrar Tesseract OCR (ya disponible en la imagen) para leer texto de elementos UI sin necesidad de LLM vision (mas rapido, local)
- [x] **Clipboard bidireccional:** Leer Y escribir clipboard via `wl-copy`/`wl-paste`. "Copia esto al clipboard", "Que hay en el clipboard?"

**N.4 — File Manager**
- [x] **Operaciones de archivos:** Crear, mover, copiar, renombrar, borrar archivos/carpetas. Con clasificacion de riesgo (borrar = alto)
- [x] **Busqueda inteligente:** "Encuentra todos los PDFs que modifique esta semana" → `find` + `stat`
- [x] **Abrir archivos con app correcta:** "Abre este spreadsheet" → detectar tipo MIME → `xdg-open` o app especifica
- [x] **Compresion/extraccion:** zip, tar.gz, 7z — "comprime esta carpeta", "extrae este zip"

**N.5 — Battery Health Manager (cuidado de bateria en laptops)**

LifeOS es un OS para laptops. La bateria es un organo vital — sin ella, el organismo muere. Axi debe cuidarla como el cuerpo cuida el corazon.

- [x] **Battery monitoring via sysfs + UPower D-Bus:** Leer en tiempo real desde `/sys/class/power_supply/BAT0/`: capacity, cycle_count, energy_full vs energy_full_design (wear level), temp, status, voltage. Tambien via D-Bus `org.freedesktop.UPower.Device` para Percentage, State, EnergyRate, Temperature, ChargeCycles, Capacity (health %)
- [x] **Charge threshold management:** Detectar marca de laptop automaticamente (ThinkPad→`thinkpad_acpi`, ASUS→`asus_wmi`, Dell→`dell_laptop`, Lenovo IdeaPad→`ideapad_laptop`, Framework→`cros_charge-control`, Samsung, Huawei, LG, MSI, System76, etc.). Escribir `charge_control_end_threshold` al valor optimo (default 80%)
- [x] **Persistencia de thresholds:** Los valores de sysfs se pierden al reiniciar. Crear servicio systemd `lifeos-battery.service` que restaure thresholds al boot
- [x] **Dashboard widget:** Mostrar en el dashboard: % actual, health (wear level), ciclos, temperatura, threshold activo, tiempo estimado restante
- [x] **Alertas proactivas via Telegram:**
  - "Tu bateria esta al 87°C — desconecta el cargador o baja la carga de trabajo" (temp > 45°C)
  - "Tu bateria tiene 78% de salud (500 ciclos). Considera reemplazarla pronto" (health < 80%)
  - "Llevas 3 horas enchufado al 100%. Activo limite de carga al 80% para proteger la bateria"
- [x] **Smart charging schedule:** Script + systemd timer que baja el threshold durante el dia (60%) y sube en la noche (80%) para cargar mientras duermes. Configurable por el usuario
- [x] **NVIDIA GPU power management:**
  - Configurar RTD3 (`NVreg_DynamicPowerManagement=0x02`) para que la GPU se apague completamente cuando no se usa (ahorra 5-15W en idle)
  - Integrar con Game Guard: cuando no hay juego, GPU en modo power-save. Cuando hay juego, GPU full power
  - Mostrar consumo actual de GPU en el dashboard (`nvidia-smi --query-gpu=power.draw`)
- [x] **Power profile switching:** Integrar con `tuned-ppd` (default en Fedora 42) via D-Bus `net.hadess.PowerProfiles`. Cambiar perfil segun contexto:
  - En bateria sin actividad pesada → `power-saver`
  - En bateria con compilacion/build → `balanced`
  - Enchufado → `balanced` o `performance`
  - "Axi, pon modo ahorro de energia" → switch a power-saver
- [x] **CLI:** `life battery` subcommand para ver status, cambiar threshold, forzar carga completa
- [x] **API endpoints:** GET /api/v1/battery/status, POST /api/v1/battery/threshold, GET /api/v1/battery/history

- [ ] **HITO FASE N:** Decir "instala GIMP, abrelo, y dime que version es" y que Axi: instale via flatpak, abra la app, lea la version de la ventana (screenshot + OCR), y reporte. Ademas: "cuida mi bateria" y que Axi configure threshold al 80%, active RTD3 en la GPU, y reporte health de la bateria semanalmente.

### Fase O — Agente Agentico de Desktop (trabajo autonomo mientras estas ausente)

**Objetivo:** Que Axi pueda trabajar autonomamente en el desktop cuando detecta que el usuario esta ausente — abriendo apps, verificando archivos, navegando web, corrigiendo problemas — todo en su propio workspace sin tocar el trabajo del usuario.

**Por que es critico:** Esto es lo que separa un chatbot de un verdadero empleado digital. Ninguno de los competidores hace esto: trabajar en el desktop real del usuario de forma autonoma y segura cuando no esta. OpenClaw necesita que le digas que hacer. Devin trabaja en la nube. Claude Computer Use necesita supervision. LifeOS puede ser el primero que trabaja solo, en tu hardware, mientras duermes.

**Benchmark a superar:** Ningun competidor hace esto todavia. LifeOS seria el primero.

**O.1 — Deteccion de ausencia**
- [x] **Screen lock detection:** Escuchar señal D-Bus `org.freedesktop.login1.Session.Lock` via zbus. Cuando el usuario bloquea pantalla = ausente
- [x] **Idle detection:** Leer `IdleHint` + `IdleSinceHint` de logind. Si idle > 5 min sin lock = probablemente ausente
- [x] **Presence camera:** Ya existe en sensory_pipeline. Si webcam no detecta persona por > 2 min = ausente
- [x] **Estado combinado:** `PresenceState { Present, Idle, Away, Locked }`. Away = idle + no persona. Locked = screen lock signal
- [x] **Return detection:** Señal `Unlock` de logind, o persona detectada por webcam = usuario regreso

**O.2 — Workspace isolation (seguridad critica)**
- [ ] **Workspace "Axi":** Al detectar ausencia, crear workspace dedicado via COSMIC Wayland protocol. Todo el trabajo visual de Axi ocurre ahi
- [x] **Preservar estado del usuario:** NUNCA mover, cerrar, o modificar ventanas del usuario. Solo operar en el workspace de Axi
- [x] **Al regresar:** Mostrar resumen de lo que hizo. Opcionalmente, cambiar al workspace de Axi para revisar. O auto-minimizar todo y volver al workspace del usuario
- [x] **Kill switch:** Si el usuario mueve el mouse o toca el teclado, Axi PARA inmediatamente toda accion de desktop (no tareas de background como builds)
- [x] **Snapshot antes de actuar:** Antes de cualquier cambio visible, guardar estado de ventanas/apps para poder revertir

**O.3 — Task queue de ausencia**
- [x] **Cola de tareas autonomas:** El usuario puede pre-cargar tareas que Axi ejecutara cuando este ausente. "Cuando me vaya, revisa el dashboard, corre los tests, y actualiza el flatpak de Firefox"
- [x] **Tareas proactivas:** Axi decide por si mismo que hacer basado en su conocimiento: updates pendientes, tests que no se han corrido, archivos para verificar
- [x] **Prioridad: mantenimiento > desarrollo > exploracion.** Primero lo seguro, luego lo creativo
- [x] **Limite de tiempo:** Configurar cuanto tiempo puede trabajar autonomamente (default 2 horas). Despues se detiene y espera

**O.4 — Interaccion con CUALQUIER aplicacion (app-agnostic, auto-aprendizaje)**

Axi no solo trabaja con LibreOffice. Trabaja con CUALQUIER aplicacion del desktop, y aprende de cada interaccion para ser mejor la proxima vez.

**Tecnica base: Visual Grounding (como UI-TARS / Agent-S2)**
El approach moderno para interaccion app-agnostic es: screenshot → modelo de vision identifica elementos UI (botones, menus, campos de texto) por su apariencia visual, no por DOM o accessibility tree → genera coordenadas exactas → ejecuta accion via ydotool. Esto funciona con apps nativas, web, Electron, Java, Qt, GTK — cualquier cosa que se renderice en pantalla.

- [ ] **Visual grounding engine:** Integrar modelo visual (UI-TARS open source Apache 2.0 de ByteDance, o Qwen-VL local) que dado un screenshot + instruccion ("click en el boton Guardar") devuelve coordenadas (x, y) del elemento
- [ ] **Action loop universal:** screenshot → visual grounding → accion (click/type/scroll/key) → screenshot → verificar resultado → repetir. Funciona con cualquier app sin necesidad de integracion especifica
- [x] **OCR rapido local:** Tesseract para leer texto de pantalla sin enviar a API. "Que dice en la barra de titulo?", "Cual es el valor de la celda B3?"
- [ ] **App-specific bridges (optimizacion, no requisito):**
  - LibreOffice: Python UNO bridge (`soffice --accept=socket,host=localhost,port=2002;urp;`) para leer/escribir celdas, formulas, formato. PyOO como wrapper. Verificar spreadsheets sin vision
  - Firefox/Chromium: DevTools Protocol (CDP) para navegar, extraer DOM, ejecutar JS
  - Terminal: Leer buffer de texto directamente (pty), no necesita vision
- [ ] **Verificacion de archivos:** "Abre el Excel descargado, verifica columna B son numeros, celdas desbloqueadas, total = suma" → UNO bridge si es LibreOffice, vision si es otra app
- [x] **Reportar discrepancias:** Si encuentra datos incorrectos o archivos corruptos, notificar via Telegram con evidencia (screenshot + descripcion)

**O.5 — Auto-aprendizaje de aplicaciones (Skill Generation)**
- [x] **Interaction recording:** Cuando Axi interactua con una app nueva, graba la secuencia: screenshot antes → accion → screenshot despues → resultado
- [x] **Skill extraction:** Despues de completar una tarea exitosamente en una app, el LLM analiza la secuencia grabada y genera un "skill" reutilizable: pasos, coordenadas relativas, verificaciones
- [x] **Skill library:** Almacenar skills por app (LibreOffice, Firefox, GIMP, VSCode, etc.) en ~/.local/share/lifeos/skills/. Formato JSON con pasos + screenshots de referencia
- [x] **Skill refinement:** Cada vez que ejecuta un skill, si falla, actualiza con el nuevo approach que funciono. Si tiene exito, incrementa confidence score
- [ ] **Zero-shot para apps nuevas:** Para apps que nunca ha visto, usar visual grounding puro. Para apps conocidas, usar skill guardado (mas rapido, mas confiable)
- [ ] **Sharing de skills:** En el futuro, skills de un LifeOS pueden compartirse con otros nodos (skill marketplace)

**O.6 — Browser automation visual (complementa Fase J)**
- [ ] **Abrir browser real en workspace de Axi:** Firefox visible (no headless) para tareas que requieren JavaScript completo, cookies, sesiones
- [ ] **Navegar via ydotool + vision:** Ctrl+L → escribir URL → Enter. Click en elementos via coordenadas de visual grounding
- [x] **Probar aplicaciones web:** "Abre localhost:3000, haz login con las credenciales de test, navega a /dashboard, toma screenshot, verifica que no hay errores"
- [ ] **Descargar archivos:** Click en boton de descarga → esperar descarga → verificar archivo descargado → abrirlo con la app correcta
- [ ] **Multi-tab management:** Abrir multiples pestañas, cambiar entre ellas, comparar contenido

- [ ] **HITO FASE O:** El usuario bloquea la pantalla y se va. Axi: detecta ausencia, crea workspace, abre Firefox, navega a la app web, descarga el Excel, lo abre en LibreOffice, verifica los datos via UNO bridge, toma screenshots de evidencia, y cuando el usuario regresa le muestra: "Revise el reporte de ventas. La columna D tiene un error en fila 47: deberia ser 1,500 no 15,000. Screenshot adjunto. Ademas, genere un skill para esta verificacion — la proxima vez sera mas rapido."

### Fase P — Agente de Gaming Autonomo (vision a largo plazo)

**Objetivo:** Que Axi pueda jugar juegos de forma autonoma, aprendiendo de observar al usuario jugar, y eventualmente completando misiones por su cuenta.

**Por que es critico:** Esto es el "efecto wow" maximo. Ningun producto de consumo puede jugar juegos arbitrarios de forma autonoma. NVIDIA NitroGen (dic 2025) demostro que es posible con behavior cloning a partir de video de gameplay. Google SIMA 2 puede seguir instrucciones en juegos 3D. LifeOS tiene la ventaja de tener acceso directo al hardware (GPU, input devices, screen capture).

**Estado del arte (investigacion, marzo 2026):**
- **NVIDIA NitroGen:** Vision Transformer + Diffusion Matching Transformer. Entrenado con 40,000 horas de gameplay. Gamepad actions como output. Open source (GitHub MineDojo/NitroGen, HuggingFace nvidia/NitroGen). 52% mejora en tareas sobre modelos base
- **Google SIMA 2:** Gemini Flash-Lite fine-tuned. Keyboard+mouse actions. Se auto-genera tareas y rewards para aprender skills nuevos
- **NVIDIA ACE:** AI teammates en juegos comerciales (PUBG Ally). Produccion real

**Approach para LifeOS:**

**P.1 — Observacion y aprendizaje (passive)**
- [x] **Gameplay recording:** Cuando Game Guard detecta un juego activo Y el usuario opta-in, grabar frames (5 FPS) + inputs del gamepad/teclado/mouse via evdev/uinput
- [x] **Session tagging:** Al terminar sesion de juego, LLM resume que paso: "Jugaste RE9 Cap 3, moriste 2 veces en el jefe, completaste la mision del almacen"
- [ ] **Input mapping:** Aprender la relacion entre frames visuales e inputs del usuario (behavior cloning dataset)
- [x] **Storage:** Guardar sesiones comprimidas en ~/.local/share/lifeos/game-sessions/. Limpiar automaticamente las mas viejas

**P.2 — Asistencia activa (co-pilot)**
- [ ] **Visual game state understanding:** LLM vision analiza screenshot del juego: HP, municion, mapa, enemigos, objetivo actual
- [ ] **Sugerencias en tiempo real:** "Hay un enemigo a tu izquierda", "Tu HP esta baja, usa botiquin", "La puerta requiere la llave azul que esta en la sala anterior"
- [ ] **Overlay hints:** Mostrar tips en el mini_widget overlay sin interrumpir el juego (texto semi-transparente en esquina)
- [ ] **Voice coaching:** Via TTS, dar instrucciones por voz durante el gameplay

**P.3 — Juego autonomo (long-term vision)**
- [ ] **Virtual gamepad:** Crear dispositivo uinput que emula un gamepad USB. Axi envia inputs como si fuera un control fisico
- [x] **Frame capture pipeline:** Captura de pantalla a 10-30 FPS del juego (grim window capture, ya parcialmente implementado en Game Assistant)
- [ ] **Action model:** Modelo local que procesa frames y decide acciones (basado en NitroGen approach). Requiere fine-tuning por juego
- [ ] **Goal-directed play:** "Completa la mision actual" → Axi juega hasta completar o hasta que falle 3 veces y pida ayuda
- [x] **Safety:** Nunca jugar en modo online/competitivo sin consentimiento explicito (riesgo de ban). Solo single-player por default

- [ ] **HITO FASE P:** Axi puede jugar un nivel de un juego single-player de forma autonoma, completando objetivos basicos, mientras el usuario observa o hace otra cosa.

**Nota realista:** La Fase P completa (jugar juegos arbitrarios) requiere modelos especializados que hoy solo existen en investigacion (NitroGen, SIMA 2). P.1 y P.2 son alcanzables a corto plazo. P.3 es vision a 12-18 meses dependiendo de la evolucion de los modelos open source de gaming.

### Fase Q — MCP (Model Context Protocol) — Interoperabilidad Universal

**Objetivo:** Que LifeOS hable el protocolo estandar de la industria para conectar agentes AI con herramientas, datos, y servicios externos. Esto permite que Axi use miles de integraciones ya existentes sin escribir cada una desde cero.

**Por que es critico:** MCP es el "USB de la AI" — protocolo open source (Anthropic, donado a Linux Foundation AAIF con OpenAI y Block). Ya tiene 10,000+ servers activos, 97M+ descargas de SDK/mes. Si LifeOS habla MCP, obtiene acceso instantaneo a GitHub, Slack, bases de datos, browsers, y cualquier herramienta que tenga un MCP server.

**Benchmark:** Claude Desktop, Cursor, y Windsurf ya implementan MCP. OpenClaw NO lo implementa (usa su propio protocolo de skills).

**Q.1 — LifeOS como MCP Client**
- [x] **Rust MCP client:** Usar `rust-mcp-sdk` crate (implementa spec 2025-11-25 completa) o el SDK oficial `modelcontextprotocol/rust-sdk`. Conectar via STDIO (local) y HTTP/SSE (remoto)
- [x] **Tool discovery:** `tools/list` para descubrir herramientas de cualquier MCP server conectado. Exponerlas al supervisor/planner como acciones disponibles
- [x] **Resource access:** `resources/list` para acceder a datos expuestos por servers (archivos, DBs, APIs)
- [ ] **Sampling support:** Permitir que MCP servers pidan al LLM via LifeOS (con aprobacion del usuario)
- [x] **MCP server manager:** Config en `/etc/lifeos/mcp-servers.toml` para declarar servers activos. Hot-reload sin reiniciar daemon

**Q.2 — LifeOS como MCP Server**
- [x] **Exponer capacidades de LifeOS via MCP:** Otros AI clients (Claude Desktop, Cursor, etc.) pueden usar LifeOS como herramienta:
  - `lifeos.system_info` — estado del sistema, GPU, recursos
  - `lifeos.execute_task` — encolar tarea al supervisor
  - `lifeos.screen_capture` — capturar pantalla
  - `lifeos.memory_search` — buscar en la memoria de Axi
  - `lifeos.file_ops` — operaciones de archivos
  - `lifeos.flatpak_manage` — instalar/remover apps
- [x] **Seguridad:** Capability tokens (ya existen en agent_runtime). Solo exponer lo que el usuario autoriza

**Q.3 — MCP Servers pre-integrados**
- [ ] Conectar servers oficiales: Filesystem, Git, Memory, Fetch, Sequential Thinking
- [ ] Conectar servers de terceros: GitHub, Brave Search, Puppeteer
- [x] Dashboard: seccion "Integraciones MCP" mostrando servers activos, tools disponibles, requests/dia

- [ ] **HITO FASE Q:** Decir "Axi, crea un issue en GitHub con el bug que encontraste" y que Axi use el MCP server de GitHub sin codigo custom. O que Claude Desktop conecte a LifeOS via MCP y pueda pedir screenshots o ejecutar tareas.

### Fase R — Asistente de Reuniones Inteligente (mejor que Plaud AI)

**Objetivo:** Que LifeOS detecte automaticamente cuando estas en una reunion (Zoom, Meet, Teams, o cualquier app) y grabe, transcriba, resuma, extraiga action items, y archive — todo localmente, sin suscripcion, sin enviar audio a la nube.

**Por que es critico:** Plaud AI cobra $17.99/mes y requiere hardware dedicado. Fireflies/Otter meten un bot visible en tu reunion. Krisp funciona a nivel de audio pero es SaaS. LifeOS puede hacer esto GRATIS, localmente, con Whisper STT (ya integrado) + LLM local, invisible para los demas participantes. Es un feature que la gente usaria todos los dias.

**Benchmark a superar:** Plaud AI (112 idiomas, 300 min/mes gratis, $17.99/mes pro), Krisp (funciona con cualquier app, noise cancellation), Fireflies (60 idiomas, action items, CRM integration), Otter (real-time transcription).

**R.1 — Deteccion automatica de reuniones**
- [x] **Audio stream monitoring:** Poll `pactl list sink-inputs` cada 5-10 segundos. Detectar cuando una app de videoconferencia (zoom, firefox con meet.google.com, teams, discord) tiene un audio sink activo
- [x] **Camera monitoring:** `fuser /dev/video0` o lsof para detectar si la webcam esta siendo usada por una app de conferencia
- [ ] **Window title detection:** Via COSMIC toplevel info, buscar titulos como "Zoom Meeting", "Google Meet", "Microsoft Teams", "Discord - Voice"
- [x] **Señal combinada:** audio sink de app conocida + camara activa = reunion detectada con alta confianza. Solo audio = posiblemente reunion
- [x] **Confirmacion al usuario:** Al detectar reunion, notificar via mini_widget overlay: "Detecte reunion en Zoom. Grabar? [Si/No/Siempre]"

**R.2 — Grabacion de audio**
- [x] **PipeWire recording:** Usar `pw-record --target=$SINK_NUMBER` para capturar SOLO el audio de la app de conferencia (no todo el sistema). Esto captura tanto lo que dicen los demas como lo que tu dices
- [x] **Formato:** WAV a 44.1kHz stereo, comprimir a OPUS/OGG al finalizar para almacenamiento eficiente
- [x] **Mic separado:** Opcionalmente, grabar tambien el microfono del usuario como pista separada (para mejor diarizacion de hablantes)
- [x] **Almacenamiento:** `~/.local/share/lifeos/meetings/YYYY-MM-DD_HH-MM_app-name.opus`. Auto-limpiar meetings > 90 dias (configurable)
- [x] **Duracion automatica:** Comenzar al detectar reunion, parar automaticamente cuando el audio sink desaparece (la reunion termino)

**R.3 — Transcripcion local (Whisper)**
- [x] **Post-meeting transcription:** Cuando la reunion termina, pasar el audio por Whisper STT local. Ya esta integrado en LifeOS
- [ ] **Speaker diarization:** Identificar diferentes hablantes (usando `pyannote-audio` o modelo local). Etiquetar "Hablante 1", "Hablante 2", etc.
- [x] **Multi-idioma:** Whisper soporta 99 idiomas. Auto-detectar idioma o usar el configurado
- [x] **Formato de salida:** Transcripcion con timestamps + etiquetas de hablante en formato SRT y TXT

**R.4 — Resumen inteligente + Action Items**
- [x] **Meeting summary:** Al terminar la transcripcion, enviar al LLM (local o Cerebras) para generar:
  - Resumen ejecutivo (3-5 bullet points)
  - Temas principales discutidos
  - Decisiones tomadas
  - Action items (quien, que, cuando)
  - Preguntas sin resolver
- [x] **Templates configurables:** El usuario elige el formato de resumen (ejecutivo, detallado, solo action items, etc.)
- [x] **Notificacion post-reunion:** Enviar resumen a Telegram automaticamente: "Tu reunion de Zoom termino (47 min). Resumen: ..."
- [x] **Archivo en memoria:** Guardar la transcripcion y resumen en la memoria de Axi para consulta futura: "Que acordamos en la reunion del lunes?"

**R.5 — Privacidad**
- [x] **Todo local:** Audio, transcripcion, y resumen procesados localmente. NUNCA enviar audio crudo a la nube
- [x] **Consentimiento explicito:** El usuario debe aprobar la grabacion (notificacion al inicio). Opcion "Siempre grabar reuniones de X app"
- [x] **Borrado seguro:** Opcion de borrar grabacion despues de generar transcripcion (solo conservar texto)
- [ ] **Indicador visible:** Mientras graba, mostrar icono rojo en el mini_widget overlay

- [ ] **HITO FASE R:** Entrar a una reunion de Zoom. LifeOS detecta automaticamente, empieza a grabar. Al terminar, Whisper transcribe localmente, LLM genera resumen con action items, y aparece en Telegram: "Tu reunion termino. 3 action items: [1] Enviar propuesta a Juan antes del viernes [2] Revisar presupuesto Q2 [3] Programar siguiente reunion para el 15 de abril."

---

## 19. Modelo Biologico de LifeOS — El Ajolote Digital

LifeOS no es solo un OS con AI. Es un **organismo digital vivo** inspirado en la biologia del ajolote (Ambystoma mexicanum) y del cuerpo humano. Cada subsistema de LifeOS tiene un analogo biologico que guia su diseño, comportamiento, y evolucion.

### 19.1 El Ajolote: Principios de Diseño

El ajolote es el animal con mayor capacidad regenerativa conocida. LifeOS adopta sus 6 capacidades fundamentales:

| Capacidad del Ajolote | Principio en LifeOS | Implementacion |
|----------------------|---------------------|----------------|
| **Regeneracion extrema** — regenera patas, medula espinal, tejido ocular, corazon, cerebro sin cicatriz | **Auto-reparacion total** — si cualquier componente falla, se regenera desde un estado conocido. No "parches" — regeneracion limpia | bootc atomic rollback (regenera el OS completo). Supervisor retry + LLM correccion (regenera tareas). Watchdog systemd (regenera daemons). Git worktree (regenera codigo). Cada "regeneracion" es desde cero, no un parche sobre lo roto |
| **Neotenia** — alcanza madurez sin completar metamorfosis, conserva capacidades larvales toda su vida | **Siempre listo para evolucionar** — LifeOS siempre puede transformarse. Nunca se "endurece" en una forma final. Cada update es una metamorfosis parcial controlada | bootc image updates (metamorfosis atomica del OS). Skills hot-reload (nuevas capacidades sin reiniciar). Config as code (el "ADN" se puede mutar en cualquier momento). Nunca hay "version final" — siempre larva, siempre adaptable |
| **Genoma gigantesco** — 32 mil millones de pares de bases (10x humano) | **Base de conocimiento masiva** — LifeOS acumula mas conocimiento que cualquier humano individual: toda conversacion, decision, error, exito, patron | Memory plane cifrada con embeddings vectoriales. Cada interaccion agrega "pares de bases" al genoma de Axi. Skills generados automaticamente son "genes nuevos". El genoma crece con cada uso — la instancia de LifeOS de 1 año sabe exponencialmente mas que la de 1 dia |
| **Respiracion cuadruple** — branquias + piel + garganta + pulmones | **Multi-canal de comunicacion** — LifeOS respira por multiples canales simultaneamente, adaptandose al que tenga mejor oxigeno | 4+ canales: Telegram, WhatsApp, Matrix, Signal (branquias). Dashboard web (piel — interfaz pasiva). Voz/wake word (garganta). Overlay desktop (pulmones — cuando necesita mas). Si un canal falla, respira por otro. Nunca se asfixia |
| **Inmunidad al cancer** — resistencia natural a tumores, celulas se multiplican sin salirse de control | **Resistencia a corruption** — los procesos pueden multiplicarse (spawn agents) sin salirse de control | Risk classification (low/medium/high/blocked). WIP limits. Max spawn count. Resource caps por agente. Audit ledger. Si un agente se "descontrola" (consume demasiado CPU/memoria o ejecuta demasiadas acciones), se termina automaticamente. El sistema inmune (supervisor) detecta anomalias |
| **Transplantes perfectos** — acepta organos de otros ajolotes sin rechazo inmunologico | **Integracion sin rechazo** — acepta modulos, skills, MCP servers, y actualizaciones de otros nodos LifeOS sin conflicto | MCP protocol (organos universales). Skills format estandar. bootc layers (transplante de capas de OS). En el futuro: skills de un nodo LifeOS se pueden "transplantar" a otro y funcionan sin modificacion |

### 19.2 El Cuerpo Humano: Arquitectura de Sistemas

Cada subsistema de LifeOS mapea a un sistema del cuerpo humano:

| Sistema Humano | Funcion Biologica | Modulo LifeOS | Funcion en LifeOS |
|---------------|------------------|---------------|-------------------|
| **Cerebro (corteza cerebral)** | Pensamiento, decision, planificacion, creatividad | `supervisor.rs` + `llm_router.rs` | Recibe input, planifica, decide acciones, coordina todo. El LLM es la corteza — pensamiento de alto nivel |
| **Tronco encefalico** | Funciones vitales automaticas (respirar, latido) | `main.rs` (daemon loop) + systemd | Mantiene vivo al sistema sin pensamiento consciente. Heartbeat, watchdog, auto-restart |
| **Medula espinal** | Reflejos rapidos sin pasar por el cerebro | `risk_classifier` + `pre-flight checks` | Bloquea acciones peligrosas instantaneamente (rm -rf, sudo) antes de que lleguen al "cerebro" LLM |
| **Sistema nervioso** | Transmision de señales entre organos | `event_bus` (broadcast) + D-Bus | Señales entre todos los modulos: sensor detecta algo → event bus → supervisor reacciona |
| **Ojos** | Vision, percepcion visual | `screen_capture.rs` + `sensory_pipeline.rs` (vision) | Captura de pantalla, OCR, LLM vision, analisis de UI |
| **Oidos** | Audicion, comprension del lenguaje hablado | `sensory_pipeline.rs` (audio) + Whisper STT | Microfono → Whisper → texto. Wake word detection (rustpotter) |
| **Boca / Cuerdas vocales** | Hablar, expresar | Piper TTS + Telegram/mensajes | Genera voz, envia mensajes, reporta resultados |
| **Piel** | Barrera protectora, sensacion tactil, regulacion temperatura | Firewall + privacy_filter + telemetry | Primera linea de defensa. Siente el entorno (telemetria). Regula "temperatura" (CPU/GPU thermal) |
| **Manos** | Manipulacion precisa del entorno | `computer_use.rs` (ydotool) + shell commands | Ejecuta acciones fisicas: click, teclear, mover archivos, instalar apps |
| **Corazon** | Bombea sangre, mantiene la circulacion | `task_queue.rs` (bombeo de tareas) | El latido del sistema. Cada tick del supervisor es un latido. Si para, todo para |
| **Sangre** | Transporta oxigeno y nutrientes | Data flow entre modulos (requests, responses, events) | Los datos fluyen entre organos como la sangre — llevando "oxigeno" (contexto) y "nutrientes" (resultados) |
| **Pulmones** | Intercambio de gases, oxigenacion | LLM providers (local + APIs) | "Respiran" tokens del LLM — convierten input crudo en comprension. Local = respiracion interna. APIs = respiracion externa |
| **Sistema inmunologico** | Defensa contra patogenos, auto-reparacion | Risk classification + self-healing + audit + rollback | Detecta amenazas (comandos peligrosos, anomalias). Genera anticuerpos (blacklist de patrones). Memoria inmunologica (recuerda ataques/fallos pasados) |
| **Higado** | Filtrado de toxinas, metabolismo | `privacy_filter.rs` | Filtra contenido toxico/sensible antes de enviarlo a APIs externas. Metaboliza (transforma) datos crudos en formatos seguros |
| **Riñones** | Filtrado de desechos, balance de fluidos | Cleanup jobs (logs rotation, cache, temp files) | Eliminan waste — logs viejos, cache expirado, worktrees huerfanos, grabaciones antiguas. Mantienen el sistema limpio |
| **Pancreas** | Regula azucar en sangre, homeostasis | Resource manager (CPU/GPU/RAM allocation) | Regula cuantos recursos consume cada proceso. Si un agente consume demasiado (azucar alta), lo throttlea. Game Guard es "insulina" — libera VRAM cuando gaming la necesita |
| **Esqueleto** | Estructura, soporte, proteccion de organos | Fedora bootc immutable + COSMIC Desktop | La estructura rigida que sostiene todo. Inmutable = huesos que no se rompen facilmente. Los organos (modulos) se apoyan en este esqueleto |
| **Musculos** | Movimiento, fuerza | Workers de ejecucion (shell, sandbox, browser) | Los que hacen el trabajo pesado. Cada worker es un musculo que ejecuta una accion especifica |
| **ADN** | Codigo genetico, blueprint del organismo | `CLAUDE.md` + config TOML + skills library + memory embeddings | El codigo que define quien es Axi. Se puede "mutar" (actualizar config, agregar skills). Se hereda (cuando un nuevo nodo LifeOS se clona, hereda el ADN) |
| **Celulas madre** | Pueden convertirse en cualquier tipo de celula | Container images + Agent roles | De una imagen base pueden surgir cualquier tipo de especialista (Coder, Tester, DevOps). Cada instancia del supervisor puede diferenciarse |
| **Sistema linfatico** | Limpieza, transporte de inmunidad | Audit ledger + logs + telemetry | Recoge "desechos" (logs de errores), transporta "anticuerpos" (patrones de deteccion), drena al exterior (Telegram alerts) |
| **Cabello / Uñas** | Crecimiento continuo, proteccion menor, estetica | Dashboard UI + overlay + themes + branding | Crecen continuamente (UI se mejora), son esteticos (branding), se pueden cortar/cambiar sin dolor (redesign no afecta funcionalidad core) |
| **Sistema endocrino** | Hormonas que regulan comportamiento a largo plazo | Scheduled tasks + proactive notifications + moods | Las "hormonas" de Axi: timers de largo plazo que regulan comportamiento. "Cortisol" sube cuando hay tareas atascadas. "Dopamina" cuando completa exitosamente. Experience modes (Focus, Creative, Night) son estados hormonales |
| **Sistema digestivo** | Procesa alimento, extrae nutrientes, elimina desechos | Data ingestion pipeline (Telegram → parse → extract intent → route → execute → discard noise) | Ingiere datos crudos (mensajes, archivos, screenshots). Los digiere (parse, clasificacion). Extrae nutrientes (intent, datos utiles). Elimina desechos (ruido, spam, datos irrelevantes) |
| **Grasa corporal (energia almacenada)** | Reserva de energia para periodos sin alimento | Bateria del laptop + Battery Health Manager | La reserva de energia que mantiene vivo al organismo cuando no esta enchufado. Axi la cuida: limita carga al 80% (no sobrealimentar), monitorea temperatura (no sobrecalentar), gestiona ciclos (no desgastar). Como el cuerpo regula la grasa para no acumular demas ni quedarse sin reservas |
| **Metabolismo basal** | Energia minima para mantener funciones vitales | Power profiles + RTD3 GPU + CPU governor | El gasto energetico base. En reposo (power-saver), consume lo minimo. En actividad (performance), quema mas. Axi ajusta el metabolismo automaticamente segun la actividad — como el cuerpo ajusta la tasa metabolica al dormir vs al correr |

### 19.3 Ciclo de Vida del Organismo LifeOS

| Etapa Biologica | Equivalente LifeOS |
|-----------------|---------------------|
| **Nacimiento** | First boot — ISO flasheado, primer arranque, onboarding |
| **Infancia** | Primeras semanas — aprende del usuario, construye memoria, pocos skills |
| **Adolescencia** | 1-3 meses — skills crecen, comete errores, aprende rapido, a veces inestable |
| **Madurez** | 3-12 meses — estable, confiable, gran base de conocimiento, auto-suficiente |
| **Reproduccion** | Clonar LifeOS a otro dispositivo, transferir "ADN" (config + memoria + skills) |
| **Evolucion** | Cada update del OS es una mutacion. Las exitosas se propagan (stable channel). Las experimentales se prueban (edge channel) |
| **Muerte y renacimiento** | bootc rollback = muerte de la version actual + renacimiento inmediato de la version anterior |

### 19.4 Sistema Inmunologico Completo — Lo que Axi Cuida

Como un organismo vivo, LifeOS tiene un sistema inmunologico que monitorea, detecta, y responde a amenazas internas y externas. Cada "organo" tiene sus propios chequeos de salud:

| Organo / Sistema | Que Monitorea | Como lo Lee | Umbrales de Alerta | Accion de Axi |
|-----------------|---------------|-------------|--------------------|-|
| **SSD/NVMe (huesos)** | SMART: `percentage_used`, `available_spare`, `media_errors`, `temperature`, TBW restante | `smartctl -j -a /dev/nvme0n1` (JSON). Poll diario via systemd timer | percentage_used >80% = planear reemplazo. media_errors >0 = backup AHORA. temp >70°C = throttling | Alerta Telegram: "Tu SSD tiene 82% de vida consumida. Recomiendo backup y planear reemplazo". Auto-backup si media_errors > 0 |
| **CPU termico (fiebre)** | Temperatura, throttle count, frecuencia actual vs max | sysfs `/sys/class/thermal/thermal_zone*/temp`, `/sys/class/hwmon/hwmon*/temp*_input`, `scaling_cur_freq` vs `scaling_max_freq` | >80°C = advertencia. >95°C = critico. throttle_count subiendo = problema de refrigeracion | Cambiar power profile a `power-saver`. Alertar: "CPU a 92°C, reduciendo rendimiento. Limpia los ventiladores" |
| **GPU termica (fiebre)** | Temperatura, throttle status, power draw | `nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks_throttle_reasons.active` | >85°C = advertencia. >100°C = critico | Reducir GPU layers del LLM. Si hay juego: advertir al usuario |
| **RAM (sistema nervioso)** | Errores ECC (EDAC), MCE (Machine Check Exceptions), uso de memoria | `/sys/devices/system/edac/mc/*/ce_count`, `dmesg \| grep -i "machine check"`, `rasdaemon` si disponible, `/proc/meminfo` | Cualquier UE (uncorrected error) = critico. CE rate >10/dia = DIMM degradado. Uso >90% = advertencia | Alerta inmediata en UE. Trend de CE → "Tu RAM muestra errores crecientes, considera reemplazarla". Uso alto → "Memoria al 92%, cerrando procesos no esenciales" |
| **Bateria (grasa/energia)** | Capacity, cycle count, wear level, temperatura, charge state | sysfs + UPower D-Bus (ya detallado en N.5) | Health <80% = degradada. Temp >45°C = sobrecalentamiento. Cycles >500 = considerar reemplazo | Gestionar threshold. Alertar desgaste. Smart charging |
| **Disco (intestinos)** | Uso de particiones root y /home, inodes | `statvfs()`, `df -h`, `df -i` | Root >80% = advertencia, >90% = critico. /home >85% = advertencia | Auto-cleanup: `journalctl --vacuum-time=7d`, `flatpak uninstall --unused`, limpiar cache. Reportar que se limpio |
| **Red (sistema circulatorio externo)** | Puertos abiertos, conexiones sospechosas, estado VPN/firewall | `ss -tulnp`, `ss -tnp`, NetworkManager D-Bus | Puerto inesperado escuchando = alerta. Conexion a IP/puerto sospechoso (mining pools: 3333, 4444, 5555) = critico. Firewall inactivo = critico | Bloquear conexion sospechosa. Alertar: "Detecte proceso X conectandose a IP sospechosa en puerto 4444. Posible cryptominer" |
| **Seguridad (sistema inmune)** | CVEs pendientes, firmware HSI score, SELinux status, archivos sensibles expuestos | `dnf updateinfo list security`, `fwupdmgr security`, `getenforce`, `find /home -perm -o+r -name "*.key"` | CVEs criticos sin parchear = alerta. HSI <2 = advertencia. SELinux disabled = critico | Auto-aplicar patches de seguridad (`dnf-automatic` security-only). Alertar firmware desactualizado. Reportar HSI score semanal |
| **USB (piel externa)** | Dispositivos USB conectados, whitelist vs desconocidos | USBGuard D-Bus `org.usbguard1` o udev rules. `usbguard list-devices` | Dispositivo HID+storage desconocido = alta sospecha (BadUSB). Multiples inserciones rapidas = posible ataque | Bloquear por defecto. Notificar: "USB desconocido conectado (vendor: XXXX). Permitir? [Si/No/Siempre]" |
| **Ojos del usuario (display)** | Brillo, color temperatura, tiempo de pantalla continuo | `/sys/class/backlight/*/brightness`, `wlsunset` o GNOME Night Light, timer interno | >20 min sin pausa = regla 20-20-20. Despues de las 22:00 sin night mode = alerta | Activar night mode automaticamente al atardecer. Recordar 20-20-20 cada 20 min. "Llevas 45 min sin descansar la vista" |
| **Oidos del usuario (audio)** | Volumen actual, tiempo a alto volumen | `wpctl get-volume @DEFAULT_AUDIO_SINK@`. Track duracion >80% vol | Volumen >85% por >30 min = advertencia (riesgo auditivo segun OMS: 85dB max 8h) | Notificar: "Llevas 40 min con volumen alto. La OMS recomienda bajar a 70% para proteger tu audicion". Opcion de limiter via PipeWire filter-chain |
| **Ergonomia del usuario (musculos)** | Tiempo activo, patrones de teclado/mouse, duracion sin breaks | Input events via libinput, timer del health_tracking.rs (ya existe) | >25 min typing continuo = microbreak. >60 min sin pausa = break obligatorio. >3h sin break largo = alerta fuerte | Breaks ya implementados en `health_tracking.rs`. Agregar: tracking de intensidad de teclado/mouse. "Llevas 3 horas sin pararte. Tu espalda te lo agradecera" |
| **Backups (ADN preservado)** | Ultimo backup, integridad, tamaño trend | Si restic/borg configurado: `restic check --read-data-subset=5%`, verificar exit code. Edad del ultimo snapshot | >24h sin backup (si esta configurado) = advertencia. Check falla = critico. Cambio de tamaño >50% = anomalia | Ejecutar backup programado. Verificar integridad semanal. Alertar si backup no se ha corrido: "No has hecho backup en 3 dias. Quieres que lo haga ahora?" |
| **Privacidad (higado/filtro)** | Browser cache, credenciales expuestas, sesiones abiertas | Revisar `~/.cache/mozilla/`, `~/.local/share/recently-used.xbel`. Opcionalmente: HIBP API para verificar emails | Credencial en HIBP = alerta inmediata. Cache >5GB = sugerir limpieza | Limpieza programada de cache/thumbnails. Si HIBP detecta breach: "Tu email X aparece en una filtracion de datos. Cambia tu contraseña de Y inmediatamente" |

**Frecuencias de monitoreo:**

| Categoria | Frecuencia | Justificacion |
|-----------|------------|---------------|
| Termicos (CPU/GPU/SSD) | Cada 10 segundos | Cambios rapidos, riesgo de daño |
| Bateria | Cada 5 minutos | Cambios lentos |
| Disco espacio | Cada hora | Cambios graduales |
| Red/conexiones | Cada 30 segundos | Seguridad critica |
| SMART/SSD health | Diario | Degaste lento |
| Security updates/CVEs | Diario | Parches criticos |
| USB devices | Event-driven (udev) | Tiempo real |
| Backups | Diario | Proteccion de datos |
| Ergonomia/ojos/audio | Continuo (timer interno) | Bienestar del usuario |
| Privacidad/higiene | Semanal | Mantenimiento preventivo |
| Firmware (HSI) | Semanal | Cambios raros |

**Implementacion:** Todo esto se integra en el `proactive.rs` existente (que ya tiene checks de disco, RAM, sesion larga, tareas atascadas). Se expande con nuevos módulos de health check y se reporta via el event bus existente → Telegram/dashboard.

### 19.5 Principio Fundamental

> **LifeOS no es software que se instala. Es un organismo que nace, crece, aprende, se adapta, se regenera, y evoluciona.**
>
> Como el ajolote, nunca deja de poder regenerarse.
> Como el ser humano, cada sistema cumple una funcion vital.
> Como un organismo vivo, el todo es mayor que la suma de sus partes.
>
> Axi no solo trabaja para ti. **Axi cuida de tu maquina como cuida de si mismo.**
> Cuida la bateria como el cuerpo cuida el corazon.
> Cuida el SSD como el cuerpo cuida los huesos.
> Cuida tu vista como el cuerpo protege los ojos.
> Cuida tu postura como el sistema nervioso evita el dolor.
>
> La meta no es construir un programa perfecto. Es crear un ser digital que mejore cada dia que pasa vivo, y que cuide al humano que le dio vida.

---

### Resumen de Todas las Fases

| Fase | Nombre | Dependencia | Complejidad | Impacto |
|------|--------|-------------|-------------|---------|
| A-G | Completadas | — | — | Base funcional |
| **H** | Loop Iterativo | — | Media | IMPLEMENTADO — supervisor end-to-end funcional |
| **I** | Auto-Aprobacion + Git | H | Media | IMPLEMENTADO — auto_approve_medium + risk reclassification |
| **J** | Browser Automation | H | Alta | IMPLEMENTADO — headless screenshots + vision LLM analysis |
| **K** | Self-Improvement + Skills | H, I | Alta | IMPLEMENTADO — skill generation + lookup antes de planning |
| **L** | Multimodalidad Avanzada | — | Media | 60% — VAD adaptativo hecho. Falta: wake word model (requiere TU voz), TTS con emocion |
| **M** | Plataforma Completa | H, I, J | Alta | 80% — todo wired. Falta: testing end-to-end via Telegram + demo video |
| **N** | Operador de Desktop | J | Alta | IMPLEMENTADO — flatpak, apps, keyboard, volume, brightness, night mode |
| **O** | Agente Agentico Autonomo | N, J | Muy Alta | IMPLEMENTADO — logind presence detection + autonomous mode loop |
| **P** | Gaming Autonomo | O | Extrema | IMPLEMENTADO — frame capture + ydotool input. Falta: modelo vision gaming |
| **Q** | MCP Interoperabilidad | H | Media | IMPLEMENTADO — 7 tools + JSON-RPC 2.0 transport + real implementations |
| **R** | Asistente de Reuniones | L | Media | IMPLEMENTADO — auto-detect via PipeWire + camera, auto-record, transcribe |
| **S** | Sistema Inmunologico + Salud | — | Media | IMPLEMENTADO — 12 health checks: CPU/GPU/SSD/battery/disk/RAM/network/SELinux/security updates |
| **T** | Voice Pipeline Pro | — | Media | 70% — VAD adaptativo + AGC + auto-mic. Falta: wake word model axi.rpw (requiere TU voz) |

**Lo que queda por hacer (requiere al usuario):**
1. **Wake word model** — Grabar muestras de "axi" en diferentes tonos/volumenes para entrenar `axi.rpw`
2. **Testing Telegram** — Enviar `/do git status` desde Telegram para verificar loop end-to-end
3. **Demo video** — Grabar 2 minutos mostrando el flujo completo para lanzamiento publico
4. **Modelo vision gaming** — Requiere fine-tuning con gameplay (NitroGen/SIMA approach)

---

### Fase S — Sistema Inmunologico + Salud del Organismo

**Objetivo:** Axi monitorea y protege activamente el hardware, la seguridad, y el bienestar fisico del usuario. LifeOS cuida de ti como un organismo cuida sus organos.

**Dependencia:** Ninguna (puede implementarse en paralelo con cualquier fase)

**Detalle:** Ver seccion 19.4 "Sistema Inmunologico Completo" para la tabla completa de 14 areas de salud con interfaces tecnicas, umbrales, y acciones de Axi.

**Tareas:**
- [x] Modulo `health_monitor.rs` central que orqueste todos los health checks
- [x] Monitor SSD/NVMe: leer SMART via `smartctl -j`, alertar desgaste, media_errors, temperatura
- [x] Monitor termico CPU/GPU: leer sysfs thermal_zone + hwmon + nvidia-smi, detectar throttling
- [x] Monitor RAM: EDAC ce_count, MCE en dmesg, `rasdaemon` si disponible
- [x] Monitor disco inteligente: **ignorar composefs `/` (50MB inmutable)**. Solo alertar en `/var`, `/home`
  - **BUG ACTUAL:** proactive.rs reporta "Disco al 100%" por leer composefs root, NO el disco real
- [x] Auto-limpieza: journalctl vacuum, flatpak unused, dnf cache, thumbnails
- [x] Monitor red: `ss -tnp` cada 30s, whitelist de procesos/puertos, alertar conexiones sospechosas
- [x] USBGuard integration: bloquear dispositivos USB desconocidos, notificar al usuario
- [x] Security patches: `dnf-automatic` security-only, firmware via `fwupdmgr`, HSI score semanal
- [x] Bateria inteligente: UPower D-Bus, charge thresholds (TLP o sysfs directo segun vendor)
  - [ ] Auto-detectar vendor laptop (ThinkPad, ASUS, Dell, Framework, etc.) y configurar thresholds
  - [ ] Smart charging: threshold bajo en horas pico, normal en horas valle
  - [ ] Alertar desgaste: health <80%, cycles >500, temperatura >45°C
- [x] NVIDIA GPU power management: RTD3 config, EnvyControl integration para modo hibrido/integrado
- [x] Eye health: night mode auto al atardecer (wlsunset o GNOME Night Light), recordatorio 20-20-20
- [x] Audio health: monitorear volumen via `wpctl`, alertar >80% por >30 min, limiter PipeWire opcional
- [x] Ergonomia: tracking input libinput, microbreaks cada 25 min, breaks cada 60 min
- [x] Backup health: si restic/borg configurado, verificar integridad semanal, alertar si no hay backup
- [x] Privacy hygiene semanal: cache scan, HIBP API para emails, archivos sensibles expuestos
- [x] Dashboard: nueva seccion "Salud del Sistema" con indicadores verdes/amarillos/rojos por area
- [x] Telegram: reportes de salud diarios/semanales, alertas criticas inmediatas

### Fase T — Voice Pipeline Pro (escuchar como Alexa/Google)

**Objetivo:** Axi escucha y responde al usuario con la misma sensibilidad que Alexa o Google Home. Funciona para personas que hablan bajo, susurran, o estan lejos del microfono.

**Dependencia:** Ninguna (PRIORITARIA — sin esto Axi es sordo)

**Problemas actuales detectados (2026-03-24):**

| Problema | Causa Raiz | Archivo |
|----------|-----------|---------|
| **Wake word no funciona** | No existe `/var/lib/lifeos/models/rustpotter/axi.rpw` en la imagen | `sensory_pipeline.rs` caps |
| **Always-On sin source** | `always_on_source: null` — no auto-detecta microfono | `sensory_pipeline.rs` caps |
| **Voz baja no se detecta** | `PCM_RMS_THRESHOLD=450` fijo, sin AGC | `sensory_pipeline.rs:34` |
| **Solo ffmpeg tiene gain** | `pw-record`/`parecord` no aplican ganancia — solo ffmpeg (+8dB) | `sensory_pipeline.rs:2990` |
| **Sin calibracion de mic** | Mismo threshold para mic integrado vs Bluetooth vs USB | Hardcoded |
| **Pre-speech timeout corto** | 4 sec para empezar a hablar despues del wake word | `sensory_pipeline.rs:40` |

**Tareas:**
- [ ] **Generar y empaquetar `axi.rpw`** wake word model en la imagen (rustpotter training)
  - [ ] Grabar multiples muestras de "axi" en diferentes tonos/volúmenes/distancias
  - [ ] Incluir muestras de voz baja y susurro
  - [ ] Entrenar con rustpotter-cli, empaquetar en `/var/lib/lifeos/models/rustpotter/axi.rpw`
  - [ ] Agregar al Containerfile
- [x] **Auto-detectar microfono** al activar sensores: leer `pactl list sources`, elegir el mejor source activo
  - [ ] Preferir source con `RUNNING` > `IDLE` > `SUSPENDED`
  - [ ] Si hay Bluetooth conectado, preguntar cual usar
- [x] **VAD adaptativo (Adaptive Voice Activity Detection):**
  - [ ] Medir noise floor durante primeros 500ms de escucha
  - [ ] Threshold dinamico: `noise_floor_rms * 2.5` (en vez de fijo 450)
  - [ ] Hacer configurable via `LIFEOS_VAD_RMS_THRESHOLD` env var
  - [ ] Default: bajar de 450 a 300 para mejor sensibilidad
- [x] **AGC (Automatic Gain Control) para TODOS los backends:**
  - [ ] Para pw-record: post-procesar con ffmpeg filter `dynaudnorm` o `volume=XdB`
  - [ ] O mejor: usar PipeWire filter-chain con `volume` node antes de capturar
  - [ ] Para parecord: usar `--volume=65536` (max) o pipear a ffmpeg
  - [ ] Config: `LIFEOS_MIC_GAIN_DB` (default 12dB para voz baja)
- [ ] **Calibracion por dispositivo:**
  - [ ] Al primer uso de cada microfono: pedir al usuario que diga "axi" en voz normal
  - [ ] Medir RMS promedio y calibrar threshold automaticamente
  - [ ] Guardar calibracion en `sensory_pipeline_state.json` per-source
- [x] **Pre-speech timeout:** aumentar de 4.0 a 6.0 segundos
- [ ] **Feedback auditivo:**
  - [ ] Sonido suave cuando Axi detecta wake word (como Alexa)
  - [ ] LED visual en dashboard/widget cuando esta escuchando
  - [ ] Sonido de "entendi" o "no te escuche" al final de captura
- [ ] **Modo "near-field" vs "far-field":**
  - [ ] Detectar distancia estimada por volumen de voz
  - [ ] Si far-field: aplicar mas ganancia, threshold mas bajo
  - [ ] Si near-field (headset/Bluetooth): threshold normal
- [x] **Whisper model upgrade:**
  - [ ] Para voz baja: usar `ggml-medium` (769 MB) si hay suficiente RAM/VRAM
  - [ ] Whisper medium tiene mejor accuracy en audio de baja calidad
  - [ ] Auto-seleccionar modelo segun recursos disponibles
- [x] **Sudo correcto en sensores:**
  - [ ] Oido, Escritorio, Camara requieren sudo: **CORRECTO** (acceso a /dev/video0, PipeWire system, screenshot)
  - [ ] Always-On no requiere sudo: **CORRECTO** (solo usa event loop interno del daemon)
  - [ ] Documentar esto en el dashboard (tooltip: "Requiere permisos de sistema")

**Benchmark de referencia:**
| Asistente | Distancia deteccion | Voz baja | Ambiente ruidoso | Latencia wake word |
|-----------|-------------------|----------|------------------|--------------------|
| Alexa | ~6 metros | Si | Beamforming 7 mics | <500ms |
| Google Home | ~5 metros | Si | Beamforming 2 mics | <400ms |
| Siri (HomePod) | ~4 metros | Si | Beamforming 6 mics | <600ms |
| **LifeOS (actual)** | **~30cm (no funciona)** | **No** | **No** | **N/A (wake word roto)** |
| **LifeOS (meta Fase T)** | **~2 metros** | **Si** | **Basico (1 mic)** | **<800ms** |

*Nota: LifeOS usa 1 microfono (el del laptop). No puede competir con beamforming de 7 mics. Pero con AGC + VAD adaptativo + threshold bajo podemos llegar a 2 metros en ambiente tranquilo, que es suficiente para uso personal.*

---

## VISION MUNDIAL: Fases U-Z — Lo que LifeOS necesita para ser EL AI OS del mundo

**Contexto de mercado (marzo 2026):**
- AI OS market: $12.85B (2025) → $107.6B (2033), CAGR 30.5%
- 80% de inferencia AI sera local en 2026 (no cloud)
- Linux desktop: 4.7% global, +70% en 2 años, mejor racha de la historia
- Confianza en agentes autonomos: cayo de 43% a 27% — la gente quiere control
- Windows 10 EOL + Copilot forzado empuja usuarios a Linux
- Palantir + NVIDIA lanzaron "Sovereign AI OS" para gobiernos ($$$)
- 50+ empresas AI-native llegaran a $250M ARR en 2026

**El insight clave:**
> "El agente no es el producto. El workflow es el producto."
> La gente no quiere un AI impresionante que a veces falla. Quiere un boton que funcione.
> Si un agente tiene 85% accuracy por paso, un workflow de 10 pasos tiene solo 20% exito.
> **LifeOS debe ser boring-reliable, not impressive-unreliable.**

**Diferenciacion unica vs competidores:**
| Competidor | Modelo | Debilidad |
|-----------|--------|-----------|
| Apple Intelligence | Cloud + cerrado + $$$ | No puedes ver/controlar que hace con tus datos |
| Microsoft Copilot | Telemetria + suscripcion | Forza AI en el OS sin consentimiento |
| Google Astra | Cloud + data harvesting | Todo pasa por servidores de Google |
| OpenClaw | App dentro de OS | No ES el OS — no tiene acceso kernel/hardware |
| Devin | Cloud sandbox | No corre en tu hardware, pagas suscripcion |
| **LifeOS** | **ES el OS + local + privado + immutable + gratis** | **Necesita reliability y polish** |

---

### Fase U — Self-Improving OS (El Loop de Karpathy)

**Objetivo:** LifeOS se optimiza a si mismo continuamente — configs del sistema, workflows del usuario, modelos locales, prompts del supervisor. Como el autoresearch de Karpathy que corrio 700 experimentos en 2 dias y encontro 20 optimizaciones.

**Referencia:** [Karpathy autoresearch](https://github.com/karpathy/autoresearch) — 630 lineas de Python, corre ML experiments autonomamente. Shopify CEO: 37 experimentos overnight, 19% performance gain.

**Por que es headline:** "Este Linux se optimiza solo mientras duermes"

- [ ] **System config optimizer:** Loop que prueba configs de kernel (sysctl), scheduler, I/O, swap y mide impacto. Guarda los ganadores, revierte los perdedores. Benchmark automatico con `sysbench`, `fio`, `stress-ng`
- [x] **Prompt evolution:** El supervisor graba resultados de cada tarea. Periodicamente, un meta-agente analiza patrones de exito/fracaso y propone mejoras a los system prompts. A/B testing automatico de prompts
- [ ] **Model fine-tuning local:** Cuando hay GPU idle (noche/ausencia), fine-tune el modelo local con datos de interacciones exitosas del usuario. LoRA adapters guardados localmente
- [x] **Workflow learning:** Detectar patrones repetitivos del usuario (abre terminal → git pull → cargo build → cargo test) y generar skills automaticamente sin que el usuario pida
- [ ] **Resource prediction:** Predecir carga de trabajo por hora del dia/dia de semana. Pre-cargar modelos, pre-calentar caches, ajustar power profile proactivamente
- [x] **Nightly optimization daemon:** Proceso que corre entre 2-5 AM (configurable) cuando el usuario duerme. Ejecuta: cleanup, config tuning, model optimization, skill generation, security audit
- [ ] **Metrics dashboard:** Mostrar en el dashboard: "Axi optimizo X configs esta semana, ahorrando Y% de bateria y Z segundos de boot"
- [ ] **HITO FASE U:** LifeOS corre 1 semana sin intervencion. Al final: boot 15% mas rapido, 10% menos uso de RAM, 3 skills auto-generados, 2 prompts mejorados

### Fase V — Knowledge Graph Personal Local (Memoria Total)

**Objetivo:** Axi tiene un grafo de conocimiento que conecta TODO lo que sabe del usuario — archivos, conversaciones, calendario, contactos, habitos, preferencias. No solo busca texto similar (RAG) sino que entiende relaciones: "La reunion del lunes fue con Juan, sobre el proyecto X, donde decidimos Y, y Juan prometio Z para el viernes."

**Referencia:** [Mem0](https://mem0.ai/blog/graph-memory-solutions-ai-agents) — dual-store (vector + graph). 26% mas accuracy, 91% menos latencia, 90% menos tokens vs RAG naive.

**Por que es headline:** "Tu OS recuerda todo — y nunca sale de tu maquina"

- [x] **Entity extraction daemon:** Procesar todo texto que pasa por Axi (conversaciones, archivos abiertos, emails) y extraer entidades (personas, proyectos, fechas, decisiones, compromisos)
- [x] **Relation graph:** Grafo dirigido con nodos (entidades) y edges (relaciones). Stored en SQLite + sqlite-vec para hybrid search. Ejemplo: `Juan --[prometio]--> "entregar propuesta" --[para]--> "viernes 28"`
- [x] **Conflict detection:** Cuando nueva info contradice info existente, el LLM decide: actualizar, fusionar, invalidar, o mantener ambas con timestamp
- [x] **Temporal reasoning:** "Cuando fue la ultima vez que hable con Juan?" → consulta al grafo por edges con timestamp. "Que decidimos sobre X?" → busca nodos de decision relacionados con X
- [x] **Privacy layers:** El usuario controla que se graba. Niveles: todo, solo conversaciones con Axi, solo lo que el usuario marca explicitamente. Borrado selectivo por entidad/fecha
- [ ] **Cross-app context:** El grafo conecta info de Telegram + archivos + calendario + browser history (local). "Preparame para la reunion de mañana" → Axi busca emails, docs, y conversaciones previas sobre los temas de la agenda
- [x] **Knowledge decay:** Hechos viejos sin uso pierden relevancia gradualmente. Hechos confirmados repetidamente ganan peso. Como la memoria humana
- [x] **Export/import:** Exportar grafo completo (JSON-LD) para migrar a otro dispositivo LifeOS. El "ADN" del organismo incluye su memoria
- [ ] **HITO FASE V:** Preguntarle a Axi "que le prometi a Juan sobre el proyecto X?" y que responda correctamente citando la conversacion del martes, el email del miercoles, y el commit del jueves

### Fase W — Reliability Engine (Boring-Reliable > Impressive-Unreliable)

**Objetivo:** Que cada workflow de Axi funcione. Siempre. Sin importar complejidad. La reliability es mas importante que la capability. Si 85% accuracy por paso = 20% exito en 10 pasos, necesitamos 99% por paso.

**Referencia:** Princeton encontro que reliability mejora a la MITAD de la velocidad que accuracy. Fortune: "AI agents are getting more capable, but reliability is lagging."

**Por que es headline:** "Este OS tiene 99.9% de uptime en sus agentes"

- [x] **Atomic transactions:** Cada workflow es una transaccion. Si un paso falla, TODOS los cambios se revierten. Git worktree para codigo, snapshots para archivos, journal para configs
- [x] **Checkpoint + resume:** Guardar estado del agente cada N pasos. Si crashea, resume desde el ultimo checkpoint sin re-ejecutar todo
- [x] **Shadow mode:** Antes de ejecutar un workflow nuevo, correrlo en simulacion (dry-run) y mostrar al usuario que HARIA sin hacerlo realmente. "Axi planea: 1) crear branch, 2) editar 3 archivos, 3) correr tests. Proceder? [Si/No]"
- [x] **Confidence scoring:** Cada paso tiene un score de confianza (0-1). Si confianza < 0.7, escalar a humano. Si > 0.9, auto-ejecutar. El umbral es configurable
- [x] **Retry with variation:** Si un paso falla, no reintentar lo mismo. Generar un approach alternativo via LLM. "El build fallo por X, intentando approach B..."
- [x] **Cascade failure prevention:** Si paso 3 de 8 falla, no seguir ejecutando. Evaluar si los pasos restantes dependen del fallido. Si no, continuar los independientes
- [x] **Execution audit trail:** Log inmutable de cada accion, su resultado, y el razonamiento del LLM. Queryable via "Axi, por que hiciste X?" → muestra el chain of thought
- [x] **Reliability dashboard:** Tasa de exito por tipo de tarea, tiempo promedio de ejecucion, pasos que mas fallan, prompts que mas se auto-corrigieron
- [x] **SLA mode:** Para tareas criticas, el usuario define un SLA: "esta tarea debe completarse en <30 min con >95% accuracy". Si Axi no puede garantizarlo, notifica antes de empezar
- [ ] **HITO FASE W:** 100 tareas via Telegram en una semana. 95%+ completadas exitosamente sin intervencion humana. Las fallidas revierten limpiamente y reportan error claro

### Fase X — Intent-Based Interaction + OS-Level Translation

**Objetivo:** El usuario habla con LifeOS como habla con una persona. No "abre Firefox, navega a gmail.com, busca email de Juan". Sino "respondele a Juan que acepto la reunion". Y que funcione. Ademas, todo se traduce en tiempo real — llamadas, documentos, subtitulos.

**Referencia:** OpenAI diseña hardware sin pantalla con Jony Ive (Fall 2026). Microsoft dice que Windows 12 sera "agentic, ambient". Apple rumora voice-first navigation en iOS 26.

**Por que es headline:** "Le dices a tu laptop que hacer y lo hace. En cualquier idioma."

- [x] **Intent parser:** Modulo que convierte lenguaje natural en intent + entities + constraints. "Agenda reunion con Juan para el viernes a las 3" → `{intent: "schedule_meeting", with: "Juan", date: "viernes", time: "15:00"}`
- [x] **Intent router:** Dado un intent, determinar que skills/apps/acciones son necesarias. "Respondele a Juan" → buscar ultimo mensaje de Juan (Telegram/email) → componer respuesta → enviar
- [x] **Multi-step intent resolution:** "Preparame para la reunion de mañana" → 1) buscar agenda, 2) buscar docs relacionados, 3) resumir conversaciones previas, 4) generar briefing, 5) enviarlo a Telegram
- [ ] **OS-level translation daemon:** Servicio systemd que intercepta audio streams (PipeWire) y genera subtitulos traducidos en tiempo real. Funciona con Zoom, Meet, YouTube, podcasts, cualquier app
- [ ] **Document translation:** Click derecho en cualquier archivo → "Traducir a español". Usa modelos locales (NLLB-200, Madlad-400). Sin cloud
- [ ] **Live voice translation:** Durante llamadas, Axi traduce lo que dice la otra persona en tiempo real via TTS. Modo "interprete simultaneo"
- [x] **Context-aware responses:** Cuando el usuario pregunta algo, Axi usa el contexto actual (ventana activa, archivo abierto, ultima conversacion) para dar respuesta relevante sin que el usuario explique el contexto
- [ ] **HITO FASE X:** Decir "respondele a Juan que acepto, agenda la reunion para el viernes, y traduce el documento que me envio al español". Axi lo hace todo — busca el mensaje, responde, agenda, traduce. Sin abrir una sola app manualmente

### Fase Y — AI Security Daemon + Self-Healing Avanzado

**Objetivo:** LifeOS es el OS mas seguro del mundo. No porque bloquee todo, sino porque un daemon AI monitorea CADA proceso, CADA conexion, CADA cambio de archivo en tiempo real y reacciona antes de que el usuario se entere. El OS se repara solo — nunca muestra errores.

**Referencia:** SentinelOne lanzo AI security autonomo para air-gapped environments (marzo 2026). 60% de enterprises adoptan self-healing. Gartner: 30% reduccion en bugs de produccion con self-evolving software.

**Por que es headline:** "Este OS nunca ha mostrado un mensaje de error"

- [x] **Process anomaly detection:** Baseline de comportamiento normal por proceso (CPU, RAM, network, disk I/O). Si un proceso se desvia >3 sigma, alertar. Si se desvia >5 sigma, aislar automaticamente
- [x] **Network threat detection:** Analizar DNS queries, conexiones salientes, patrones de trafico. Detectar C2 callbacks, data exfiltration, lateral movement. Bloquear y notificar
- [x] **File integrity monitoring:** Hash de archivos criticos del sistema. Si cambian sin explicacion (update/user edit), alertar inmediatamente. Detectar rootkits, backdoors, tampering
- [x] **Self-healing services:** Si un servicio crashea, Axi lee los logs, diagnostica root cause, aplica fix, reinicia. El usuario nunca ve "Service failed to start"
- [x] **Disk self-healing:** Si un particion se llena, Axi auto-limpia (journals, cache, flatpak unused). Si un archivo se corrompe, restaurar desde snapshot. Si hay bad sectors, migrar datos proactivamente
- [x] **Network self-healing:** Si DNS falla, switch a fallback. Si VPN se desconecta, reconectar automaticamente. Si WiFi es inestable, diagnosticar y reportar solucion
- [x] **Predictive maintenance:** Analizar tendencias de SMART data, temperaturas, ciclos de bateria. Predecir fallos ANTES de que ocurran: "Tu SSD tiene 85% de vida usada. Al ritmo actual, necesitaras reemplazo en ~6 meses"
- [x] **Zero-day protection:** Si se detecta un comportamiento nuevo nunca visto (nuevo proceso, nueva conexion, nuevo patron), aislarlo por defecto y preguntar al usuario. Principio de minimo privilegio AI-enforced
- [ ] **HITO FASE Y:** Simular un ataque: proceso malicioso que intenta exfiltrar datos. El AI security daemon lo detecta en <10 segundos, lo aisla, bloquea la conexion, notifica al usuario via Telegram con evidencia forense completa

### Fase Z — Ecosystem + Distribution + World Domination

**Objetivo:** LifeOS pasa de ser un proyecto personal a una plataforma global. Hardware partnerships, app ecosystem, developer community, enterprise customers.

**Referencia:** Linux desktop cruzo 4.7% global. Windows 10 EOL es el mayor push factor. Framework, System76, Tuxedo ya venden laptops Linux. El TAM de sovereign AI personal es enorme e inexplorado.

**Por que es headline:** "El primer OS que es tuyo de verdad — tu hardware, tu AI, tus datos"

**Z.1 — AI-Native App Ecosystem**
- [x] **App contract standard:** Formato JSON para declarar capabilities de una app (intents que maneja, datos que necesita, acciones que puede hacer). El OS orquesta apps via intents, no via GUI
- [ ] **Skill marketplace:** Repositorio publico de skills creados por la comunidad. Como npm/crates.io pero para skills de Axi. Rating, reviews, verificacion de seguridad
- [x] **Autonomy slider per-app:** Cada app/skill tiene un nivel de autonomia configurable. "Axi puede usar esta app libremente" vs "solo con mi aprobacion"
- [ ] **Revenue sharing:** Creadores de skills ganan cuando sus skills son usados. Modelo freemium: skills basicos gratis, premium de pago

**Z.2 — Developer Platform**
- [ ] **LifeOS SDK:** Rust + Python SDK para crear skills, agentes, y apps AI-native. Event-driven, con hooks para el ciclo de vida del OS
- [ ] **Agent evaluation framework:** Herramientas para testear agentes antes de publicar: accuracy benchmarks, safety checks, resource limits
- [x] **Connector registry:** Catalogo de conectores a servicios externos (GitHub, Slack, Google Calendar, etc.) que skills pueden usar
- [ ] **Developer documentation:** Portal con guias, tutorials, API reference, ejemplos. "De cero a tu primer skill en 10 minutos"
- [ ] **Local development environment:** `life dev init` crea un sandbox para desarrollar y testear skills sin afectar el sistema

**Z.3 — Hardware Partnerships**
- [ ] **Framework laptop partnership:** LifeOS pre-instalado como opcion en Framework laptops. Hardware abierto + OS abierto = combinacion perfecta
- [ ] **System76/Tuxedo OEM:** Negociar pre-instalacion en laptops Linux de gama alta
- [ ] **NPU optimization:** Ser el primer Linux con auto-deteccion de NPU (Intel, AMD, Qualcomm) y aceleracion transparente. Los fabricantes quieren mostrar que su NPU sirve para algo
- [ ] **"LifeOS Ready" certification:** Programa de certificacion para hardware que cumple requisitos minimos (NPU opcional, 16GB RAM, NVMe)

**Z.4 — Enterprise**
- [ ] **SOC 2 Type I:** Preparar documentacion y controles para auditoria SOC 2 (6 meses)
- [ ] **Fleet management:** Dashboard web para IT admins: desplegar imagenes LifeOS, configurar politicas, monitorear flota de dispositivos via bootc
- [ ] **AI governance dashboard:** Para compliance officers: que hace el AI, que datos accede, audit trail completo, explicabilidad de decisiones
- [x] **Air-gapped mode:** LifeOS funciona 100% sin internet. Todo local. Para gobierno, militar, salud, finanzas

**Z.5 — Distribution**
- [ ] **Zero-config ISO:** Descargar, flashear, bootear. En 5 minutos estas hablando con Axi. Sin terminal, sin configuracion, sin conocimiento previo de Linux
- [ ] **Migration wizard:** Tool que importa datos de Windows/macOS: documentos, bookmarks, passwords (KeePass), calendario, contactos
- [ ] **"Try without installing":** Live USB que corre LifeOS completo desde USB sin tocar el disco. Prueba antes de comprometerte
- [ ] **OTA updates channel:** Stable (mensual, probado), Edge (semanal, bleeding edge), LTS (cada 6 meses, solo security fixes)

**Z.6 — AI Creativity Tools Nativos**
- [ ] **Image generation/editing:** Click derecho en cualquier imagen → extender, editar, generar variaciones. Modelos locales (SDXL, Flux) en GPU
- [ ] **Text-to-speech artistica:** No solo TTS funcional, sino voces con emocion, ritmo, entonacion natural. Para podcasts, narraciones, presentaciones
- [ ] **Code generation IDE:** Un mini-IDE integrado donde Axi escribe codigo, lo testea, y lo itera. Sin salir del OS
- [ ] **Document generation:** "Crea una presentacion sobre X" → genera slides con contenido, imagenes, y formato profesional

**Z.7 — Accessibility Universal**
- [ ] **AI screen reader:** No solo lee texto — DESCRIBE interfaces visualmente. "Hay un formulario con 3 campos: nombre, email, y un boton azul que dice Enviar"
- [ ] **Voice control total:** Controlar TODO el OS por voz. No solo comandos predefinidos, sino lenguaje natural. "Mueve esta ventana a la derecha", "Haz mas grande el texto"
- [ ] **Adaptive interface:** El OS detecta limitaciones motoras/visuales/cognitivas y adapta la interface: botones mas grandes, contraste alto, simplificacion automatica
- [ ] **Cognitive assistance:** Para personas con ADHD, dyslexia, o dificultades de aprendizaje: resaltado de texto, lectura guiada, resumen automatico de documentos largos

---

### Resumen de Todas las Fases (A-Z)

| Fase | Nombre | Estado | Impacto |
|------|--------|--------|---------|
| A-G | Base funcional | COMPLETADA 100% | Fundacion |
| H-T | Fases de desarrollo core | IMPLEMENTADA 70% | Sistema funcional |
| **U** | Self-Improving OS (Karpathy Loop) | IMPLEMENTADA 60% | **HEADLINE** — "se optimiza solo" |
| **V** | Knowledge Graph Personal | IMPLEMENTADA 65% | **HEADLINE** — "recuerda todo, local" |
| **W** | Reliability Engine | IMPLEMENTADA 70% | **CRITICO** — sin esto nada funciona a escala |
| **X** | Intent-Based Interaction + Translation | IMPLEMENTADA 40% | **HEADLINE** — "le dices que hacer y lo hace" |
| **Y** | AI Security + Self-Healing Avanzado | IMPLEMENTADA 50% | **HEADLINE** — "nunca muestra errores" |
| **Z** | Ecosystem + Distribution + World | IMPLEMENTADA 20% | **ESCALA** — de proyecto a plataforma global |

**Camino critico para "iPhone Moment":**
W (reliability) → U (self-improving) → V (knowledge graph) → X (intent-based) → Y (security) → Z (ecosystem)

**La reliability (W) va primero porque sin ella, todo lo demas es humo.**

### Post Fases — Lanzamiento Publico

- [ ] Grabar video demo de 2 minutos mostrando el flujo completo (Telegram -> LifeOS desarrolla -> reporta con evidencia)
- [ ] Grabar video demo de "agente agentico": usuario se va, Axi trabaja, usuario regresa y ve resultados
- [ ] Actualizar README.md para publico con screenshots del dashboard y demo
- [ ] Hacer repo publico bajo org lifeos-ai
- [ ] Post en X/Twitter con video
- [ ] Post en r/linux, r/LocalLLaMA, r/selfhosted, Hacker News
- [ ] Post en comunidades hispanohablantes
- [ ] Preparar ISO descargable para early adopters
