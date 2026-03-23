# LifeOS Estrategia Unificada Final

Fecha: 2026-03-23
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
| No vas lento construyendo | Si | Si (81 commits/13 dias, 54K LOC) | Si |
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

| Metrica | Valor |
|---------|-------|
| Primer commit | 10 de marzo de 2026 |
| Dias activos de desarrollo | 11 |
| Total commits | 81 |
| Lineas de Rust | 53,769 |
| Subcomandos CLI implementados | 26 de 39 |
| Subcomandos CLI stub | 13 de 39 |
| Endpoints REST del daemon | 50+ |
| Modulos del daemon | 32 archivos, ~22,500 LOC, ~95% implementado |
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

### Lo que falta (los 6 cierres decisivos)

1. **Supervisor autonomo:** agent_runtime.rs tiene 3,239 lineas de estructura pero la ejecucion real se queda en "baseline runtime"
2. **Loop asincrono con retries:** no hay task queue, no hay retry, no hay recuperacion ante fallo
3. **Canal remoto:** cero — no hay Telegram, email, webhook, ni push notification
4. **Self-healing:** si un componente falla, requiere intervencion manual
5. **Jerarquia de agentes real:** `life agents` es placeholder, no hay spawn ni coordinacion
6. **Valor diario inmediato:** el loop de uso no esta cerrado — requiere estar frente a la laptop con CLI

---

## 5. Competencia Real al 23 de Marzo de 2026

### Competencia directa: nadie ha ganado la categoria

| Competidor | Estado | Amenaza | Ventaja de LifeOS |
|------------|--------|---------|-------------------|
| **OpenClaw** | 100K+ GitHub stars, viral. Steinberger en OpenAI. 50+ integraciones. NVIDIA dice "toda empresa necesita OpenClaw strategy" | **ALTA** — es lo mas cercano a tu vision | Tu ERES el OS. OpenClaw es app dentro de OS. Ademas 135K instancias expuestas (crisis seguridad) |
| **AthenaOS** (kyegomez) | Concepto de OS con millones de agentes swarm. Rust + C++. 1700+ contribuidores de Agora | Baja hoy, potencial en 12-18 meses | Tu tienes producto funcional corriendo en hardware real |
| **MAGI OS** | Distro experimental AI + Debian/MATE. Descargable como ISO | Baja. Proyecto de investigacion | Mucho mas limitado que LifeOS en todo |
| **RHEL AI** | Red Hat enterprise con InstructLab. Produccion | Baja para personal, alta para enterprise | Enfocado en servidor, no desktop personal |
| **deepin 25 AI** | Dos agentes AI nuevos (writing/data), OCR mejorado | Media en Asia | LifeOS tiene multimodalidad completa, no solo writing/OCR |

### Competencia indirecta: herramientas que compiten por tu tiempo

| Competidor | Estado | Diferencia clave |
|------------|--------|-----------------|
| **Agent Zero** | Open source, 12K+ stars, Docker, se auto-corrige, multi-LLM | Es framework, no OS. LifeOS puede integrarlo |
| **Claude Computer Use** | Produccion via API. Ve pantalla, mueve mouse, ejecuta | Es API, no OS. LifeOS ya tiene computer_use + puede usar Claude API como cerebro |
| **Devin AI** | $20/mes, completa 83% mas tareas que v1, auto-debugging | Solo para desarrollo de software, no asistente de vida |
| **Screenpipe** | Open source MIT, $400 lifetime, graba pantalla/audio 24/7 | Es app no OS. Tu sensory_pipeline hace lo mismo a nivel kernel |
| **CrewAI / LangGraph / AutoGen** | Los 3 dominantes en multi-agente. Produccion | Son librerias Python. LifeOS puede usarlas como motor interno |

### Lo que los gigantes estan haciendo

| Gigante | Estado Marzo 2026 | Implicacion para LifeOS |
|---------|-------------------|------------------------|
| **Microsoft Copilot+** | **RETROCEDIENDO.** Admiten que Windows 11 se paso con Copilot. Cancelaron integraciones en Photos, Widgets, Notepad. Recall con problemas de seguridad | Ventana abierta. El mercado rechaza AI invasiva mal hecha |
| **Apple Intelligence** | Conservadora. Privacidad primero, no autonomia. Varias features de Siri con contexto "in development" | No competira con autonomia real por años |
| **Samsung/Google Gemini** | Agresivo en movil. Gemini controla apps en Galaxy S26. 800M dispositivos | Solo movil. Desktop Linux es diferente |
| **Limitless (ex-Rewind)** | **MUERTO.** Meta lo compro, servidores apagandose, Pendant descontinuado | Oportunidad: el espacio de "memoria personal AI" quedo huerfano |
| **Humane AI Pin** | **MUERTO.** Bricked desde Feb 2025. HP compro restos | Hardware AI dedicado fracaso |
| **Rabbit R1** | Apenas sobrevive. Planean R2 para 2026 | Hardware AI dedicado no funciona solo |

### Veredicto competitivo

**La categoria "AI-first OS funcional, abierto, con agente autonomo" NO TIENE GANADOR.**

- OpenClaw es la amenaza mas seria pero NO es un OS
- Los gigantes estan retrocediendo (Microsoft) o siendo conservadores (Apple)
- Los dispositivos AI dedicados fracasaron (Humane, Rabbit)
- Los frameworks de agentes (CrewAI, LangGraph) son librerias, no productos de usuario final
- La ventana esta abierta pero se cierra. OpenClaw crece exponencialmente

**Tu ventaja unica que nadie puede replicar facil:**
1. ERES el OS (acceso a kernel, systemd, bootc, hardware)
2. Inmutabilidad + rollback (si la AI rompe algo, bootc te salva)
3. Full sensory stack a nivel de sistema (no una app sandboxeada)
4. Open source + privacidad real (todo local por default)

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

### 8.2 Stack real de LLMs para el router (costo adicional: $5-15/mes)

**Tier gratis (sin gastar nada):**

| Provider | Modelo | Limite | Uso |
|----------|--------|--------|-----|
| Gemini API | 2.5 Flash-Lite | 1,000 req/dia | Tareas medias |
| Gemini API | 2.5 Pro | 100 req/dia | Razonamiento complejo |
| Zhipu/GLM | GLM-4.7-Flash | Sin limite | Tareas generales no sensibles |
| OpenRouter | Qwen3 Coder 480B | 200 req/dia | Coding gratis |
| OpenRouter | DeepSeek R1 | 200 req/dia | Reasoning gratis |
| Modelo local | Qwen3.5-2B | Sin limite | Guardian de privacidad + fallback |

**Tier barato (fallback cuando gratis se agota):**

| Provider | Modelo | Costo/M tokens | Uso |
|----------|--------|----------------|-----|
| DeepSeek | V3.2 | $0.28 input / $0.42 output | General, excelente calidad/precio |
| MiniMax | M2.5 | $0.30 / $1.20 | Coding (80% SWE-Bench) |
| Kimi | K2.5 | $0.60 / $2.50 | Vision multimodal, 256K contexto |

**Capacidad gratuita total: ~2,150+ requests/dia + modelo local ilimitado. Suficiente para un agente 24/7.**

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

### Pre-requisitos (Hoy — Dia 0)

- [ ] Descargar Qwen3.5-2B-Q4_K_M.gguf y colocarlo en /var/lib/lifeos/models/
- [ ] Actualizar LIFEOS_AI_MODEL en llama-server.env a Qwen3.5-2B
- [ ] Verificar que llama-server arranca con el nuevo modelo
- [ ] Registrar API key gratis en Google AI Studio (Gemini)
- [ ] Registrar cuenta gratis en OpenRouter
- [ ] Registrar cuenta gratis en Zhipu/GLM (ya tienes cuenta)
- [ ] Limpiar documentacion segun seccion 17
- [ ] Reservar nombre en GitHub org (lifeos-ai) y X/Twitter

### Fase A — Semana 1: LLM Router + Telegram Bot

- [ ] Crear `daemon/src/llm_router.rs` con trait Provider
- [ ] Implementar provider: Local (llama-server :8082, OpenAI-compatible)
- [ ] Implementar provider: Gemini Free (generativelanguage.googleapis.com)
- [ ] Implementar provider: GLM Free (open.bigmodel.cn, OpenAI-compatible)
- [ ] Implementar provider: OpenRouter Free (openrouter.ai/api)
- [ ] Implementar logica de seleccion por complejidad de tarea
- [ ] Implementar fallback automatico si provider falla o rate-limited
- [ ] Implementar `daemon/src/privacy_filter.rs` — clasificar sensibilidad, redactar datos
- [ ] Agregar endpoint API: POST /api/v1/llm/chat (usa router en vez de llama-server directo)
- [ ] Agregar crate `teloxide` a daemon/Cargo.toml
- [ ] Crear `daemon/src/telegram_bridge.rs` — bot bidireccional
- [ ] Telegram: recibir mensajes de texto y pasarlos al LLM router
- [ ] Telegram: devolver respuesta del LLM
- [ ] Telegram: autenticacion (solo tu chat_id puede interactuar)
- [ ] Test: enviar mensaje desde Telegram, recibir respuesta de LifeOS

### Fase A — Semana 2: Task Queue + Supervisor basico

- [ ] Crear `daemon/src/task_queue.rs` — SQLite persistente
- [ ] Esquema: id, objetivo, estado (pending/running/completed/failed/retrying), timestamps, resultado
- [ ] Los trabajos sobreviven reinicios del daemon
- [ ] Crear `daemon/src/supervisor.rs` — loop basico
- [ ] Supervisor recibe objetivo -> llama LLM para generar plan (JSON steps)
- [ ] Supervisor ejecuta cada paso del plan secuencialmente
- [ ] Herramientas disponibles para el supervisor: terminal (shell command), screen_capture, computer_use, AI query
- [ ] Si un paso falla: registrar error, intentar de nuevo con contexto del error
- [ ] Si falla 3 veces: marcar tarea como failed, notificar via Telegram
- [ ] Telegram: enviar tarea como mensaje -> se crea en task_queue -> supervisor la toma

### Fase A — Semana 3: Integracion completa + Memory writeback

- [ ] Conectar Telegram -> task_queue -> supervisor -> LLM router (flujo end-to-end)
- [ ] Supervisor puede enviar screenshots via Telegram (captura -> comprime -> envia)
- [ ] Activar embeddings reales en memory_plane.rs (usar modelo local para generar vectores)
- [ ] Despues de cada tarea completada: guardar en memoria que se hizo, que funciono, que fallo
- [ ] Antes de planificar tarea nueva: consultar memoria por tareas similares anteriores
- [ ] Agregar provider pagado: DeepSeek V3.2 (OpenAI-compatible, $0.28/M)
- [ ] Test: flujo completo Telegram -> tarea -> ejecucion -> resultado -> Telegram

### Fase A — Semana 4: Heartbeat + Hardening + Hito

- [ ] Heartbeat diario automatico via Telegram: resumen de que hizo, que fallo, que sigue
- [ ] Heartbeat incluye: tareas completadas, tareas fallidas, estado del sistema, VRAM/RAM/disco
- [ ] Logging de todas las llamadas a APIs externas en /var/log/lifeos/llm-audit.log
- [ ] Retry robusto: exponential backoff, max 3 intentos, fallback a otro provider
- [ ] Tests unitarios para: llm_router, task_queue, privacy_filter
- [ ] **HITO FASE A:** Desde Telegram: "revisa el estado del repo y dime que sigue" -> LifeOS responde con analisis real

### Fase B — Semanas 5-6: Sandbox + Loop Visual

- [ ] Sandbox de desarrollo: git worktree para cambios al propio codigo
- [ ] Supervisor puede: crear branch, hacer cambios, correr tests, reportar resultado
- [ ] Si tests fallan: revertir cambios automaticamente
- [ ] Si tests pasan: notificar via Telegram para aprobacion
- [ ] Loop visual: screenshot -> LLM analiza -> decide accion -> computer_use ejecuta -> verifica con nuevo screenshot
- [ ] Provider pagado adicional: Kimi K2.5 para vision multimodal compleja

### Fase B — Semanas 7-8: Self-Healing + Approvals + Learning

- [ ] Browser automation real: elevar browser.rs de stub a operador funcional
- [ ] Self-healing: si worker muere -> reinicio automatico via systemd
- [ ] Self-healing: si LLM falla -> fallback a otro provider automatico
- [ ] Self-healing: si task falla 3 veces -> escalar a humano via Telegram
- [ ] Clasificacion de riesgo: bajo (ejecutar), medio (ejecutar + notificar), alto (pedir aprobacion)
- [ ] Learning loop: guardar patron exito/fallo por tipo de tarea
- [ ] Planner consulta memoria antes de planificar
- [ ] **HITO FASE B:** "entra al dashboard, verifica que todo esta verde, si hay error corrigelo" -> LifeOS completa sin rescate

### Fase C — Semanas 9-12: Gerente General Digital

- [ ] Sub-agente spawning: supervisor puede crear workers especializados
- [ ] Roles: Executive/GM, Planner, Coder, Reviewer, Tester, DevOps
- [ ] Cada rol tiene prompt especifico y herramientas permitidas
- [ ] GM asigna subtareas, workers reportan estado, GM detecta bloqueos
- [ ] Resource management: agentes comparten GPU/CPU sin saturar
- [ ] Dashboard de operaciones: que hace cada agente, que fallo, que sigue
- [ ] Metricas por agente y tipo de tarea
- [ ] Runbooks automaticos de fallo
- [ ] **HITO FASE C:** "mejora el manejo de errores del sensory_pipeline, prueba, audita y presentame el resultado" -> equipo de agentes lo completa

### Post Fase C — Lanzamiento Publico

- [ ] Grabar video demo de 2 minutos (Telegram -> LifeOS trabaja -> reporta)
- [ ] Actualizar README.md para publico
- [ ] Hacer repo publico bajo org lifeos-ai
- [ ] Post en X/Twitter con video
- [ ] Post en r/linux, r/LocalLLaMA, r/selfhosted, Hacker News
- [ ] Post en comunidades hispanohablantes
