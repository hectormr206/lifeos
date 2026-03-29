# LifeOS Vision y Decisiones Estrategicas

> Este archivo es parte de la Estrategia Unificada de LifeOS. Ver [docs/strategy/](../strategy/) para el indice completo.

Fecha: 2026-03-23 (ultima revision: 2026-03-29)

---

## Regla Permanente: Atribucion del Creador

**LifeOS fue creado por Hector Martinez Resediz (hectormr.com).**

Esta atribucion DEBE aparecer en TODOS estos lugares y NUNCA debe ser removida:

| Lugar | Archivo | Que dice |
|-------|---------|----------|
| **os-release** (Acerca de) | `image/Containerfile:759` | `PRETTY_NAME="LifeOS 0.3 Axolotl - by Hector Martinez (hectormr.com)"` |
| **os-release** (vendor) | `image/Containerfile:762` | `VENDOR_NAME="Hector Martinez Resediz"` + `VENDOR_URL="https://hectormr.com"` |
| **System prompt de Axi** | `daemon/src/telegram_tools.rs` | `Fui creado por Hector Martinez Resediz (hectormr.com)` |
| **GRUB boot** | `image/files/usr/share/lifeos/grub-theme/theme.txt:60` | `text = "hectormr.com"` |
| **README.md** | `README.md` | `Hector Martinez (hectormr.com)` |
| **OCI labels** | `image/Containerfile:206` | `org.opencontainers.image.source` |
| **URLs del OS** | `image/Containerfile:763-766` | `HOME_URL`, `DOCS_URL`, `SUPPORT_URL`, `BUG_REPORT_URL` |

**Si algun agente de IA (Claude, Gemini, o cualquier otro) modifica estos archivos, DEBE preservar la atribucion del creador. Si la remueve accidentalmente, restaurarla inmediatamente.**

---

## Regla Permanente: Proteccion Legal y Propiedad Intelectual

**LifeOS NUNCA debe meterse en problemas legales. Estas reglas aplican a todo el desarrollo:**

### Codigo y Propiedad Intelectual
- **100% codigo propio** — todo el codigo de LifeOS es escrito desde cero en Rust. NUNCA se copia codigo de otros proyectos
- **Analisis competitivo es legal** — analizar productos publicos (OpenClaw, Devin, etc.) para entender features es ingenieria inversa legitima y practica estandar de la industria
- **Features genericas no son patentables** — funcionalidades como "typing indicator", "bot commands", "inline keyboards" son APIs publicas de Telegram/plataformas, no inventos de ningun competidor
- **Si usamos una libreria open source**, verificar que su licencia (MIT, Apache 2.0, etc.) es compatible con uso comercial

### Datos y Privacidad
- **Privacidad por defecto** — todo se procesa localmente. Datos sensibles NUNCA salen de la maquina del usuario sin consentimiento explicito
- **Zero Data Retention** — para providers remotos, preferir los que garantizan ZDR (Cerebras, Groq)
- **GDPR/CCPA ready** — el usuario puede exportar y borrar TODOS sus datos en cualquier momento
- **No recopilar datos de usuarios** — LifeOS no tiene telemetria que envie datos a nuestros servidores (a menos que el usuario lo active explicitamente)

### Branding y Marcas
- **Nunca usar logos o marcas ajenas** — si mencionamos OpenClaw, Devin, etc. en docs es solo como referencia competitiva
- **Registrar marca "LifeOS" y "Axi"** cuando sea financieramente viable
- **El nombre "LifeOS" debe verificarse** que no este registrado por otra entidad antes de lanzamiento publico

### Licencias de Dependencias
- **Verificar licencias de crates** — antes de agregar un nuevo crate a Cargo.toml, verificar que su licencia permite uso comercial
- **Crates permitidos:** MIT, Apache 2.0, BSD, ISC, Zlib, MPL 2.0 (con cuidado)
- **Crates NO permitidos:** GPL (a menos que sea solo link dinamico), AGPL, SSPL, propietarios
- **`cargo deny` o `cargo audit`** verifican licencias en CI

### Para Agentes de IA
- **Cuando implementes una feature inspirada en otro producto**, documenta: "Inspirado en [producto], implementacion propia, no se copio codigo"
- **NUNCA copies codigo fuente de otro repo** ni siquiera para "adaptarlo". Escribe desde cero basandote en la API publica
- **Si tienes duda sobre si algo es legal**, pregunta al usuario antes de implementar

---
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
- **AI local:** llama-server (Vulkan GPU) + Qwen3.5-4B default (16K ctx, reasoning off) + catalogo de 4 modelos (0.8B/2B/4B/9B)
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

Ver [competencia.md](competencia.md) para el analisis competitivo detallado.

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

### 8.4 Modelo local: Qwen3.5-4B Q4_K_M (default desde 2026-03-28)

**Historial:** 0.8B (lanzamiento) → 2B (fase A) → **4B (actual)**. El 2B resultaba demasiado limitado: entraba en loops de reasoning degenerado, no podia mantener una conversacion coherente, y el system prompt de Axi (~4K tokens) consumia casi todo el contexto de 6K.

| Aspecto | 0.8B | 2B | **4B (actual)** | 9B |
|---------|------|----|-----------------|----|
| GGUF Q4_K_M | 0.5 GB | 1.3 GB | **2.7 GB** | ~5.5 GB |
| mmproj | 205 MB | 671 MB | **672 MB** | ~1 GB |
| VRAM total (16K ctx) | ~1 GB | ~2.5 GB | **~3.5 GB** | ~6.5 GB |
| VRAM libre gaming | ~11 GB | ~9.5 GB | **~8.5 GB** | ~5.5 GB |
| Vision/multimodal | SI | SI | **SI** | SI |
| Conversacion coherente | No | Apenas | **SI** | SI |
| Razonamiento basico | No | Loop degenerado | **Funcional** | Bueno |
| Corre en CPU sin GPU | SI (lento) | SI (12-50 tok/s) | **SI (8-30 tok/s)** | Lento |

**Por que 4B es el sweet spot:**
- **Conversacion real:** El 2B no podia responder un "Hola" sin entrar en loop de reasoning. El 4B mantiene dialogo coherente
- **VRAM vs Gaming:** Con ~3.5 GB de VRAM, deja ~8.5 GB libres — suficiente para la mayoria de juegos. El 9B usaria ~6.5 GB y dejaria solo ~5.5 GB, causando stuttering en juegos pesados (RE Requiem usa 11.8 GB)
- **Modelo local = daily driver, cloud = cerebro:** Para tareas complejas (razonamiento profundo, codigo largo), el LLM router escala automaticamente a Cerebras/Groq/Claude. El modelo local solo necesita ser competente para conversacion, clasificacion y vision
- **Contexto 16K:** El system prompt de Axi usa ~4K tokens. Con 16K de contexto hay espacio para historial de conversacion + herramientas + respuesta
- **Reasoning deshabilitado:** Qwen3.5 tiene modo reasoning que en modelos pequenos causa loops degenerados. Se desactiva con `--reasoning-budget 0` en llama-server
- Descartados: 0.8B (inutil para conversacion), 2B (loop de reasoning, contexto insuficiente), 9B (VRAM excesiva, game guard tendria que offloadear siempre)

**Configuracion de llama-server (produccion):**
```
LIFEOS_AI_MODEL=Qwen3.5-4B-Q4_K_M.gguf
LIFEOS_AI_MMPROJ=Qwen3.5-4B-mmproj-F16.gguf
LIFEOS_AI_CTX_SIZE=16384
LIFEOS_AI_THREADS=4
LIFEOS_AI_GPU_LAYERS=99
```

**Flags adicionales del service (via drop-in 96-fast-sensory.conf):**
```
--parallel 1 --batch-size 512 --ubatch-size 128 --n-predict 2048 --reasoning-budget 0 --jinja
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

## Integration Architecture Rule (permanente)

**Regla #1: No hay features huerfanas.**

Cada modulo nuevo DEBE estar conectado a al menos UNA ruta de runtime antes de hacer commit:

| Ruta | Ejemplo | Archivo |
|------|---------|---------|
| Telegram tool | "translate", "game_help" | telegram_tools.rs |
| API endpoint | GET /api/v1/battery/status | api/mod.rs |
| Background loop | health checks cada 60s | main.rs |
| Supervisor action | BrowserNavigate, ShellCommand | supervisor.rs |
| Event bus | MeetingRecordingStarted | events.rs |

**Antes de programar, responder:**
1. ¿Quien llama a este modulo?
2. ¿Como llega al usuario? (Telegram, dashboard, notificacion, automatico)
3. ¿Necesita memoria? (MemoryPlane para datos, KnowledgeGraph para relaciones)
4. ¿Necesita el event bus? (para comunicarse con otros modulos)

**Si un modulo no tiene respuesta clara a la pregunta 1, NO se implementa.**

Estado actual: 17 de 40 modulos estan conectados al runtime. Los 23 restantes son deuda tecnica de integracion.

---

## Sudo Policy: Least Privilege (permanente)

El usuario `lifeos` (UID 1000) ejecuta `lifeosd`. Los permisos root estan en `/etc/sudoers.d/lifeos-axi` con NOPASSWD solo para comandos especificos.

| Categoria | Comandos | Fuente |
|-----------|----------|--------|
| Service mgmt | systemctl start/stop/restart llama-server, whisper-stt | game_guard.rs, agent_runtime.rs, api/mod.rs |
| OS updates | bootc status/upgrade/rollback | updates.rs, health.rs |
| Flatpak | flatpak install/uninstall/update --system | telegram_tools.rs, proactive.rs |
| Hardware diag | smartctl -j -a (read-only) | security_daemon.rs, proactive.rs |
| Network security | nft list/add rule, iptables block | proactive.rs, security_ai.rs |
| System tuning | sysctl -w | system_tuner.rs |
| Battery | tee charge_control_end_threshold | battery_manager.rs |
| Process isolation | kill -STOP | security_ai.rs |
| RPM verify | rpm -V | security_ai.rs |

**Regla para agregar nuevas:** comando exacto, scope minimo, comentario con archivo fuente. **NUNCA** `ALL=(ALL) NOPASSWD: ALL`.

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

- [x] Seguir construyendo LifeOS — APROBADO (fases A-AA completadas)
- [x] Adoptar el wedge: "empleado digital local-first con control remoto"
- [x] Cerrar primero 1 laptop autonoma y confiable
- [x] Convertir los LLMs en pipeline, no copilotos manuales — LLM router con 13+ providers
- [x] Priorizar: LLM router -> Telegram -> Supervisor loop -> Memory -> Recovery — todo implementado
- [x] Usar OpenClaw como benchmark, no como modelo a copiar

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
