# Investigacion: CLIs de suscripcion como backends LLM para Axi

**Fecha:** 2026-03-29
**Estado:** Investigacion completa
**Veredicto:** Tecnica viable en los tres casos, pero con perfiles de riesgo muy distintos: Claude consumer esta explicitamente prohibido como backend third-party; Codex CLI si soporta automatizacion oficial, pero no es un buen backend compartido ni multiusuario; Gemini es la opcion mas limpia si se documentan bien sus planes y cuotas reales

---

## 1. Resumen ejecutivo

La idea: usuarios con suscripciones consumer o developer ya tienen acceso a modelos
frontier desde Claude Code, Codex o Gemini CLI. LifeOS podria crear wrappers MCP
alrededor de estos CLIs para que Axi los use como proveedores LLM sin pedir API keys
en todos los casos.

**Conclusion:** La viabilidad tecnica es excelente — Claude Code, Gemini CLI y Codex
soportan modos no-interactivos. El problema real no es tecnico sino de producto,
autenticacion y terminos:

- **Anthropic:** si prohbe explicitamente usar credenciales consumer (Free/Pro/Max)
  fuera de Claude Code / Claude.ai o en productos third-party.
- **OpenAI:** documenta oficialmente `codex exec`, login con ChatGPT y hasta flujos
  de CI/CD, asi que no se puede equiparar con Anthropic. Aun asi, sigue siendo mala
  base para un backend compartido por limites, credenciales y riesgo operativo.
- **Google:** ofrece la ruta mas limpia para integracion por CLI o API, pero hay que
  distinguir cuidadosamente entre free tier, Gemini Code Assist y planes web de Gemini,
  porque no todos aplican al CLI.

---

## 2. Analisis tecnico por CLI

### 2.1 Claude Code CLI (`claude`)

**Modo no-interactivo:** Excelente.

```bash
# Uso basico
claude -p "pregunta" --output-format json

# Con schema estructurado
claude -p "extrae funciones" --output-format json --json-schema '{...}'

# Streaming JSON
claude -p "explica" --output-format stream-json --verbose

# Modo bare (sin carga de configs locales)
claude --bare -p "tarea" --allowedTools "Read,Edit,Bash"

# Continuar conversaciones
claude -p "sigue" --continue
claude -p "sigue" --resume "$session_id"
```

**Formatos de salida:**
- `text` (default): texto plano
- `json`: JSON estructurado con resultado, session ID y metadata
- `stream-json`: JSON delimitado por lineas para streaming en tiempo real

**Agent SDK:** Disponible en Python y TypeScript para control programatico completo.
PERO: requiere autenticacion con API key, no acepta OAuth de suscripciones consumer.

**Viabilidad tecnica: 10/10**

---

### 2.2 Gemini CLI (`gemini`)

**Modo no-interactivo (Headless):** Excelente.

```bash
# Modo headless con prompt
gemini -p "pregunta"

# JSON output
gemini -p "pregunta" --output-format json

# Nota: algunas referencias del proyecto mencionan stream-json, pero la pagina
# oficial de headless documenta solo text y json. Tratar como version-dependiente.
# gemini -p "pregunta" --output-format stream-json
```

**Formatos de salida:**
- Default: texto
- `json`: objeto JSON con `response`, `stats` y `error`
- `stream-json`: mencionado en el README oficial del repo, pero no en la pagina oficial
  de headless. Debe tratarse como capacidad no estable hasta pinnear version y validar.

**Autenticacion:** Google Account (OAuth), API key, o Vertex AI.

**Cuotas oficiales relevantes:**
- Login con Google: `1000` requests/dia, `60` requests/min
- Gemini API key sin pago: `250` requests/dia, `10` requests/min, Flash only
- Gemini Code Assist Standard: `1500` requests/dia, `120` requests/min
- Gemini Code Assist Enterprise: `2000` requests/dia, `120` requests/min

**Importante:** La documentacion oficial aclara que ciertos planes web de Gemini no
aplican automaticamente al uso del CLI/API. No conviene asumir que cualquier plan
consumer de "Google AI Pro" equivale a cuota ampliada para Gemini CLI.

**Viabilidad tecnica: 9/10**

---

### 2.3 OpenAI Codex CLI (`codex`)

**Modo no-interactivo:** Excelente.

```bash
# Exec no-interactivo
codex exec "tarea"

# Con JSON output
codex exec --json "tarea"

# Full auto con sandbox
codex exec --full-auto --sandbox danger-full-access "tarea"

# Pipe desde stdin
echo "prompt" | codex exec -

# Output schema estructurado
codex exec --output-schema schema.json "tarea"

# Nota: `codex -q --json` pertenece a CLIs previos/historicos y no debe tomarse
# como interfaz estable del Codex CLI actual.
```

**Formatos de salida:**
- Default: texto final a stdout, progreso a stderr
- `--json`: JSON Lines con eventos (`thread.started`, `turn.completed`, `item.*`)
- `--output-schema`: respuesta validada contra JSON Schema

**Autenticacion:** `CODEX_API_KEY` o auth de ChatGPT guardada en `~/.codex/auth.json`.

**Incluido en ChatGPT Plus:** Si, explicitamente. OpenAI documenta limites promedio
por plan y modelo, con ventana compartida de 5h para tareas locales/cloud segun el caso.

**Viabilidad tecnica: 9/10**

---

### 2.4 OpenCode (`opencode`)

**Modo no-interactivo:** Bueno, con arquitectura cliente/servidor.

```bash
# Servidor headless
opencode serve              # HTTP API en puerto 4096
opencode serve --port 8080  # Puerto personalizado

# CLI no-interactivo
opencode "pregunta"
```

**Arquitectura:** Cliente/servidor con OpenAPI spec en `/doc`.
SDK oficial en JS/TS: `@opencode-ai/sdk`.
Soporta ACP (Agent Client Protocol) via stdin/stdout con nd-JSON.

**Autenticacion:** Variable por proveedor (no acoplado a ninguno).
Password HTTP basic auth con `OPENCODE_SERVER_PASSWORD`.

**NOTA LEGAL IMPORTANTE:** La situacion OpenCode/Claude es mas matizada de lo que
parecia inicialmente. La documentacion oficial actual de OpenCode todavia describe una
ruta para conectar Anthropic/Claude Pro-Max mediante plugins, pero aclara explicitamente
que Anthropic lo prohibe y que OpenCode dejo de incluir esos plugins bundled desde 1.3.0.
La conclusion practica sigue siendo "alto riesgo", pero "eliminar toda integracion"
ya no describe con precision el estado actual.

**Viabilidad tecnica: 8/10** (buena API, pero proveedor-dependiente)

---

## 3. Analisis legal

### 3.1 Anthropic (Claude Code) — PROHIBIDO

**Veredicto: NO se puede usar como backend de LifeOS.**

Hechos clave:
- La documentacion oficial de Anthropic dice que OAuth consumer (Free/Pro/Max) es
  exclusivamente para Claude Code y Claude.ai
- La documentacion oficial tambien dice que no se permite usar esas credenciales en
  el Agent SDK ni en productos, herramientas o servicios third-party
- Anthropic se reserva explicitamente el derecho de aplicar medidas de enforcement
- Reportes externos y documentacion de proyectos como OpenCode sugieren que este
  enforcement ya se ha aplicado en la practica

**Lo que esta permitido:**
- Usar `claude -p` directamente en tu terminal como usuario (uso personal)
- Usar API keys para uso comercial (bajo Commercial Terms)
- Multi-model routing con otros LLMs junto a Claude (sin entrenar modelos competidores)

**Lo que esta PROHIBIDO:**
- Extraer tokens OAuth para usarlos en otra app
- Hacer que otra app (como LifeOS/Axi) envie requests a traves de credenciales consumer
- Usar el Agent SDK con autenticacion OAuth de suscripciones consumer
- Suplantar el harness Claude Code desde otro software

**Zona gris critica:** Llamar al binario `claude -p` como subproceso desde LifeOS
tecnicamente ejecuta el producto oficial de Anthropic. Pero la intencion de los ToS
es clara: los tokens de suscripcion son exclusivamente para Claude Code y claude.ai,
no para alimentar agentes third-party. Anthropic podria considerar esto una violacion
del espiritu de los terminos, y dado que ya han tomado acciones legales agresivas
(OpenCode, OpenClaw), el riesgo es alto.

### 3.2 OpenAI (Codex) — SOPORTADO LOCALMENTE, MALO COMO BACKEND COMPARTIDO

**Veredicto:** No esta en la misma categoria legal que Claude Code. OpenAI documenta
explcitamente automatizacion con `codex exec`, login con ChatGPT en CLI/IDE y hasta
patrones para conservar `auth.json` en runners confiables de CI/CD. Eso hace que un
uso local, single-user y opt-in sea defendible desde producto. Lo que NO es buena idea
es tratar Codex como backend compartido, multiusuario o expuesto como servicio.

- Codex CLI esta incluido en ChatGPT Plus/Pro/Business/Enterprise/Edu
- Codex soporta login con ChatGPT o API key
- OpenAI recomienda API keys para workflows programaticos y CI/CD, pero no prohibe
  el uso no-interactivo del CLI; al contrario, lo documenta
- Las credenciales suelen cachearse en `~/.codex/auth.json` o keyring local
- Los limites dependen del plan, modelo y complejidad; no son suficientemente amplios
  para convertirlo en backend principal de un agente persistente

**Riesgos reales:**
- Compartir la cuenta o exponer el proceso a terceros si seria problematico
- Los limites de consumo del usuario son finitos y variables
- El comportamiento de precios/creditos cambia por plan, modelo y modo local/cloud
- OpenAI empuja claramente a usar API keys como opcion recomendada para automatizacion

### 3.3 Google (Gemini CLI) — VIABLE

**Veredicto: La mejor opcion para un fallback CLI, pero con matices importantes.**

- Gemini CLI es Apache 2.0 (open source)
- Free tier generoso: 1,000 req/dia sin pagar nada
- Google no ha tomado acciones contra uso programatico
- Soporta API keys (pay-as-you-go) y OAuth de cuenta Google
- Las cuotas ampliadas documentadas para CLI estan ligadas a Gemini Code Assist
  Standard/Enterprise o a rutas especificas de suscripcion/autenticacion, no a
  cualquier plan web de Gemini
- No hay una restriccion equivalente a la de Anthropic contra usar el CLI como
  wrapper local del propio usuario

**Ventaja adicional:** Al ser open source, LifeOS podria incluso integrar
el codigo de Gemini CLI directamente en lugar de wrapearlo como subproceso.

---

## 4. Limites de uso por suscripcion

| CLI | Plan | Mensajes/ventana | Ventana | Notas |
|-----|------|-------------------|---------|-------|
| Claude Code | Pro ($20/mo) | ~10-40 prompts | 5h rolling | Compartido con claude.ai y Desktop |
| Claude Code | Max ($100/mo) | ~50-800 prompts | 5h rolling | Mas headroom |
| Codex | Plus ($20/mo) | 33-168 (GPT-5.4 local) | 5h | Oficial, depende de complejidad |
| Codex | Pro ($200/mo) | 223-1120 (GPT-5.4 local) | 5h | Oficial, depende de complejidad |
| Gemini CLI | Free | 1,000/dia | 24h | 60 req/min |
| Gemini CLI | API key free | 250/dia | 24h | 10 req/min, Flash only |
| Gemini CLI | Code Assist Standard | 1,500/dia | 24h | 120 req/min |
| Gemini CLI | Code Assist Enterprise | 2,000/dia | 24h | 120 req/min |

**Observacion critica:** Claude y Codex siguen siendo malos candidatos para un backend
siempre-on basado en suscripcion consumer. Gemini tiene mejor historia de cuotas, pero
hay que mapear correctamente el tipo de autenticacion del usuario antes de prometer
capacidad.

---

## 5. Arquitectura propuesta

La arquitectura recomendada sigue favoreciendo Gemini API/CLI, pero ya no por asumir
que Codex este "prohibido". La razon principal es operativa: control, cuotas y menor
fragilidad. Si algun dia se integra Codex CLI, deberia ser **solo** como bridge local
single-user y nunca como backend compartido.

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│   lifeosd   │────>│  MCP Server:     │────>│  gemini -p   │
│  (Axi core) │<────│  gemini-bridge   │<────│  --json      │
│             │     │                  │     │              │
│ llm_router  │     │  - Traduce MCP   │     │ Google OAuth │
│  selecciona │     │    a gemini CLI  │     │ o API key    │
│  proveedor  │     │  - Parsea JSON   │     │              │
└─────────────┘     │  - Rate limiting │     └──────────────┘
                    │  - Cache         │
                    └──────────────────┘
```

### Componentes:

1. **gemini-bridge (MCP Server)**
   - Recibe requests MCP del llm_router de lifeosd
   - Traduce a invocaciones `gemini -p --output-format json`
   - Parsea respuesta JSON y devuelve via MCP
   - Implementa rate limiting interno segun tipo de auth (10, 60 o 120 req/min)
   - Cache de respuestas para prompts identicos
   - Manejo de errores y reintentos

2. **llm_router integration**
   - Nuevo provider `gemini-cli` en llm_router.rs
   - Prioridad configurable (usar Gemini CLI cuando API key no disponible)
   - Fallback: llama-server local -> Gemini CLI -> API keys pagadas

3. **Autenticacion**
   - El usuario inicia `gemini` y completa una vez el flujo "Login with Google"
   - O configura API key en variable de entorno
   - lifeosd detecta presencia de gemini CLI y credenciales validas

### Flujo:

```
1. Usuario no tiene API keys configuradas
2. lifeosd detecta `gemini` en PATH y auth valida
3. llm_router agrega "gemini-cli" como provider disponible
4. Para tareas que requieren modelo potente:
   - Primero intenta llama-server local (Qwen3.5-4B, rapido pero limitado)
   - Si la tarea necesita mas capacidad, usa gemini-cli
   - Si hay API keys, usa esas como prioridad
5. gemini-bridge ejecuta: gemini -p "prompt" --output-format json
6. Parsea respuesta y devuelve al agente
```

---

## 6. Que utilidad tendria

### Casos de uso viables (Gemini CLI):

1. **Tareas de coding complejas** — Gemini 3 con 1M tokens de contexto
2. **Analisis de codebase** — revisar archivos grandes que exceden el contexto local
3. **Busqueda web grounded** — Gemini CLI tiene Google Search integrado
4. **Generacion de documentacion** — tareas que no necesitan baja latencia
5. **Planificacion y razonamiento** — tareas que el modelo local no puede resolver
6. **Conversacion general** — no limitado a coding

### Lo que NO funciona bien:

1. **Latencia** — subproceso CLI agrega overhead (~2-5s startup)
2. **Streaming** — posible pero complejo de implementar via subproceso
3. **Contexto compartido** — cada invocacion es stateless (se puede mitigar con --continue)
4. **Herramientas del CLI** — Gemini CLI tiene sus propias tools (file ops, shell) que
   entrarian en conflicto con las de Axi

---

## 7. Alternativas mejores

### 7.1 API Gemini directa (RECOMENDADA)

En lugar de wrapear el CLI, usar la API de Gemini directamente:
- Free tier: depende del metodo de auth (`1000/dia` con login Google, `250/dia` con
  API key gratis)
- Sin overhead de subproceso
- Streaming nativo
- Control total sobre el contexto
- Ya soportado en llm_router.rs via OpenAI-compatible endpoint

**Costo:** $0 para free tier, luego pay-as-you-go.

### 7.2 OpenRouter con creditos

- Acceso a multiples modelos (Claude, GPT, Gemini, etc.)
- Pay-as-you-go con precios competitivos
- Una sola API key para todo
- Ya soportado en llm_router.rs

### 7.3 Modelo local mejorado

- Actualizar de Qwen3.5-4B a modelos mas capaces cuando el hardware lo permita
- Qwen3-8B o Llama 4 cuando esten disponibles en formato GGUF
- Cero costo, cero dependencia externa, cero problemas legales

### 7.4 Codex CLI local como fallback opt-in

- Solo para uso local del propio usuario
- Nunca como servicio remoto, multiusuario o compartiendo credenciales
- Preferir API key cuando se trate de automatizacion formal o CI/CD
- Util si el usuario ya paga ChatGPT y quiere un bridge local sin configurar API key

### 7.5 Gemini CLI como fallback de emergencia

- No como backend principal, sino como opcion cuando:
  - El modelo local no puede resolver la tarea
  - No hay API keys configuradas
  - El usuario tiene cuenta Google (casi todos)
- Esto es lo mas pragmatico y lo unico legalmente limpio

---

## 8. Recomendacion final

### HACER:

1. **Integrar Gemini API directa** como provider en llm_router (no el CLI)
   - Free tier generoso, legalmente limpio, mejor rendimiento que subproceso
   - Prioridad: alta (puede hacerse en Fase 5)

2. **Implementar gemini-cli como fallback** de emergencia
   - Solo cuando no hay API keys y el modelo local no alcanza
   - Con rate limiting agresivo para no quemar el free tier del usuario
   - Prioridad: media

3. **Documentar para usuarios** exactamente que autenticaciones y planes si cuentan
   para Gemini CLI
   - Distinguir Login con Google, API key gratis, Code Assist Standard/Enterprise
   - No mezclarlo con planes web de Gemini que no aplican al CLI/API

4. **Evaluar Codex CLI local como opcion experimental**
   - Solo single-user
   - Sin compartir credenciales
   - Sin depender de ello como backend estable

### NO HACER:

1. **No wrapear Claude Code CLI** — riesgo legal alto, Anthropic activamente bloquea esto
2. **No usar Codex CLI como backend principal o multiusuario** — aunque OpenAI soporta
   automatizacion local, sigue siendo una mala base para un servicio compartido
3. **No extraer tokens OAuth** de ningun CLI — violacion clara de ToS de todos los proveedores
4. **No depender de suscripciones consumer** como backend principal — limites insuficientes

### Prioridad en el roadmap:

Esto NO es un game-changer. La mejor inversion del tiempo de desarrollo es:
1. Terminar el multi-LLM router con API keys (ya en progreso)
2. Agregar Gemini API como provider gratuito (facil, alto impacto)
3. Mejorar el modelo local (Qwen3-8B cuando sea viable)
4. Gemini CLI como ultimo recurso (nice-to-have, no critico)
5. Codex CLI local opt-in solo si realmente aporta valor para usuarios Plus/Pro

---

## 9. Referencias

- [Claude Code headless docs](https://code.claude.com/docs/en/headless)
- [Gemini CLI headless mode](https://google-gemini.github.io/gemini-cli/docs/cli/headless.html)
- [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive)
- [Codex authentication](https://developers.openai.com/codex/auth)
- [Codex pricing and plan limits](https://developers.openai.com/codex/pricing)
- [OpenCode server docs](https://opencode.ai/docs/server/)
- [OpenCode providers docs](https://opencode.ai/docs/providers/)
- [Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Claude Code programmatic usage](https://code.claude.com/docs/en/headless)
- [Claude Agent SDK overview](https://platform.claude.com/docs/en/agent-sdk/overview)
- [Claude Code Pro/Max usage article](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan)
- [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/)
- [Anthropic bans third-party harnesses (The Register)](https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/)
- [Anthropic crackdown (VentureBeat)](https://venturebeat.com/technology/anthropic-cracks-down-on-unauthorized-claude-usage-by-third-party-harnesses)
- [Gemini CLI quotas and pricing](https://google-gemini.github.io/gemini-cli/docs/quota-and-pricing.html)

---

## 10. Computer Use: Axi como usuario humano de CLIs

**Fecha:** 2026-03-29
**Pregunta central:** Si Axi abre un terminal, escribe `claude -p 'hello'` usando
ydotool (simulacion de teclado), lee la respuesta de la pantalla via OCR/screenshot, y
usa esa informacion — es legal? Pueden las empresas detectarlo o prohibirlo?

---

### 10.1 Tres modelos de integracion

Antes de analizar la legalidad, hay que distinguir tres enfoques tecnicamente distintos:

| # | Metodo | Como funciona | Ejemplo |
|---|--------|---------------|---------|
| 1 | **Wrapper de subproceso** | `std::process::Command::new("claude").arg("-p").arg("hello")` | Ejecuta el binario oficial, captura stdout |
| 2 | **Computer Use** | ydotool escribe en un terminal, OCR/screenshot lee la respuesta | Indistinguible de un humano tecleando |
| 3 | **Extraccion de tokens** | Robar OAuth tokens de `~/.claude/` o `~/.codex/auth.json` | Usar credenciales en un cliente propio |

El metodo #3 esta **unanimemente prohibido** por todos los proveedores y no se discute
mas. La pregunta real es si #1 y #2 son legales, y cual tiene menor riesgo.

---

### 10.2 Analisis legal por proveedor

#### 10.2.1 Anthropic (Claude Code) — ALTO RIESGO en ambos metodos

**ToS relevantes:**
- Seccion 3.7 de los Consumer Terms: "Except when you are accessing our Services via
  an Anthropic API Key or where we otherwise explicitly permit it, [you may not] access
  the Services through automated or non-human means, whether through a bot, script, or
  otherwise."
- OAuth de Free/Pro/Max es exclusivamente para Claude Code y claude.ai
- Anthropic implemento bloqueos tecnicos contra harnesses third-party en enero 2026
- OpenCode fue forzado a eliminar plugins bundled de Claude en la version 1.3.0

**Wrapper de subproceso (`claude -p`):**
- Tecnicamente ejecuta el producto oficial de Anthropic, lo cual esta permitido
- Pero la Seccion 3.7 dice "automated or non-human means... through a bot, script, or
  otherwise" — un subproceso lanzado por Axi es literalmente un script automatizado
- La excepcion dice "via an Anthropic API Key" (no aplica a OAuth consumer) o "where we
  otherwise explicitly permit it" (no hay permiso explicito para wrappers third-party)
- Claude Code headless (`claude -p`) SI es una interfaz oficial, pero esta disenada para
  que el USUARIO la use en scripts, no para que otro producto la use como backend

**Computer Use (ydotool + OCR):**
- Tecnicamente indistinguible de un humano tecleando en un terminal
- No extrae tokens, no modifica el binario, no intercepta nada
- PERO: la intencion de los ToS es clara — "automated or non-human means" incluye
  simulacion de teclado aunque sea via uinput del kernel
- Anthropic vende su propio producto Computer Use (Claude Cowork, lanzado marzo 2026)
  que controla teclado y raton de otras apps — pero eso no significa que consientan que
  OTROS hagan lo mismo con SU producto

**Deteccion:**
- **Wrapper:** Facil de detectar. El proceso hijo `claude` puede ver que su padre no es
  un shell interactivo. Anthropic podria checkear `getppid()`, TTY, variables de entorno
- **Computer Use:** Muy dificil de detectar a nivel de aplicacion. ydotool usa uinput
  del kernel, que es indistinguible de un teclado fisico desde la perspectiva de la app
  receptora. Sin embargo, patrones de timing (velocidad constante, zero jitter) podrian
  delatar automatizacion si Anthropic analizara comportamiento biometrico

**Veredicto Anthropic: PROHIBIDO por ToS para ambos metodos.** El wrapper es mas facil
de detectar y bloquear. Computer Use es mas dificil de detectar pero igualmente viola
el espiritu y la letra de los terminos. Dado el historial agresivo de Anthropic con
OpenCode y OpenClaw, el riesgo es inaceptable.

---

#### 10.2.2 OpenAI (Codex CLI) — RIESGO MODERADO

**ToS relevantes:**
- OpenAI Terms of Use: "except as permitted through the API, [you may not] use any
  automated or programmatic method to extract data or output from the Services, including
  scraping, web harvesting, or web data extraction"
- PERO: Codex CLI documenta oficialmente `codex exec` para automatizacion
- OpenAI recomienda API keys para CI/CD pero no prohibe el uso no-interactivo del CLI
  con login de ChatGPT
- La documentacion muestra como verificar auth en scripts: `codex login status` sale con
  codigo 0 cuando hay credenciales validas

**Wrapper de subproceso (`codex exec`):**
- Este es el caso MAS limpio de todos los CLIs. OpenAI documenta explicitamente el uso
  programatico de `codex exec` con `--full-auto` y `--json`
- La restriccion de ToS dice "except as permitted through the API" — el CLI es un
  producto oficial que usa la API internamente, y OpenAI lo considera una via permitida
- Riesgo: bajo-moderado. No es lo mismo que scraping de chatgpt.com

**Computer Use (ydotool + OCR):**
- Innecesario dado que el wrapper de subproceso es explicitamente soportado
- No violaria ToS adicionales mas alla de lo que el wrapper ya hace
- Anadira fragilidad sin beneficio legal

**Deteccion:**
- **Wrapper:** OpenAI no tiene incentivo para detectarlo — lo documentan como uso valido
- **Computer Use:** No detectable a nivel de app, pero sin necesidad de usarlo

**Veredicto OpenAI: Wrapper de subproceso PERMITIDO oficialmente.** Computer Use
innecesario. El riesgo real es que los limites del plan consumer son insuficientes para
un backend persistente, no que el metodo de acceso sea ilegal.

---

#### 10.2.3 Google (Gemini CLI) — RIESGO BAJO (con matices)

**ToS relevantes:**
- Gemini CLI es Apache 2.0, open source
- Gemini CLI Terms: "Directly accessing the services powering Gemini CLI using
  third-party software, tools, or services (for example, using OpenClaw with Gemini CLI
  OAuth) is a violation of applicable terms and policies"
- Google baneó cuentas masivamente en febrero 2026 por uso de OpenClaw con OAuth de
  Gemini/Antigravity — algunos usuarios perdieron acceso a Gmail y Workspace entero
- La clave: Google distingue entre usar el CLI (permitido) y acceder a los SERVICIOS
  DETRAS del CLI con software third-party (prohibido)

**Wrapper de subproceso (`gemini -p`):**
- El CLI es open source. Ejecutar `gemini -p` como subproceso es ejecutar software
  Apache 2.0 de la forma documentada
- A diferencia de Claude, Google no tiene una clausula que prohiba "automated means"
  genericamente — la prohibicion es especifica a acceso directo a los servicios via
  third-party software
- Un subproceso que ejecuta el binario oficial de Google no "accede directamente a los
  servicios" — accede al CLI, que a su vez accede a los servicios
- PERO: los bans de OpenClaw demuestran que Google puede interpretar esto de forma
  amplia cuando detecta abuso de cuota

**Computer Use (ydotool + OCR):**
- Aun mas indirecto que un subproceso — es un humano (virtual) usando el CLI
- No hay clausula en los ToS que cubra este escenario
- Indetectable desde la perspectiva de Google (el CLI no puede saber si lo teclea un
  humano o ydotool)

**Deteccion:**
- **Wrapper:** Poco probable. Google puede ver patrones de uso anomalos (velocidad,
  frecuencia), pero el CLI es open source y headless esta documentado
- **Computer Use:** Practicamente indetectable. El CLI no reporta telemetria sobre
  como fue invocado

**Veredicto Google: Wrapper de subproceso VIABLE y de bajo riesgo** si se respetan las
cuotas. Computer Use innecesario pero extremadamente seguro. El peligro real es el
abuso de cuota (como OpenClaw), no el metodo de acceso.

---

#### 10.2.4 OpenCode — NO APLICA DIRECTAMENTE

OpenCode es un meta-CLI que conecta a multiples proveedores. La legalidad depende del
proveedor subyacente, no de OpenCode. Desde la version 1.3.0, OpenCode elimino plugins
bundled de Claude por presion de Anthropic. Para el analisis de Computer Use, las mismas
reglas de cada proveedor aplican.

---

### 10.3 Precedentes legales relevantes

#### 10.3.1 Industria RPA — $13B+ en automatizacion que simula humanos

UiPath, Automation Anywhere, Blue Prism, y decenas de empresas construyen bots que
literalmente hacen click, escriben texto, y leen pantallas — exactamente lo que Computer
Use haria. Esta industria:

- Factura mas de $13 mil millones al ano (2025-2026)
- Opera legalmente en todos los paises del mundo
- Es usada por bancos, hospitales, gobiernos, y las mismas empresas de tech
- Nunca ha sido declarada ilegal como categoria

**Pero hay un matiz critico:** los bots de RPA normalmente automatizan software INTERNO
de la empresa (ERPs, CRMs, sistemas legacy). Cuando automatizan servicios EXTERNOS,
deben cumplir los ToS de esos servicios. Un bot de UiPath que automatiza SAP interno es
legal; el mismo bot automatizando ChatGPT podria violar los ToS de OpenAI.

#### 10.3.2 Tecnologia de accesibilidad — proteccion legal del screen reading

Los screen readers (JAWS, NVDA, Orca) hacen exactamente lo que Computer Use haria:
leen contenido de la pantalla y lo transforman para el usuario. Estan protegidos por:

- **ADA (Americans with Disabilities Act)** — obliga a apps a ser compatibles con AT
- **Directiva Europea de Accesibilidad** — protecciones similares en la UE
- **Section 508** — requisitos para software del gobierno de EEUU

**Diferencia clave:** la tecnologia asistiva esta protegida porque sirve a personas con
discapacidades. Un bot de IA que lee la pantalla para automatizar trabajo NO tiene esa
proteccion legal. Sin embargo, establece un precedente tecnico: leer la pantalla no es
inherentemente ilegal — es un mecanismo estandar de interaccion.

#### 10.3.3 Claude Computer Use — Anthropic vende lo que podrian prohibir

En marzo 2026, Anthropic lanzo Claude Cowork con capacidad de Computer Use: Claude
controla el teclado y raton del Mac del usuario para operar otras aplicaciones. Esto
significa que:

- Anthropic vende un producto que controla apps de terceros via teclado/raton
- Si Google o Microsoft demandaran a Anthropic por "acceso automatizado" a sus apps, el
  precedente se volveria contra Anthropic
- Crea una asimetria: "esta bien que NUESTRO AI controle OTRAS apps, pero no que OTROS
  AI controlen NUESTRAS apps"

**Implicacion para LifeOS:** Anthropic no puede argumentar coherentemente que Computer
Use es legal cuando lo hacen ellos pero ilegal cuando lo hacen otros. Sin embargo, los
ToS son contratos privados, no leyes — una empresa puede prohibir contractualmente lo
que quiera, independientemente de la coherencia.

#### 10.3.4 hiQ v. LinkedIn — Precedente de acceso automatizado

El Noveno Circuito (confirmado en 2022 tras remand del Supreme Court) establecio que:

- Scraping de datos publicos NO viola la CFAA (Computer Fraud and Abuse Act)
- El CFAA requiere "unauthorized access" — acceder a datos publicos no es "unauthorized"
- Los ToS de un sitio web no convierten automaticamente el acceso en "unauthorized" bajo
  la CFAA

**Aplicacion a Computer Use:** Un CLI que se ejecuta en tu maquina no es un servidor
remoto con gates de autorizacion. La CFAA probablemente no aplica. Sin embargo, la
violacion de ToS sigue siendo un breach of contract civil.

#### 10.3.5 Selenium/Playwright — Millones de usuarios, legal para uso personal

Selenium y Playwright son herramientas de automatizacion web usadas por millones de
desarrolladores. Son legales para:

- Testing de tus propias aplicaciones
- Automatizacion personal
- Scraping de datos publicos (segun hiQ v. LinkedIn)

Son problematicas cuando:

- Evaden deliberadamente deteccion de bots
- Violan ToS especificos de servicios
- Se usan para fraude o abuso de recursos

---

### 10.4 Analisis de deteccion: pueden descubrirte?

#### 10.4.1 Wrapper de subproceso

| Senhal | Detectable? | Por quien? |
|--------|-------------|------------|
| Parent process no es shell interactivo | Si | El CLI puede checkear `getppid()` |
| Sin TTY asignado | Si | `isatty()` en stdout |
| Timing de invocaciones (alta frecuencia) | Si | Telemetria del CLI |
| Variables de entorno inusuales | Si | El CLI puede inspeccionar env |
| User-agent o headers modificados | No aplica | CLIs no usan HTTP user-agent |
| Patron de uso (queries sin contexto humano) | Si | Analisis estadistico server-side |

**Nivel de deteccion: MEDIO.** Los CLIs pueden implementar checks facilmente.
Anthropic ya bloquea harnesses third-party. Google monitorea patrones de uso.
OpenAI no tiene incentivo para bloquear esto dado que lo documentan.

#### 10.4.2 Computer Use (ydotool + OCR)

| Senhal | Detectable? | Por quien? |
|--------|-------------|------------|
| Input via uinput del kernel | No | Indistinguible de teclado fisico para la app |
| Timing perfecto entre keystrokes | Posible | Analisis biometrico (si el CLI lo implementa) |
| Sin movimiento de raton correlacionado | Posible | Solo si hay analisis de HID completo |
| Patron de uso anomalo | Si | Server-side, mismos checks que wrapper |
| OCR leyendo la pantalla | No | La app no puede saber que otra app lee sus pixeles |
| Frecuencia de requests | Si | Server-side, independiente del metodo de input |

**Nivel de deteccion: BAJO a nivel de cliente.** ydotool opera a nivel de kernel
(uinput), creando un dispositivo de entrada virtual que es indistinguible de hardware
real para cualquier aplicacion en userspace. El CLI no puede saber si las teclas vienen
de un teclado USB, un teclado Bluetooth, o ydotool.

**PERO:** la deteccion server-side es identica para ambos metodos. Si haces 100 queries
por hora, da igual si las escribiste a mano o con ydotool — el servidor ve el mismo
patron anomalo.

#### 10.4.3 Mitigaciones para reducir deteccion

Si se decidiera usar Computer Use (no recomendado para Claude, viable para Gemini):

1. **Jitter humano en keystrokes:** ydotool permite delay entre teclas. Usar
   distribucion gaussiana de 50-200ms entre keystrokes, no delays constantes
2. **Rate limiting agresivo:** respetar las cuotas documentadas del proveedor
3. **Pausas organicas:** insertar delays variables entre queries (30s-5min)
4. **Variacion de prompts:** no repetir el mismo patron exacto de invocacion
5. **Sesiones cortas:** imitar el patron de un humano que usa el CLI intermitentemente

---

### 10.5 Tabla comparativa: API vs Wrapper vs Computer Use

| Dimension | API directa | Wrapper subproceso | Computer Use (ydotool) |
|-----------|------------|-------------------|----------------------|
| **Legalidad Claude** | Permitido (con API key) | Zona gris, alto riesgo | Viola ToS, dificil de detectar |
| **Legalidad Codex** | Permitido | Permitido (documentado) | Innecesario |
| **Legalidad Gemini** | Permitido | Viable, bajo riesgo | Extremadamente seguro |
| **Latencia** | ~200-500ms | ~2-5s (startup CLI) | ~5-15s (typing + OCR) |
| **Fiabilidad** | Alta | Media (depende de CLI version) | Baja (OCR puede fallar) |
| **Streaming** | Nativo | Posible (stream-json) | No viable |
| **Deteccion riesgo** | Nulo (uso oficial) | Medio | Bajo (cliente), igual (server) |
| **Complejidad** | Baja | Media | Alta (ydotool + OCR + parsing) |
| **Mantenimiento** | Bajo | Medio (CLI updates) | Alto (cambios de UI rompen OCR) |
| **Costo** | Pay-as-you-go o free tier | $0 (usa suscripcion) | $0 (usa suscripcion) |

---

### 10.6 Recomendacion para LifeOS

#### Lo que Axi DEBE hacer:

1. **Usar APIs directas** como metodo primario (Gemini API free tier, OpenRouter,
   llama-server local). Cero riesgo legal, mejor rendimiento, mas fiable.

2. **Wrapper de subproceso para Gemini CLI** como fallback cuando no hay API keys.
   Gemini CLI es open source (Apache 2.0), headless esta documentado, y Google no
   tiene restricciones contra el uso programatico del CLI en si.

3. **Wrapper de subproceso para Codex CLI** como opcion opt-in para usuarios con
   ChatGPT Plus/Pro. OpenAI documenta oficialmente `codex exec` para automatizacion.

#### Lo que Axi NO debe hacer:

1. **NO usar Computer Use con Claude Code** — viola ToS explicitamente, y aunque es
   dificil de detectar, el historial de enforcement agresivo de Anthropic hace que el
   riesgo sea inaceptable para un proyecto que quiere ser serio.

2. **NO usar Computer Use cuando hay un wrapper de subproceso viable** — Computer Use
   es mas complejo, mas fragil, mas lento, y no reduce el riesgo server-side. Es una
   solucion peor en todos los ejes excepto deteccion a nivel de cliente.

3. **NO depender de evasion de deteccion** como estrategia de producto. Si la unica
   forma de usar un servicio es que no te pillen, no es una base solida para un OS.

#### Cuando Computer Use SI tiene sentido:

Computer Use es una capacidad valiosa de Axi para **otros propositos**:

- Automatizar aplicaciones GUI que no tienen API (formularios web, apps legacy)
- Operar software del usuario por peticion explicita (como hace Claude Cowork)
- Testing automatizado de interfaces graficas
- Accesibilidad y asistencia al usuario

Usar Computer Use para controlar CLIs de IA es la aplicacion MENOS util de esta
capacidad, porque los CLIs ya tienen interfaces programaticas superiores (subproceso,
JSON output, streaming).

---

### 10.7 Consideraciones de seguridad

#### 10.7.1 Riesgos de Computer Use en general

- **Prompt injection via pantalla:** contenido malicioso visible en pantalla podria
  manipular al agente que hace OCR. Anthropic reconoce explicitamente este riesgo en
  su documentacion de Computer Use
- **Escalacion de privilegios:** ydotool requiere acceso a `/dev/uinput`, que
  normalmente requiere permisos especiales (grupo `input` o udev rule)
- **Exfiltracion:** un agente con control de teclado podria ser manipulado para enviar
  datos sensibles a traves de un terminal abierto
- **Superficie de ataque ampliada:** OCR + keyboard simulation + parsing de output =
  mas puntos de fallo y mas vectores de ataque

#### 10.7.2 Riesgos especificos de wrapear CLIs

- **Credenciales en disco:** los CLIs almacenan tokens en archivos locales
  (`~/.claude/`, `~/.codex/auth.json`). Axi no debe leer ni copiar estos archivos
- **Limites compartidos:** el uso de Axi consume la cuota del usuario, que tambien
  necesita para uso directo
- **Updates del CLI:** un update del CLI puede romper el parsing de output
- **Telemetria:** los CLIs pueden reportar metricas que revelen uso automatizado

---

### 10.8 Conclusion

**Computer Use (ydotool + OCR) para controlar CLIs de IA es tecnicamente posible,
legalmente ambiguo, y practicamente inferior a wrappers de subproceso.**

La pregunta "es indistinguible de un humano, asi que es legal?" tiene una respuesta
matizada:

1. **Legalmente:** los ToS prohben "automated means" sin importar COMO se implemente
   la automatizacion. Que sea indetectable no lo hace legal — solo lo hace dificil de
   enforcer.

2. **Practicamente:** la deteccion ocurre a nivel de servidor (patrones de uso), no a
   nivel de cliente (metodo de input). Computer Use no protege contra rate limiting ni
   analisis estadistico.

3. **Estrategicamente:** LifeOS debe construir sobre bases solidas y documentadas, no
   sobre evasion de deteccion. Gemini API directa, Gemini CLI como subproceso, y Codex
   CLI como opcion opt-in cubren todas las necesidades sin riesgo legal.

4. **Paradoja de Anthropic:** Anthropic vende Computer Use para controlar apps de
   terceros mientras prohibe que terceros controlen sus apps. Esta asimetria podria ser
   legalmente desafiable, pero no es un argumento en el que LifeOS deba apostar su
   integridad.

**Veredicto final:** Implementar Computer Use como capacidad general de Axi (para apps
GUI, formularios web, software legacy) tiene mucho valor. Usarlo especificamente para
evadir restricciones de ToS de CLIs de IA no lo tiene.

---

### 10.9 Referencias adicionales

- [Anthropic Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms)
- [Anthropic clarifies ban on third-party tools (The Register)](https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/)
- [OpenCode vs Anthropic legal controversy 2026 (ShareUHack)](https://www.shareuhack.com/en/posts/opencode-anthropic-legal-controversy-2026)
- [Claude Computer Use tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)
- [Claude Cowork and Computer Use launch (claude.com)](https://claude.com/blog/dispatch-and-computer-use)
- [OpenAI Terms of Use](https://openai.com/policies/row-terms-of-use/)
- [Codex CLI non-interactive reference](https://developers.openai.com/codex/cli/reference)
- [Codex authentication docs](https://developers.openai.com/codex/auth)
- [Gemini CLI Terms of Service](https://google-gemini.github.io/gemini-cli/docs/tos-privacy.html)
- [Google banning OpenClaw users (GitHub issue)](https://github.com/openclaw/openclaw/issues/14203)
- [Google bans OpenClaw users (Secure.com)](https://www.secure.com/blog/google-bans-openclaw-users-a-warning-shot-for-the-agentic-ai-era)
- [Mass 403 ToS bans on Gemini (Google AI Forum)](https://discuss.ai.google.dev/t/urgent-mass-403-tos-bans-on-gemini-api-antigravity-for-open-source-cli-users-paid-tier/124508)
- [hiQ v. LinkedIn — Ninth Circuit data scraping ruling](https://calawyers.org/privacy-law/ninth-circuit-holds-data-scraping-is-legal-in-hiq-v-linkedin/)
- [CFAA and web scraping (White & Case)](https://www.whitecase.com/insight-our-thinking/web-scraping-website-terms-and-cfaa-hiqs-preliminary-injunction-affirmed-again)
- [AI Agent Detection signals (HUMAN Security)](https://www.humansecurity.com/learn/blog/ai-agent-signals-traffic-detection/)
- [ADA web accessibility guidance](https://www.ada.gov/resources/web-guidance/)
- [UiPath RPA for Legal](https://uipath.com/solutions/process/legal)
- [RPA legal issues (Lexology)](https://www.lexology.com/library/detail.aspx?g=5ea86cc2-b6d6-4572-8be0-f47ac93a4663)
- [BeCAPTCHA: Bot detection via behavioral biometrics](https://www.sciencedirect.com/science/article/abs/pii/S0952197620303274)
- [ydotool (GitHub)](https://github.com/ReimuNotMoe/ydotool)
