# Fase AQ — CLI Subscription Bridge: Modelos Frontier via MCP sin API Keys (ESTRATEGICA)

**Objetivo:** Que Axi acceda a modelos frontier (Gemini 2.5 Pro, GPT-5, etc.) a traves de CLIs de suscripcion ($20/mes) envueltos como MCP servers, eliminando la necesidad de API keys costosas. El usuario paga una suscripcion fija y obtiene 1,000-2,000 requests/dia de modelos frontier que Axi puede usar como backends inteligentes.

**Por que es estrategico:** Un API key de Gemini 2.5 Pro o GPT-5 cuesta $0.01-0.06 por request. Con uso intensivo (200+ requests/dia), eso son $60-360/mes solo en API. Pero las suscripciones de consumidor (Google AI Pro $20/mes, ChatGPT Plus $20/mes) incluyen 1,000-1,500 requests/dia a modelos frontier. La diferencia economica es brutal: el modelo de suscripcion es 10-50x mas barato para uso personal. LifeOS puede ser el puente que conecta estas suscripciones con un agente local inteligente.

**Investigacion base:** Analisis de 4 CLIs (Gemini CLI, Codex CLI, Claude Code, OpenCode), 3 proyectos MCP existentes (Artegy/gemini-cli-mcp, dnnyngyen/gemini-cli-orchestrator, nosolosoft/opencode-mcp), documentacion oficial, y estado legal de cada opcion.

---

## Diagrama de Arquitectura

```
                    LifeOS (host)
                         |
          +--------------+--------------+
          |                             |
     lifeosd (Axi)              llama-server
     MCP Client (Fase Q)        (modelo local)
          |
          |  JSON-RPC 2.0 / stdio
          |
    +-----+-----+-----+-----+
    |           |           |
lifeos-gemini  lifeos-     lifeos-
-bridge        opencode    codex
(MCP server)   -bridge     -bridge*
    |          (MCP srv)   (limitado)
    |           |           |
  gemini        opencode    codex
  CLI           CLI         CLI
  (subprocess)  (subprocess)(subprocess)
    |           |           |
  Google API   Any LLM     OpenAI API
  (OAuth)      Provider    (OAuth)
               (API key)

* Codex bridge tiene limites severos, baja prioridad

[BLOQUEADO - NO IMPLEMENTAR]
  claude CLI → Anthropic prohibe wrappers third-party
```

### Flujo de una request tipica

```
1. Usuario (Telegram): "Analiza mi codebase y sugiere refactorings"
2. Axi (coordinator, Fase AP): clasifica como "task" → spawn worker
3. Worker evalua: tarea requiere contexto masivo (>100K tokens)
4. Router (llm_router.rs) selecciona: Gemini (2M ctx window)
5. Axi → MCP call → lifeos-gemini-bridge
6. Bridge ejecuta: gemini -p "..." --output-format json --approval-mode yolo
7. Gemini CLI → Google API (autenticado via OAuth del usuario)
8. Response JSON → Bridge parsea → MCP response → Axi
9. Axi consolida → envia resultado a Telegram
```

---

## Analisis Legal por CLI

### Gemini CLI — LEGAL (Apache 2.0)

| Aspecto | Estado |
|---------|--------|
| **Licencia** | Apache 2.0 — permite uso, modificacion, distribucion, uso comercial |
| **Automatizacion** | Headless mode es feature OFICIAL: `-p`, `--output-format json`, `--approval-mode yolo` |
| **MCP wrapping** | Google lo promueve activamente (Extensions SDK, MCP server docs oficiales) |
| **ToS** | Uso personal con Google account — no hay restriccion de automatizacion en ToS |
| **Precedentes** | 3+ proyectos MCP wrapper en produccion (Artegy, dnnyngyen, centminmod) |
| **Veredicto** | **100% LEGAL y RECOMENDADO** |

### OpenCode CLI — LEGAL (MIT)

| Aspecto | Estado |
|---------|--------|
| **Licencia** | MIT — la mas permisiva posible |
| **Automatizacion** | Server mode OFICIAL: `opencode serve` expone REST API + OpenAPI 3.1 spec |
| **MCP wrapping** | MCP server community ya existe (nosolosoft/opencode-mcp, ajhcs/Better-OpenCodeMCP) |
| **Ventaja** | Soporta 75+ LLM providers (Anthropic, OpenAI, Groq, Ollama, etc.) — meta-CLI |
| **Veredicto** | **100% LEGAL — alternativa complementaria a Gemini** |

### Claude Code CLI — ILEGAL (ToS prohibe wrappers)

| Aspecto | Estado |
|---------|--------|
| **Licencia** | Codigo: Apache 2.0, PERO sujeto a ToS de Anthropic |
| **Seccion 3.7 ToS** | Prohibe "any automated access tool not officially endorsed" |
| **Enforcement activo** | Enero 2026: Anthropic bloqueo tokens OAuth de OpenClaw, Roo Code, Goose, OpenCode |
| **Metodo de bloqueo** | Server-side token validation — detecta y bloquea clientes third-party |
| **Riesgo** | Suspension de cuenta sin aviso previo |
| **Veredicto** | **NO IMPLEMENTAR — riesgo real de ban de cuenta** |

**Nota importante:** Usar Claude Code como herramienta standalone (el usuario lo invoca manualmente) esta permitido. Lo que esta prohibido es que otro programa extraiga tokens OAuth o automatice Claude Code como backend.

### Codex CLI — LEGAL pero IMPRACTICO

| Aspecto | Estado |
|---------|--------|
| **Licencia** | Apache 2.0 — tecnica y legalmente permitido |
| **Limites** | ChatGPT Plus: 30-150 msgs/5h; Pro: 300-1,500 msgs/5h |
| **Problema** | Ventana de 5 horas con limites bajos, compartida entre CLI y web |
| **Non-interactive** | `codex exec PROMPT` funciona, pero los limites hacen inviable el uso intensivo |
| **Veredicto** | **LEGAL pero NO RECOMENDADO como backend principal** — util como fallback ocasional |

---

## Rate Limits Detallados

### Gemini CLI (backend principal recomendado)

| Tier | Requests/dia | Requests/min | Costo/mes |
|------|-------------|-------------|-----------|
| Google Account (gratis) | 1,000 | 60 | $0 |
| Google AI Pro | 1,500 | 60 | $20 |
| Google AI Ultra | 2,000 | 60 | $25 |
| Gemini API Key (gratis) | 250 | varies | $0 |
| Vertex AI Pay-as-you-go | ilimitado | varies | variable |

**Nota critica sobre modelo routing:** En tier gratis, Gemini CLI usa ~10-15 requests de Gemini 2.5 Pro antes de caer a Flash. Con AI Pro, el acceso a Pro es mas generoso pero no ilimitado por request — Google rutea entre Pro y Flash internamente.

**Modelo disponible:** Gemini 3 Pro Preview (via alias `auto` o `pro`), Gemini 2.5 Flash, Gemini 2.5 Flash-Lite. Contexto window: 1M tokens (2M para Gemini 3).

### OpenCode CLI (backbone multi-provider)

| Aspecto | Detalle |
|---------|---------|
| Rate limits | Depende del provider configurado (usa API keys directas) |
| Ventaja | Un solo CLI → 75+ providers |
| Server mode | `opencode serve` → REST API en `localhost:4096` |
| Auth | `OPENCODE_SERVER_PASSWORD` para HTTP basic auth |

### Codex CLI (solo fallback)

| Plan | Msgs/5h | Msgs/dia (estimado) |
|------|---------|-------------------|
| ChatGPT Plus ($20/mo) | 30-150 | ~150-720 |
| ChatGPT Pro ($200/mo) | 300-1,500 | ~1,440-7,200 |

*2x rate limits temporales en Q1 2026 (promocion).*

---

## Estrategia de Rate Limiting y Routing

### Token Bucket por CLI

```rust
// Pseudocodigo para el rate limiter
struct CliBridge {
    name: String,
    daily_limit: u32,
    daily_used: AtomicU32,
    minute_limit: u32,
    minute_window: RwLock<SlidingWindow>,
    cooldown_until: AtomicI64,  // unix timestamp
    priority: u8,               // 1=primario, 2=secundario, 3=fallback
}

// Router decision logic
fn select_backend(task: &Task) -> CliBridge {
    // 1. Filtrar por capacidad (contexto grande → Gemini)
    // 2. Filtrar por disponibilidad (no excedido, no en cooldown)
    // 3. Ordenar por prioridad
    // 4. Si todos excedidos → modelo local (siempre disponible)
}
```

### Cascada de Fallback

```
1. Gemini CLI (Pro)     → 1,500 req/dia, 2M context, web search
   ↓ si excedido
2. OpenCode CLI         → dependiendo del provider configurado
   ↓ si excedido
3. Codex CLI            → 30-150 req/5h (solo tareas criticas)
   ↓ si excedido
4. Modelo local (Qwen)  → ilimitado, privado, siempre disponible
```

### Reserva inteligente de quota

- **Mañana (6am-12pm):** 40% del budget diario — mayor productividad del usuario
- **Tarde (12pm-6pm):** 35% del budget
- **Noche (6pm-12am):** 20% del budget
- **Madrugada (12am-6am):** 5% — tareas automaticas de baja prioridad
- **Override:** Si el usuario pide explicitamente, ignorar reserva (con warning)

---

## Seguridad

### 1. Aislamiento de Procesos

```
lifeosd (PID 1 del servicio)
  └── worker (tokio::spawn)
       └── gemini CLI (subprocess, fork+exec)
            - Hereda SOLO: Google OAuth token (via env)
            - NO hereda: API keys de LifeOS, tokens de Telegram, secrets
            - Sandbox: --sandbox flag de Gemini CLI
            - Timeout: 120s max por invocacion
            - Working dir: /tmp/lifeos-sandbox-XXXX (tmpdir efimero)
```

### 2. Prevencion de Prompt Injection en Cadena

**Riesgo:** Agente A envia prompt malicioso a Agente B que lo propaga a Agente C.

**Mitigaciones:**

| Capa | Mecanismo |
|------|-----------|
| **Input sanitization** | Strip de instrucciones sospechosas antes de enviar a CLI (`ignore previous`, `system:`, etc.) |
| **Output validation** | Parsear JSON response, rechazar si contiene tool calls no solicitadas |
| **Context isolation** | Cada CLI invocation es stateless — no comparte session/memoria con Axi |
| **Depth limit** | Maximo 1 nivel de delegacion: Axi → CLI → respuesta. Sin recursion CLI→CLI |
| **Content boundary** | Marcar claramente input del usuario vs context del sistema en el prompt |
| **Audit log** | Loguear CADA invocacion a CLI bridge con: prompt hash, response hash, tokens, latencia |

### 3. Prevencion de Fuga de Secretos

- Gemini CLI recibe SOLO el prompt y el OAuth token del usuario (ya autenticado)
- NUNCA pasar a Gemini: API keys de otros providers, tokens de Telegram, bootstrap token
- Working directory aislado sin acceso a `/var/lib/lifeos/` ni `/home/lifeos/.config/`
- Response sanitization: si la respuesta contiene algo que parece un secret (`sk-`, `ghp_`, `xoxb-`), redactarlo antes de devolver a Axi

### 4. Prevencion de Cost Runaway

- Hard cap diario por CLI bridge (configurable, default: 80% del limite del tier)
- Si Axi genera >10 requests/minuto al mismo bridge, activar backpressure (cooldown 30s)
- Si un worker lleva >5 minutos, notificar al usuario y pedir confirmacion para continuar
- Dashboard: grafica de uso por bridge con alertas al 50%, 75%, 90% del budget diario

### 5. Prevencion de Loops Infinitos

- Cada task tiene un `max_iterations` (default: 5)
- Cada delegacion a CLI bridge incrementa un `depth_counter`
- Si `depth_counter > 1`, rechazar — Axi NUNCA debe pedir a Gemini que llame a otro CLI
- Timeout global por task: 10 minutos
- Si la misma query se repite 3 veces en 5 minutos, detener y notificar al usuario

---

## Decision: Subprocess vs MCP Wrapper

### Opcion A: Subprocess directo

```rust
let output = Command::new("gemini")
    .args(&["-p", &prompt, "--output-format", "json", "--approval-mode", "yolo"])
    .env("GOOGLE_APPLICATION_CREDENTIALS", &oauth_path)
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()?
    .wait_with_output()?;
```

**Pros:** Simple, sin dependencias, control total del lifecycle.
**Contras:** Parsing manual de JSON, no discovery, cada CLI requiere wrapper custom.

### Opcion B: MCP server wrapper (lifeos-gemini-bridge)

```
Axi (MCP client) → lifeos-gemini-bridge (MCP server, stdio) → gemini CLI (subprocess)
```

**Pros:** Estandar MCP, tool discovery automatico, compatible con cualquier MCP client.
**Contras:** Una capa mas de abstraccion, latencia adicional (~50ms).

### Veredicto: **MCP wrapper (Opcion B)** — por estas razones:

1. **LifeOS ya es MCP client (Fase Q)** — la integracion es nativa, no requiere codigo nuevo en el daemon
2. **Estandar de industria** — cualquier mejora al protocolo MCP beneficia automaticamente
3. **Desacoplamiento** — el bridge es un binario separado, se puede actualizar sin tocar lifeosd
4. **Multi-CLI uniforme** — un MCP server por CLI, todos exponen la misma interfaz a Axi
5. **Community leverage** — ya existen 3+ wrappers para Gemini, podemos fork/adaptar

### Crear nuestro propio wrapper vs usar Artegy/gemini-cli-mcp

| Criterio | Artegy | Propio (lifeos-gemini-bridge) |
|----------|--------|-------------------------------|
| Mantenimiento | Dependemos de tercero | Control total |
| Scope | Code analysis only | General purpose (Axi necesita mas que code review) |
| Lenguaje | TypeScript/Node.js | Puede ser Rust o TypeScript |
| Customizacion | Limitada | Total (rate limiting, sanitization, logging integrado) |
| **Veredicto** | Buen reference | **Crear propio, inspirado en Artegy + dnnyngyen** |

**Razon principal:** Artegy/gemini-cli-mcp esta optimizado para code review con code2prompt. LifeOS necesita un bridge general: "enviame este prompt a Gemini y dame la respuesta". El wrapper dnnyngyen/gemini-cli-orchestrator es mejor referencia arquitectonica (plan+craft+synthesize pattern), pero tambien es code-focused. Necesitamos un bridge general-purpose.

---

## Casos de Uso (no solo codigo)

### Tareas de Asistente Personal

| Caso | Por que Gemini bridge | Alternativa local |
|------|----------------------|-------------------|
| "Resume este PDF de 200 paginas" | 2M context window | Qwen no puede (4K-8K ctx) |
| "Busca en internet que paso hoy con Bitcoin" | Google Search grounding nativo | No disponible localmente |
| "Compara estas 5 ofertas de trabajo" | Razonamiento complejo + web | Posible pero mas lento |
| "Traduce este contrato legal al ingles" | Precision alta en legal | Argos/local aceptable |
| "Planifica mi viaje a Barcelona en junio" | Web search + razonamiento + creatividad | No tiene info actualizada |
| "Analiza mi codebase y sugiere arquitectura" | 1M+ tokens de contexto | Imposible localmente |

### Tareas de Desarrollo

| Caso | CLI optimo | Razon |
|------|-----------|-------|
| Code review de PR grande | Gemini | Contexto masivo (archivos completos) |
| Generar tests unitarios | Gemini o Local | Depende del tamano del contexto |
| Debug de error críptico | Gemini (web search) | Puede buscar issues similares en internet |
| Refactoring de modulo | Local | Privado, rapido, iterativo |
| Escribir documentacion | Gemini o Local | Depende de si necesita context externo |

### Routing Inteligente por Tarea

```
Router Decision Tree:

1. Requiere >32K tokens de contexto?
   → SI: Gemini (2M ctx)
   → NO: continuar

2. Requiere informacion actual de internet?
   → SI: Gemini (Google Search grounding)
   → NO: continuar

3. Contiene datos sensibles (finanzas, medico, personal)?
   → SI: Modelo local (NUNCA sale de la maquina)
   → NO: continuar

4. Es tarea simple (<5s estimado)?
   → SI: Modelo local (menor latencia)
   → NO: Gemini (mayor calidad de razonamiento)

5. Quota de Gemini excedida?
   → SI: OpenCode → Codex → Local
   → NO: Gemini
```

---

## Plan de Implementacion

### AQ.1 — lifeos-gemini-bridge (MCP server) [P0, 1-2 dias]

- [ ] Crear crate `bridges/gemini/` (o directorio npm si TypeScript) con MCP server stdio
- [ ] Tool `gemini_query`: recibe prompt (string), devuelve response (string) + stats (tokens, latencia)
- [ ] Tool `gemini_query_json`: recibe prompt, devuelve respuesta parseada como JSON
- [ ] Tool `gemini_analyze_files`: recibe lista de paths, concatena contenido, envia a Gemini con instrucciones
- [ ] Subprocess management: spawn `gemini -p ... --output-format json --approval-mode yolo`
- [ ] Parsear response JSON: extraer `.response` y `.stats`
- [ ] Error handling: timeout (120s), exit code != 0, rate limit (429), auth failure
- [ ] Config: path al binario gemini, timeout, flags adicionales
- [ ] Test: mock de subprocess con response JSON fijo

### AQ.2 — Rate limiter + router integration [P0, 1 dia]

- [ ] Struct `CliBridgeRegistry` en `llm_router.rs` con bridges registrados
- [ ] Token bucket por bridge: daily counter + minute sliding window
- [ ] Cascada de fallback: Gemini → OpenCode → Local
- [ ] Configuracion en `/etc/lifeos/cli-bridges.toml`:
  ```toml
  [bridges.gemini]
  enabled = true
  binary = "/usr/bin/gemini"
  daily_limit = 1200  # 80% de 1500 (AI Pro)
  minute_limit = 50   # 83% de 60
  timeout_secs = 120
  priority = 1

  [bridges.opencode]
  enabled = false
  binary = "/usr/bin/opencode"
  server_port = 4096
  priority = 2
  ```
- [ ] Metricas: requests totales, exitosos, fallidos, latencia p50/p95/p99 por bridge
- [ ] Evento WebSocket `bridge.quota_warning` al 75% y 90% del daily limit

### AQ.3 — Conectar a Fase AP (async workers) [P1, 1 dia]

- [ ] Worker async puede llamar a CLI bridge via MCP client
- [ ] Clasificador de Fase AP: si tarea requiere contexto masivo → marcar para Gemini bridge
- [ ] Si bridge responde rate limit → reencolar con siguiente bridge en cascada
- [ ] Progress updates al usuario: "Consultando Gemini... Procesando respuesta..."

### AQ.4 — lifeos-opencode-bridge (MCP server) [P1, 1-2 dias]

- [ ] Crear MCP server que conecta a `opencode serve` via REST API
- [ ] Tool `opencode_query`: HTTP POST a `localhost:4096/api/session/send`
- [ ] Tool `opencode_models`: listar modelos disponibles via API
- [ ] Auth: `OPENCODE_SERVER_PASSWORD` en config
- [ ] Ventaja: OpenCode soporta 75+ providers — si el usuario tiene API keys de varios, usarlos todos

### AQ.5 — Security hardening [P1, 1 dia]

- [ ] Subprocess sandboxing: tmpdir efimero, sin acceso a secrets de LifeOS
- [ ] Input sanitization: regex filter para prompt injection patterns
- [ ] Output sanitization: redactar secrets en responses
- [ ] Audit log: cada invocacion a bridge en `/var/log/lifeos/bridge-audit.jsonl`
- [ ] Depth limiter: rechazar si el call proviene de otro bridge (no recursion)

### AQ.6 — Dashboard UX [P2, 1 dia]

- [ ] Seccion "CLI Bridges" en dashboard web
- [ ] Por bridge: status (connected/disconnected), quota usage (barra), requests hoy, latencia media
- [ ] Grafica de uso ultimas 24h por bridge
- [ ] Boton "Test Connection" para verificar que el CLI esta instalado y autenticado
- [ ] Alert visual cuando quota > 75%

### AQ.7 — Codex bridge (opcional, baja prioridad) [P3]

- [ ] Solo si el usuario tiene ChatGPT Pro ($200/mo) con limites suficientes
- [ ] `codex exec PROMPT` como subprocess
- [ ] Rate limiter con ventana de 5 horas (no diaria)
- [ ] Marcar como "last resort" en cascada — solo cuando Gemini y OpenCode esten excedidos

---

## Prerequisitos

| Prerequisito | Estado | Fase |
|-------------|--------|------|
| MCP client en lifeosd | Completado | Fase Q |
| MCP server en lifeosd | Completado | Fase Q |
| Async workers | Planificado | Fase AP |
| LLM router multi-provider | Existente | `llm_router.rs` |
| Gemini CLI instalado en host | Requiere usuario | Manual (`npm i -g @google/gemini-cli`) |

## Dependencias externas

| Dependencia | Instalacion | Responsable |
|-------------|-------------|-------------|
| Gemini CLI | `npm i -g @google/gemini-cli` | Usuario (first-boot wizard, Fase AE) |
| Google OAuth login | `gemini` (primera ejecucion, browser flow) | Usuario |
| OpenCode CLI | `brew install opencode` o `npm i -g opencode-ai` | Usuario (opcional) |
| Node.js 18+ | Ya en LifeOS image | Imagen bootc |

---

## Comparativa con Alternativas

### Por que NO usar Gemini API key directamente?

| Aspecto | API Key | CLI Subscription Bridge |
|---------|---------|----------------------|
| Costo/1000 requests | $1-15 (segun modelo) | $0 (incluido en $20/mes) |
| Limites | Sin limite diario (pay-as-you-go) | 1,000-2,000/dia |
| Setup | Crear API key, configurar billing | Login con Google |
| Riesgo de costos | Bill shock real | Fixed $20/mes max |
| Para LifeOS target user | Overkill (dev setup) | Perfecto (consumer setup) |

**Conclusion:** Para el usuario target de LifeOS (persona que paga $20/mes de Google AI Pro), el bridge es estrictamente superior. Para power users que quieren ilimitado, API key sigue disponible via `llm_router.rs` existente.

### Por que NO depender solo del modelo local?

| Aspecto | Solo local (Qwen 3.5 4B) | Local + Gemini bridge |
|---------|--------------------------|----------------------|
| Contexto maximo | 4K-32K tokens | 2M tokens (Gemini 3) |
| Web search | No | Si (Google Search grounding) |
| Calidad razonamiento | Buena para tareas simples | Frontier para tareas complejas |
| Privacidad | Total | Parcial (prompts van a Google) |
| Disponibilidad | Siempre | Depende de quota/internet |
| Latencia | ~1-5s | ~3-15s |

**Conclusion:** Modelo hibrido. Local para privacidad y velocidad, Gemini para potencia y contexto. El router decide automaticamente.

---

## Proyectos de Referencia Estudiados

1. **[Artegy/gemini-cli-mcp](https://github.com/Artegy/gemini-cli-mcp)** — MCP server que usa code2prompt + Gemini CLI para code review. TypeScript. Buena referencia de como invocar Gemini como subprocess y parsear JSON. Limitado a code analysis.

2. **[dnnyngyen/gemini-cli-orchestrator](https://github.com/dnnyngyen/gemini-cli-orchestrator)** — MCP server que permite a Claude Code orquestar Gemini. Patron plan→craft→synthesize. Mejor arquitectura que Artegy pero tambien code-focused.

3. **[nosolosoft/opencode-mcp](https://github.com/nosolosoft/opencode-mcp)** — MCP server para OpenCode CLI. Manejo de sesiones, descubrimiento de modelos.

4. **[ajhcs/Better-OpenCodeMCP](https://github.com/ajhcs/Better-OpenCodeMCP)** — Fork mejorado con async task execution, process pooling, crash recovery. 293 tests. Referencia para robustez.

5. **Gemini CLI SDK** (`packages/sdk/SDK_DESIGN.md`) — SDK oficial en desarrollo para uso programatico de Gemini CLI. Cuando madure, podriamos usarlo en vez de subprocess. Tiene `GeminiCliAgent`, `session.sendStream()`, custom tools. Actualmente incompleto (hooks, subagents, ACP no implementados).

---

## Riesgos y Mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|------------|
| Google cambia rate limits a la baja | Media | Alto | Cascada de fallback + modelo local siempre disponible |
| Google bloquea uso automatizado (como Anthropic) | Baja | Critico | Headless mode es feature OFICIAL, Apache 2.0, Google lo promueve |
| Latencia alta del subprocess spawn | Media | Medio | Pool de procesos pre-spawned, o migrar a Gemini SDK cuando madure |
| Usuario no instala Gemini CLI | Alta | Medio | First-boot wizard (Fase AE), `life doctor` check, install script |
| Prompt injection cross-agent | Media | Alto | Sanitization + isolation + depth limit + audit log |
| OAuth token expira silenciosamente | Media | Medio | Health check periodico (`gemini -p "ping" --output-format json`) |

---

## Metricas de Exito

| Metrica | Target |
|---------|--------|
| Latencia end-to-end (Telegram msg → response) | < 15s para tareas Gemini |
| Tasa de exito de invocaciones Gemini | > 95% |
| Fallback a local cuando quota excedida | 100% (nunca dejar al usuario sin respuesta) |
| Requests/dia usados vs disponibles | 60-80% (ni desperdicio ni limit) |
| Usuarios que configuran Gemini bridge | > 50% de usuarios LifeOS |
| Zero secret leaks via bridge | 100% |

---

*Fase AQ depende de: Fase Q (MCP, completada), Fase AP (async workers, en progreso), Fase AE (first-boot wizard, planificada).*
*Prioridad: ALTA — impacto directo en la calidad de las respuestas de Axi para $0 adicional si el usuario ya tiene Google AI Pro.*
