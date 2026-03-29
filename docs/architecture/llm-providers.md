# Estrategia de Acceso a LLMs para LifeOS

Fecha: 2026-03-23 (actualizado 2026-03-24)

## 0. Principio de Privacidad (actualizado 2026-03-24)

LifeOS prioriza providers que **no retienen datos y no entrenan con tu informacion**.

### Ranking de privacidad por provider

| Provider | Retiene datos? | Entrena con datos? | Zero Data Retention | Jurisdiccion | Confianza |
|----------|---------------|-------------------|---------------------|-------------|-----------|
| **Local** (Qwen3.5-2B) | No — nunca sale de tu laptop | No | N/A | Tu laptop | MAXIMA |
| **Cerebras** | No por defecto. Nunca almacena/loguea/reusa | No | Si, por defecto | USA | ALTA |
| **Groq** | No por defecto. Solo si activas persistencia | No | Si, activable | USA | ALTA |
| **Z.AI/GLM** | Ambiguo ("no sin consentimiento") | Ambiguo | No documentado | China | BAJA |
| **OpenRouter** | No (OpenRouter mismo). Pero rutea a providers que SI pueden | Depende del provider final | Si para OpenRouter, no para providers | USA/Mixto | MEDIA |
| **OpenAI API** | 30 dias. Opt-out disponible | No en API pagada. SI en free | Opt-out | USA | MEDIA |
| **Google Gemini** | SI en free tier | SI en free tier | Solo en paid | USA | BAJA (free) |

### Orden de prioridad en el LLM router

```
1. Local (Qwen3.5-2B)      — datos sensibles, maxima privacidad
2. Cerebras (free)          — zero retention, velocidad extrema (2000+ tok/s)
3. Groq (free)              — zero retention, buena velocidad (500-1000 tok/s)
4. Z.AI paid (si hay saldo) — jurisdiccion china, solo para datos no sensibles
5. OpenRouter (fallback)    — privacidad mixta, ultima instancia
```

Fuentes:
- Cerebras: https://cloud.cerebras.ai/privacy
- Groq: https://console.groq.com/docs/your-data
- OpenRouter: https://openrouter.ai/docs/guides/privacy/logging

---

## 1. Situacion Actual de tus Suscripciones

| Suscripcion | Costo/mes | Que incluye |
|-------------|-----------|-------------|
| Claude Max | $100 | Claude Code CLI local, claude.ai web, modelos Opus/Sonnet/Haiku |
| ChatGPT Plus | $20 | ChatGPT web, GPT-4o, GPT-5.4, DALL-E, vision |
| Google AI Pro | $20 | Gemini web, Gemini 3.1 Pro, Deep Research, 2TB storage |
| **Total** | **$140/mes** | |

---

## 2. Pueden tus Suscripciones Usarse como API Programatica?

### Claude Max — PARCIALMENTE

**Lo que Anthropic permite:**
- Usar Claude Code CLI en tu propia computadora para desarrollo local, scripted y automatizado. Es su producto oficial
- Claude Code CLI usa OAuth tokens internamente y Anthropic lo permite porque ES su herramienta

**Lo que Anthropic PROHIBE (desde enero 2026):**
- Extraer el OAuth token de Claude Code y usarlo en otros clientes/tools
- Usar tokens de suscripcion con el Agent SDK
- Proxies como CLIProxyAPI que interceptan el token y lo exponen como API OpenAI-compatible
- Cualquier herramienta tercera usando tu token de suscripcion

**Riesgo de ban:** ALTO. Anthropic empezo a banear cuentas masivamente en enero 2026. Miles de usuarios de OpenClaw, Cline, Roo Code, OpenCode perdieron acceso. El motivo oficial: las suscripciones Max a $200/mes se vuelven "profundamente no rentables" cuando se usan para cargas de trabajo agenticicas sin rate limits

**Lo que OpenClaw hacia:** Usaba el token OAuth de Claude para hacer llamadas API. **Anthropic lo bloqueo explicitamente en enero 2026.** Los usuarios de OpenClaw que dependian de Claude tuvieron que migrar

**Hay una zona gris importante:** Claude Code CLI si se puede usar de forma scripted en tu computadora. Eso significa que LifeOS podria invocar `claude` como subproceso CLI (no como API) y seguiria siendo uso permitido. Pero:
- Es mas lento que una API directa
- No es tan elegante
- No esta 100% claro si Anthropic lo permitira a largo plazo si detectan uso masivo

**Veredicto:** NO usar como API proxy. SI usar Claude Code CLI directamente para tareas de desarrollo de LifeOS (que es su uso intencionado). Para el LLM router del daemon, usar APIs reales

### ChatGPT Plus — NO

**Politica clara de OpenAI:**
- ChatGPT Plus y la API son productos completamente separados con facturacion separada
- "Extraer datos o output de forma automatica o programatica esta prohibido" segun los Terms of Use
- No puedes usar tu suscripcion Plus para hacer llamadas API

**Veredicto:** IMPOSIBLE usar programaticamente. Solo sirve como herramienta manual via web

### Google AI Pro — NO DIRECTAMENTE, PERO...

**La suscripcion AI Pro ($20/mes):**
- Es para uso de consumidor: Gemini web, integrations con Gmail/Docs, Deep Research
- NO incluye acceso API programatico

**PERO la API de Gemini tiene tier gratuito:**
- Gemini 2.5 Flash-Lite: **GRATIS, 1,000 requests/dia, 15 RPM, 250K TPM**
- Gemini 2.5 Flash: **GRATIS, 250 requests/dia, 10 RPM**
- Gemini 2.5 Pro: **GRATIS, 100 requests/dia, 5 RPM**
- Sin tarjeta de credito requerida
- Sin fecha de expiracion

**Veredicto:** La suscripcion AI Pro NO da API. PERO el free tier de la API de Gemini es muy generoso y puedes usarlo para LifeOS sin gastar nada adicional

---

## 3. La Verdad Sobre OpenClaw y APIs

**Como lo hacia OpenClaw antes (2025):**
- Usaba OAuth tokens de Claude Pro/Max directamente como API
- Los usuarios conectaban sus cuentas y OpenClaw hacia llamadas en su nombre

**Que paso en enero 2026:**
- Anthropic desplego protecciones server-side que bloquearon tokens OAuth fuera de sus herramientas oficiales
- Miles de instancias de OpenClaw se rompieron de un dia para otro
- Steinberger (creador de OpenClaw) se unio a OpenAI

**Como se reconstruyeron los usuarios:**
- Migraron a Kimi K2.5 ($0.60/M input) + MiniMax M2.5 ($0.30/M input) como fallback
- Costo total: ~$15/mes para uso moderado
- Algunos usan OpenRouter como intermediario universal

**Conclusion:** Lo que OpenClaw hacia con Claude YA NO SE PUEDE HACER. La solucion actual es APIs baratas de modelos chinos

---

## 4. Opciones Reales para el LLM Router de LifeOS

### Tier 1: GRATIS (sin gastar nada adicional)

| Provider | Modelo | Input/M tokens | Output/M tokens | Limite | Notas |
|----------|--------|----------------|-----------------|--------|-------|
| **Google Gemini API** | 2.5 Flash-Lite | $0 | $0 | 1,000 req/dia, 15 RPM | Mejor opcion gratis. Sin tarjeta |
| **Google Gemini API** | 2.5 Flash | $0 | $0 | 250 req/dia, 10 RPM | Mas capaz que Flash-Lite |
| **Google Gemini API** | 2.5 Pro | $0 | $0 | 100 req/dia, 5 RPM | El mas potente gratis |
| **Zhipu/GLM** | GLM-4.7-Flash | $0 | $0 | Sin limite diario | Modelo chino, bueno para tareas generales |
| **Zhipu/GLM** | GLM-4.5-Flash | $0 | $0 | Sin limite diario | Generacion anterior, gratis total |
| **OpenRouter** | Qwen3 Coder 480B | $0 | $0 | 20 RPM, 200 req/dia | Mejor modelo de coding gratis |
| **OpenRouter** | DeepSeek R1 | $0 | $0 | 20 RPM, 200 req/dia | Reasoning gratis |
| **OpenRouter** | Llama 3.3 70B | $0 | $0 | 20 RPM, 200 req/dia | General purpose |
| **Modelo local** | Qwen 3.5 0.8B/4B | $0 | $0 | Sin limite | Ya incluido en LifeOS |

**Capacidad gratuita total por dia:**
- ~1,550 requests/dia solo de Gemini (combinando 3 modelos)
- ~600 requests/dia de OpenRouter (3 modelos rotativos)
- Ilimitado de GLM Flash y modelo local
- **Esto es SUFICIENTE para un agente que trabaja todo el dia**

### Tier 2: MUY BARATO ($5-15/mes)

| Provider | Modelo | Input/M tokens | Output/M tokens | Notas |
|----------|--------|----------------|-----------------|-------|
| **DeepSeek** | V3.2 | $0.28 | $0.42 | Cache hit: $0.028. Excelente calidad/precio |
| **DeepSeek** | R1 (reasoning) | $0.50 | $2.18 | Para tareas de razonamiento complejo |
| **MiniMax** | M2.5 | $0.30 | $1.20 | 80.2% SWE-Bench. Muy bueno para codigo |
| **Kimi** | K2.5 | $0.60 | $2.50 | Multimodal, vision, 256K contexto |
| **Together AI** | Varios | $0.02-$0.90 | $0.10-$0.90 | 200+ modelos, batch 50% descuento |

**Estimacion de costo para uso agenticico moderado (~100K tokens/dia output):**
- Con DeepSeek V3.2: ~$1.26/mes
- Con MiniMax M2.5: ~$3.60/mes
- Con Kimi K2.5: ~$7.50/mes

### Tier 3: MODERADO ($15-30/mes, para tareas que requieren los mejores modelos)

| Provider | Modelo | Input/M tokens | Output/M tokens | Notas |
|----------|--------|----------------|-----------------|-------|
| **Anthropic API** | Haiku 4.5 | $0.25 | $1.25 | Rapido, barato, buena calidad |
| **Anthropic API** | Sonnet 4.6 | $3.00 | $15.00 | Excelente para codigo y razonamiento |
| **OpenAI API** | GPT-4o | $2.50 | $10.00 | Vision, multimodal |
| **Google API** | Gemini 2.5 Pro (paid) | $1.25 | $10.00 | Contexto largo, grounding |
| **Zhipu** | GLM-4.7 | $0.55 | $2.20 | Buena calidad, precio medio |

---

## 5. Recomendacion: El Stack de LLMs para LifeOS

### Configuracion recomendada: $5-10/mes TOTAL (ademas de tus suscripciones)

```
LLM Router de LifeOS
|
|-- Tareas simples (clasificacion, OCR follow-up, respuestas cortas)
|   -> Qwen 3.5 local (0.8B/4B) — $0/mes
|   -> GLM-4.7-Flash (Zhipu) — $0/mes
|
|-- Tareas medias (chat, resumen, codigo simple, planning basico)
|   -> Gemini 2.5 Flash (free tier) — $0/mes (250 req/dia)
|   -> DeepSeek V3.2 como fallback — ~$1-3/mes
|
|-- Tareas de coding (escribir/revisar/debuggear codigo)
|   -> Qwen3 Coder 480B (OpenRouter free) — $0/mes (200 req/dia)
|   -> MiniMax M2.5 como fallback — ~$2-4/mes
|
|-- Tareas complejas (planning avanzado, razonamiento largo)
|   -> Gemini 2.5 Pro (free tier) — $0/mes (100 req/dia)
|   -> DeepSeek R1 como fallback — ~$1-2/mes
|
|-- Vision/multimodal (screenshots, UI analysis)
|   -> Kimi K2.5 — ~$2-5/mes (256K contexto, vision nativa)
|   -> Gemini 2.5 Flash (free, soporta vision) — $0/mes
|
|-- Desarrollo de LifeOS (TU trabajando directamente)
|   -> Claude Code CLI (tu suscripcion Max) — ya pagado
```

### Costo mensual estimado del LLM router

| Uso | Solo gratis | Con fallback barato |
|-----|-------------|-------------------|
| Agente trabajando 8 horas/dia | $0 | $5-8/mes |
| Agente trabajando 24/7 | $0-3 (con rate limits) | $10-15/mes |
| Desarrollo tu con Claude Code | $0 (ya pagado) | $0 (ya pagado) |

---

## 6. Que Hacer con tus Suscripciones Actuales

### Claude Max ($100/mes) — CONSERVAR

**Uso correcto:** Tu herramienta personal de desarrollo via Claude Code CLI
- Usalo directamente para escribir el codigo de LifeOS
- Para tareas de razonamiento complejas que TU necesitas resolver
- Para code review y arquitectura
- NO intentes usarlo como API para el daemon

**Nota importante:** Si $100/mes te pesa, puedes considerar bajar a Claude Pro ($20/mes) que tambien incluye Claude Code. La diferencia es el rate limit (Pro tiene limites mas bajos). Pero para un solo developer, Pro puede ser suficiente. Eso te ahorraria $80/mes que podrias invertir en APIs

### ChatGPT Plus ($20/mes) — CONSIDERAR CANCELAR

**Realidad:** No puedes usarlo programaticamente. Solo sirve como herramienta web manual.

**Opciones:**
1. **Cancelar y usar los $20 en API de OpenAI:** $20 de creditos API te dan mucho mas valor programatico. Con GPT-4o a $2.50/M input, $20 te compran ~8M tokens de input o ~2M de output. Eso son miles de requests
2. **Mantener si lo usas mucho manualmente** para research, brainstorming, o tareas que no requieren integracion programatica

**Recomendacion:** Cancelar ChatGPT Plus. Abrir cuenta API de OpenAI con $20/mes de credito. Asi LifeOS puede usar GPT-4o programaticamente

### Google AI Pro ($20/mes) — CONSIDERAR BAJAR

**Realidad:** La API de Gemini tiene un tier GRATUITO muy generoso que NO requiere la suscripcion AI Pro

**Si usas AI Pro para:**
- Gmail/Docs AI integrations -> conservar
- Deep Research -> conservar
- Solo quieres Gemini API -> **no necesitas la suscripcion**

**Recomendacion:** Si no usas las integraciones de Workspace, puedes cancelar y usar el free tier de Gemini API. Te ahorras $20/mes

---

## 7. Presupuesto Optimizado Propuesto

### Opcion A: Minimo absoluto (~$105/mes)

| Gasto | Costo |
|-------|-------|
| Claude Max (tu herramienta de dev) | $100 |
| DeepSeek API (agente) | ~$3 |
| Gemini API free tier | $0 |
| GLM Flash free | $0 |
| OpenRouter free models | $0 |
| **Total** | **~$103** |

### Opcion B: Balance costo/capacidad (~$125/mes)

| Gasto | Costo |
|-------|-------|
| Claude Max (tu herramienta de dev) | $100 |
| OpenAI API (antes ChatGPT Plus) | $20 (creditos API, no suscripcion) |
| DeepSeek API | ~$3 |
| Kimi K2.5 API | ~$2 |
| Gemini API free tier | $0 |
| GLM Flash free | $0 |
| **Total** | **~$125** |

### Opcion C: Recorte agresivo (~$40/mes)

| Gasto | Costo |
|-------|-------|
| Claude Pro (bajar de Max) | $20 |
| OpenAI API credits | $10 |
| DeepSeek API | ~$3 |
| Kimi K2.5 API | ~$2 |
| Gemini API free tier | $0 |
| GLM Flash free | $0 |
| OpenRouter free models | $0 |
| **Total** | **~$35** |

---

## 8. Implementacion Tecnica del LLM Router

### Arquitectura

```
lifeosd (daemon)
  |
  +-- llm_router.rs
       |
       +-- Provider: Local (llama-server en :8082)
       |     API: OpenAI-compatible
       |     Modelos: Qwen 3.5 0.8B, 4B
       |
       +-- Provider: Gemini Free
       |     API: generativelanguage.googleapis.com
       |     Key: API key gratuita de Google AI Studio
       |     Modelos: 2.5 Flash-Lite, Flash, Pro
       |
       +-- Provider: DeepSeek
       |     API: api.deepseek.com (OpenAI-compatible)
       |     Modelos: V3.2, R1
       |
       +-- Provider: OpenRouter
       |     API: openrouter.ai/api (OpenAI-compatible)
       |     Modelos: Qwen3 Coder, DeepSeek R1, Llama 3.3
       |
       +-- Provider: Kimi (Moonshot)
       |     API: api.moonshot.cn (OpenAI-compatible)
       |     Modelos: K2.5
       |
       +-- Provider: GLM (Zhipu)
       |     API: open.bigmodel.cn (OpenAI-compatible)
       |     Modelos: GLM-4.7-Flash (free), GLM-4.7
       |
       +-- Provider: OpenAI (opcional, si conviertes a API)
       |     API: api.openai.com
       |     Modelos: GPT-4o, GPT-4o-mini
       |
       +-- Provider: Anthropic (opcional, si compras API)
             API: api.anthropic.com
             Modelos: Haiku, Sonnet
```

### Logica de seleccion

```
fn select_provider(task: &Task) -> Provider {
    match task.complexity {
        Simple => local o GLM-Flash (gratis, instantaneo)
        Medium => Gemini Flash free (250/dia) o DeepSeek V3.2 ($0.28/M)
        Complex => Gemini Pro free (100/dia) o DeepSeek R1 ($0.50/M)
        Coding => OpenRouter Qwen3 Coder free (200/dia) o MiniMax M2.5 ($0.30/M)
        Vision => Kimi K2.5 ($0.60/M) o Gemini Flash free (soporta vision)
    }
    // Fallback: si el provider primario falla o rate-limited, usar siguiente
}
```

### La mayoria de APIs son OpenAI-compatible

Esto simplifica mucho la implementacion. DeepSeek, OpenRouter, Together AI, Kimi, GLM, y tu llama-server local todos hablan el mismo protocolo `/v1/chat/completions`. Solo Gemini y Anthropic tienen APIs ligeramente diferentes.

Con un solo cliente HTTP que soporte el formato OpenAI + adaptadores para Gemini y Anthropic, cubres TODOS los providers.

---

## 9. Resumen de Decisiones

| Decision | Accion |
|----------|--------|
| Usar suscripciones como API proxy | **NO. Te banean (Claude ya lo hizo)** |
| Claude Max | Conservar para Claude Code CLI (desarrollo). No proxy |
| ChatGPT Plus | **Cancelar. Convertir a $20 de API credits de OpenAI** |
| Google AI Pro | Evaluar si usas Workspace AI. Si no, **cancelar y usar Gemini API free** |
| APIs baratas para el agente | **DeepSeek V3.2 + Kimi K2.5 + Gemini free + GLM free + OpenRouter free** |
| Costo adicional del agente | **$5-15/mes dependiendo de uso** |
| Modelo local | **Seguir con Qwen 3.5 en llama-server como primera linea** |

---

## 10. Seguridad y Privacidad: Que Datos Salen de tu Laptop

### Que datos envia LifeOS a un LLM externo

Cuando el LLM router envia una request a cualquier API externa (sea GLM, DeepSeek, Gemini, OpenAI, o cualquier otra), el contenido que viaja es:

| Dato | Se envia al LLM? | Sensibilidad |
|------|-------------------|-------------|
| Texto de tu prompt/instruccion | SI | Media |
| Texto OCR extraido de tu pantalla | SI (si se incluye como contexto) | ALTA — puede contener passwords, emails, datos financieros |
| Transcripcion de tu voz | SI (el texto, no el audio raw) | ALTA — conversaciones privadas |
| Screenshots como imagen | SI (si usas vision/multimodal) | MUY ALTA — todo lo visible en tu pantalla |
| Audio WAV/PCM raw del microfono | NO — Whisper lo procesa localmente | N/A (nunca sale) |
| Video raw de webcam | NO — presencia se procesa localmente | N/A (nunca sale) |
| Memoria del agente (memory_plane) | SI (si se incluye como contexto para el planner) | ALTA — historial de decisiones y vida personal |
| Codigo fuente de LifeOS | SI (si el agente trabaja en el repo) | BAJA — es open source |
| Configuracion del sistema | Posiblemente (si el agente diagnostica) | MEDIA — podria revelar tu setup |

### Riesgo especifico con APIs chinas (GLM, DeepSeek, Kimi, MiniMax)

Los riesgos documentados son reales y deben tomarse en serio:

1. **Ley china de seguridad nacional:** Las empresas chinas estan legalmente obligadas a cooperar con el gobierno si se les requiere acceso a datos de usuarios
2. **Servidores en China:** Tus datos viajan y potencialmente se almacenan en jurisdiccion china
3. **Incidentes documentados:** DeepSeek tuvo una base de datos expuesta publicamente con mas de un millon de lineas de logs incluyendo historiales de chat y API keys
4. **Censura embebida:** Investigadores encontraron que cuando se incluyen terminos politicamente sensibles para el gobierno chino, la tasa de vulnerabilidades de seguridad en codigo generado aumenta hasta 50%
5. **Politica de privacidad ambigua:** GLM/Zhipu dice que "los datos se retienen solo lo necesario y no se usan para entrenamiento sin consentimiento", pero la verificacion independiente es limitada

**Contexto importante:** Estos riesgos NO son exclusivos de China:
- OpenAI guarda prompts de la API (con opcion de opt-out)
- Google usa datos del tier gratuito para mejorar modelos
- Empresas americanas estan sujetas a programas de vigilancia (NSA/FISA)
- La diferencia es que en democracias occidentales hay mas oversight judicial y legal

### La solucion: Capa de Privacidad en el LLM Router

LifeOS NO tiene que enviar datos crudos a ningun LLM externo. La arquitectura del router debe incluir un filtro de privacidad obligatorio:

```
Dato sensible (screenshot, transcripcion de voz, memoria personal)
    |
    v
[1. Procesamiento LOCAL primero]
    - OCR via Qwen local (ya existe en sensory_pipeline)
    - Transcripcion via Whisper local (ya existe)
    - Deteccion de presencia via webcam local (ya existe)
    - Resumen/extraccion via modelo local
    |
    v
[2. Filtro de privacidad (privacy_filter.rs)]
    - Detectar y redactar: passwords, emails, numeros de tarjeta,
      tokens, API keys, datos financieros visibles
    - Clasificar sensibilidad del contenido: baja/media/alta/critica
    - Resumir en vez de enviar texto completo cuando sea posible
    - Anonimizar nombres propios si no son necesarios para la tarea
    |
    v
[3. Decision de routing basada en sensibilidad]
    - Sensibilidad CRITICA -> SOLO modelo local, nunca sale de la laptop
    - Sensibilidad ALTA -> modelo local preferido; si necesita modelo
      potente, usar Gemini/OpenAI (mejor track record de privacidad)
    - Sensibilidad MEDIA -> cualquier provider confiable
    - Sensibilidad BAJA -> cualquier provider incluyendo chinos
    |
    v
[4. Registro de auditoria]
    - Loggear que datos se enviaron a que provider
    - Loggear que datos se filtraron/redactaron
    - Permitir al usuario revisar que se envio
```

### Politica de datos por tipo de tarea

| Tipo de tarea | Datos involucrados | Provider permitido | Justificacion |
|---------------|-------------------|-------------------|---------------|
| Coding de LifeOS | Codigo open source | Cualquiera (GLM, DeepSeek, etc.) | El codigo es publico |
| Planning de tareas genericas | Descripcion de tarea | Cualquiera | No hay datos personales |
| Resumen de documento tecnico | Texto del documento | Cualquiera | Contenido no personal |
| Analisis de screenshot con datos personales | OCR con emails/passwords visibles | SOLO local | Datos criticos |
| Transcripcion de conversacion privada | Texto de la conversacion | SOLO local o Gemini/OpenAI con opt-out | Datos personales altos |
| Memoria personal ("Vida plena") | Historial de vida | SOLO local, NUNCA API externa | Datos intimos |
| Diagnostico del sistema | Config, logs, estado | Local preferido; APIs OK si se sanitiza | Datos de sistema |
| Busqueda web | Query de busqueda | Cualquiera | No sensible |
| Computer use / UI automation | Screenshots de apps | Local para analisis; API solo si se sanitiza | Puede contener datos sensibles |

### Reglas obligatorias para el router

1. **Screenshots sin sanitizar NUNCA se envian a APIs chinas.** Si necesitas vision multimodal de un screenshot con datos personales, usar modelo local o Gemini (que tiene politica de no-entrenamiento en tier pagado)
2. **Transcripciones de voz personal NUNCA salen de la laptop.** Whisper corre local. El texto resultante se procesa local. Solo el resumen/accion resultante puede ir a API externa
3. **Memoria personal (memory_plane) NUNCA se envia completa.** Solo fragmentos relevantes y sanitizados
4. **Todo envio a API externa se loggea** en `/var/log/lifeos/llm-audit.log` para revision del usuario
5. **El usuario puede configurar su nivel de privacidad:**
   - `paranoid`: solo modelo local, nada sale
   - `careful` (default): sanitiza todo, solo APIs confiables para datos medios
   - `balanced`: sanitiza lo critico, permite APIs chinas para tareas no sensibles
   - `open`: todo va a la API mas rapida/barata disponible

### GLM especificamente: cuando SI y cuando NO usarlo

**SI usar GLM (seguro):**
- Escribir/revisar codigo de LifeOS (es open source)
- Tareas de planning genericas ("descompone esta tarea en pasos")
- Preguntas tecnicas ("como implementar un queue en Rust")
- Research ("que frameworks de agentes existen")
- Generacion de texto no personal ("escribe un README")

**NO enviar a GLM (ni a ninguna API china):**
- Screenshots de tu escritorio con informacion personal visible
- Transcripciones de conversaciones privadas
- Tu memoria personal de "Vida plena"
- Credenciales, tokens, API keys
- Datos financieros o medicos
- Informacion de tu trabajo/empleador si es confidencial

### Nota sobre GLM-4.7 para pruebas del router

GLM-4.7-Flash (gratis, sin limite) es **excelente para probar el LLM router** porque:
- No cuesta nada
- Sin limite de requests diarios
- API OpenAI-compatible (facil de integrar)
- Suficiente calidad para validar que el routing, fallbacks y pipeline funcionan

Para pruebas, no necesitas meter creditos todavia. GLM-4.7-Flash gratis es suficiente. Cuando quieras probar el modelo mas potente (GLM-4.7, 355B params, $0.55/$2.20 per M tokens), entonces si necesitas creditos, pero solo para tareas no sensibles.

---

## 11. Modelo Local Optimo para LifeOS: El Guardian de Privacidad

### El rol del modelo local

El modelo local NO es para todo. Es el **guardian de privacidad** y el **worker rapido** del sistema:

1. Procesar datos sensibles que NUNCA deben salir de la laptop (screenshots, voz, memoria personal)
2. Clasificar la sensibilidad de cada request antes de decidir si va a API externa
3. Hacer tareas rapidas (clasificacion, OCR follow-up, respuestas cortas) sin latencia de red
4. Servir como fallback si no hay internet o las APIs estan caidas
5. Funcionar en CUALQUIER hardware (desde laptops gamer hasta PCs basicas sin GPU)

### Tu hardware actual

| Componente | Spec |
|-----------|------|
| GPU | RTX 5070 Ti — 12 GB VRAM |
| RAM | 96 GB DDR5 5200 MT/s |
| CPU | Intel i9-13900HX (24 cores) |
| VRAM libre deseada para gaming | ~10 GB |
| VRAM disponible para LLM | ~2 GB (para no afectar gaming) |

### Comparativa de modelos candidatos (marzo 2026)

| Modelo | Params | GGUF Q4_K_M | Contexto nativo | Multimodal | Idiomas | VRAM estimada (ctx 4K) | Calidad general |
|--------|--------|-------------|-----------------|------------|---------|----------------------|-----------------|
| **Qwen3.5-0.8B** | 0.8B | ~0.6 GB | 262K | SI (vision+texto) | 200+ | ~0.8 GB | Basica — OCR, clasificacion, respuestas cortas |
| **Qwen3.5-2B** | 2B | **1.28 GB** | 262K | SI (vision+texto) | 200+ | **~1.6 GB** | **Buena — razonamiento, agentes, coding basico** |
| **Gemma 3 1B** | 1B | 0.8 GB | 32K | NO (solo texto) | Limitado | ~1.0 GB | Decente en texto, sin vision |
| **SmolLM3-3B** | 3B | 1.92 GB | 128K | NO (solo texto) | Limitado | ~2.3 GB | Excelente calidad texto, pero sin vision y se pasa de 2 GB |
| **Phi-4-mini** | 3.8B | ~2.3 GB | 128K | NO (solo texto) | Limitado | ~2.8 GB | Mejor razonamiento/GB, pero se pasa de 2 GB y sin vision |
| **Qwen3.5-4B** | 4B | ~2.5 GB | 262K | SI (vision+texto) | 200+ | ~3.0 GB | Excelente, pero se pasa del limite de 2 GB |

### La eleccion: Qwen3.5-2B Q4_K_M

**Ganador claro: Qwen3.5-2B**

Razones:

1. **1.28 GB en disco, ~1.6 GB en VRAM con contexto 4K** — cabe dentro de tu limite de 2 GB y te deja >10 GB para gaming
2. **Multimodal nativo (vision + texto)** — puede analizar screenshots, OCR, imagenes sin necesitar modelo aparte. Esto es CRITICO para el filtro de privacidad
3. **262K tokens de contexto nativo** — aunque lo limitemos a 4-8K para eficiencia, tiene capacidad para mas si se necesita
4. **200+ idiomas** — español nativo, ideal para tu uso
5. **2x la calidad del 0.8B actual** — el salto de 0.8B a 2B es enorme en calidad: +34 puntos en tareas de agente, significativamente mejor en razonamiento y coding
6. **Misma familia Qwen3.5** — compatible con tu setup actual de llama-server sin cambios de arquitectura
7. **Thinking mode** — puede activar razonamiento profundo (/think) cuando la tarea lo requiere, o modo rapido (/no_think) para clasificacion
8. **Funciona bien en CPU** — en laptops sin GPU, 2B en Q4 corre a 15-25 tok/s en CPU moderno, que es usable

### Por que NO los otros

| Modelo | Razon de descarte |
|--------|------------------|
| Qwen3.5-0.8B (actual) | Demasiado basico. Funciona para OCR simple pero no puede razonar sobre si un dato es sensible ni planificar |
| Gemma 3 1B | Sin vision/multimodal. No puede analizar screenshots localmente. Contexto solo 32K |
| SmolLM3-3B | Sin vision. 1.92 GB en disco pero ~2.3 GB en VRAM con contexto — se pasa. Excelente calidad texto pero le falta multimodal |
| Phi-4-mini | Sin vision. 2.3 GB en disco, ~2.8 GB VRAM — se pasa del limite. Mejor para razonamiento puro pero no para tu caso |
| Qwen3.5-4B | Excelente modelo pero 2.5 GB en disco, ~3 GB VRAM — te come demasiada VRAM para gaming. Es la opcion si decides sacrificar algo de VRAM |

### Configuracion de contexto recomendada

El contexto consume VRAM adicional via el KV cache. Formula aproximada para modelos small:

```
VRAM total = peso del modelo + KV cache
KV cache ≈ contexto_tokens x factor_por_capa

Para Qwen3.5-2B Q4_K_M:
- Peso modelo: ~1.28 GB
- KV cache 4K tokens: ~0.15 GB
- KV cache 6K tokens: ~0.22 GB
- KV cache 8K tokens: ~0.30 GB
- KV cache 16K tokens: ~0.60 GB
```

| Contexto | VRAM total estimada | Cabe en 2 GB? | Recomendacion |
|----------|--------------------|----|-------------|
| 2,048 tokens | ~1.36 GB | SI | Minimo funcional. Suficiente para clasificacion y respuestas cortas |
| **4,096 tokens** | **~1.43 GB** | **SI** | **Recomendado por defecto.** Buen balance para la mayoria de tareas del guardian |
| **6,144 tokens** | **~1.50 GB** | **SI** | **Optimo.** Suficiente para analizar un screenshot con contexto + decidir routing |
| 8,192 tokens | ~1.58 GB | SI | Bueno si necesitas mas contexto para tareas de privacidad complejas |
| 16,384 tokens | ~1.88 GB | JUSTO | Posible pero apretado. Solo si necesitas analizar documentos largos localmente |
| 32,768 tokens | ~2.48 GB | NO | Se pasa. No usar como default |

**Configuracion recomendada para llama-server:**

```
LIFEOS_AI_MODEL=Qwen3.5-2B-Q4_K_M.gguf
LIFEOS_AI_CTX_SIZE=6144
LIFEOS_AI_THREADS=4
LIFEOS_AI_GPU_LAYERS=99
```

Esto consume ~1.5 GB de VRAM, dejandote ~10.5 GB libres para gaming.

### Que puede hacer Qwen3.5-2B como guardian de privacidad

| Tarea | Capacidad | Ejemplo |
|-------|-----------|---------|
| Clasificar sensibilidad de texto | Buena | "Este texto contiene un password: si/no" |
| Analizar screenshot localmente | Buena (vision nativa) | "Que hay en esta captura? Hay datos sensibles visibles?" |
| Redactar/sanitizar datos | Aceptable | "Reemplaza emails y passwords con [REDACTED]" |
| Decidir routing | Buena | "Esta tarea requiere API externa o basta con local?" |
| Resumir para enviar a API | Aceptable | "Resume este texto en 2 oraciones sin datos personales" |
| Responder preguntas simples | Buena | "Que hora es en Tokyo?" |
| Coding basico | Limitada | Puede hacer snippets simples, no refactors complejos |
| Planning complejo | Limitada | Para esto se escala a API externa (Gemini Pro, DeepSeek R1) |

### Para equipos sin GPU (futuro)

En CPU solamente, Qwen3.5-2B Q4_K_M corre a:

| CPU | Tokens/seg estimados | Usable? |
|-----|---------------------|---------|
| i9-13900HX (tu CPU) | 30-50 tok/s | Excelente |
| i7 reciente (laptop media) | 20-30 tok/s | Bueno |
| i5 reciente (laptop basica) | 12-20 tok/s | Aceptable |
| Ryzen 5/7 reciente | 15-25 tok/s | Bueno |
| CPU viejo (pre-2020) | 5-10 tok/s | Lento pero funcional |

Incluso en el peor caso (CPU viejo), 5-10 tok/s es suficiente para:
- Clasificar si un dato es sensible (respuesta de 10-20 tokens = 1-4 segundos)
- Decidir routing (respuesta rapida)
- Tareas de filtrado

No es suficiente para chat fluido, pero ESO lo harian las APIs externas para tareas no sensibles.

### Migracion desde Qwen3.5-0.8B a 2B

El cambio es minimo porque ambos son de la misma familia:

1. Descargar `Qwen3.5-2B-Q4_K_M.gguf` (~1.28 GB) de [Hugging Face](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF)
2. Colocarlo en `/var/lib/lifeos/models/`
3. Actualizar `LIFEOS_AI_MODEL` en `/etc/lifeos/llama-server.env`
4. Reiniciar llama-server
5. El mmproj (para vision multimodal) tambien necesita descargarse si no existe

No hay cambios en la API — llama-server sigue exponiendo el mismo endpoint OpenAI-compatible en `:8082`.

### Opcion alternativa: Qwen3.5-4B (si decides sacrificar VRAM)

Si en algun momento decides que necesitas mas calidad local y puedes sacrificar ~1 GB mas de VRAM (dejando ~9 GB para gaming):

- Qwen3.5-4B Q4_K_M: ~2.5 GB en disco, ~3 GB VRAM con 6K contexto
- Calidad dramaticamente mejor: +23 puntos en agentes, +32 en contexto largo vs 2B
- Rinde como modelos de 80B de la generacion anterior en muchas tareas
- Es el "sweet spot" si el gaming no requiere los 10 GB completos

Pero para el default de LifeOS que debe correr en CUALQUIER hardware, **Qwen3.5-2B es la eleccion correcta.**

### Resumen de la decision

| Aspecto | Decision |
|---------|----------|
| Modelo local por defecto | **Qwen3.5-2B Q4_K_M** |
| Tamaño en disco | 1.28 GB |
| VRAM con 6K contexto | ~1.5 GB |
| Contexto por defecto | 6,144 tokens |
| Multimodal | SI (vision + texto) |
| Rol principal | Guardian de privacidad + worker rapido + fallback offline |
| Modelo alternativo potente | Qwen3.5-4B Q4_K_M (~2.5 GB, si hay VRAM disponible) |
| Compatible con tu gaming | SI — deja >10 GB VRAM libres |
| Compatible con PCs sin GPU | SI — corre a 12-50 tok/s en CPU |

---

## Fuentes

- [OpenClaw Model Providers](https://docs.openclaw.ai/concepts/model-providers)
- [Anthropic bans third-party OAuth](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/)
- [Anthropic clarifies ban](https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/)
- [OpenClaw ban wave](https://www.pcworld.com/article/3068842/whats-behind-the-openclaw-ban-wave.html)
- [Rebuilt for $15/mo after ban](https://medium.com/@rentierdigital/anthropic-just-killed-my-200-month-openclaw-setup-so-i-rebuilt-it-for-15-9cab6814c556)
- [Claude Code Terms of Service](https://autonomee.ai/blog/claude-code-terms-of-service-explained/)
- [CLIProxyAPI risks](https://rogs.me/2026/02/use-your-claude-max-subscription-as-an-api-with-cliproxyapi/)
- [Claude subscription vs API](https://support.claude.com/en/articles/9876003-i-have-a-paid-claude-subscription-pro-max-team-or-enterprise-plans-why-do-i-have-to-pay-separately-to-use-the-claude-api-and-console)
- [OpenAI Terms of Use](https://openai.com/policies/row-terms-of-use/)
- [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [Gemini API free tier guide](https://blog.laozhang.ai/en/posts/gemini-api-free-tier)
- [Gemini rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- [Cheapest LLM APIs 2026](https://www.tldl.io/resources/cheapest-llm-api-2026)
- [LLM API pricing comparison](https://www.tldl.io/resources/llm-api-pricing-2026)
- [DeepSeek API pricing](https://api-docs.deepseek.com/quick_start/pricing)
- [Kimi K2.5 pricing](https://openrouter.ai/moonshotai/kimi-k2.5)
- [MiniMax M2.5 pricing](https://www.verdent.ai/guides/minimax-m2-5-pricing)
- [GLM pricing](https://open.bigmodel.cn/pricing)
- [GLM Coding Plan $3/mo](https://vibecoding.app/blog/zhipu-ai-glm-coding-plan-review)
- [OpenRouter pricing](https://openrouter.ai/pricing)
- [OpenRouter free models](https://costgoat.com/pricing/openrouter-free-models)
- [Together AI pricing](https://www.together.ai/pricing)
- [Hidden Risks of Chinese LLMs - Illuminis Labs](https://www.illuminislabs.com/post/illuminis-labs-unmasking-the-hidden-risks-of-chinese-llms-in-critical-infrastructure)
- [Privacy Pitfalls: DeepSeek and Qwen](https://www.thefirewall-blog.com/2025/03/privacy-pitfalls-in-ai-a-closer-look-at-deepseek-and-qwen/)
- [Chinese AI Models and AI Neutrality - CIGI](https://www.cigionline.org/articles/chinese-ai-models-and-the-high-stakes-fight-for-ai-neutrality/)
- [Chinese AI coding tool security risks](https://securitybrief.com.au/story/chinese-ai-coding-tool-deepens-security-risk-on-sensitive-triggers)
- [LLM Data Privacy Enterprise Guide](https://www.lasso.security/blog/llm-data-privacy)
- [GLM-4.7 Overview](https://docs.z.ai/guides/llm/glm-4.7)
- [Qwen3.5 2B GGUF - Hugging Face](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF)
- [Qwen3.5 0.8B GGUF - Hugging Face](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF)
- [Qwen3.5 GGUF Benchmarks - Unsloth](https://unsloth.ai/docs/models/qwen3.5/gguf-benchmarks)
- [Qwen3.5 Complete Guide](https://techie007.substack.com/p/qwen-35-the-complete-guide-benchmarks)
- [Qwen3.5 Models Compared: 0.8B vs 2B vs 4B vs 9B](https://sonusahani.com/blogs/qwen-08b-vs-2b-vs-4b-vs-9b)
- [Qwen3.5 Small Models - Artificial Analysis](https://artificialanalysis.ai/articles/qwen3-5-small-models)
- [Best Small Language Models March 2026](https://localaimaster.com/blog/small-language-models-guide-2026)
- [Best Open-Source SLMs 2026 - BentoML](https://www.bentoml.com/blog/the-best-open-source-small-language-models)
- [SmolLM3-3B GGUF - Hugging Face](https://huggingface.co/ggml-org/SmolLM3-3B-GGUF)
- [Gemma 3 1B GGUF - Hugging Face](https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF)
- [GGUF VRAM Formula - oobabooga](https://oobabooga.github.io/blog/posts/gguf-vram-formula/)
- [llama.cpp VRAM Requirements 2026](https://localllm.in/blog/llamacpp-vram-requirements-for-local-llms)
- [Best Local LLM Models 2026 - SitePoint](https://www.sitepoint.com/best-local-llm-models-2026/)
- [Local LLM Inference Guide 2026](https://blog.starmorph.com/blog/local-llm-inference-tools-guide)
