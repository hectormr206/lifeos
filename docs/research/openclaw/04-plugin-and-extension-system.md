# 04 - Plugin And Extension System

## Tesis

OpenClaw crecio sin romperse tanto porque no metio todas las integraciones dentro del core.

La apuesta central fue esta:

- el core define contratos
- las extensiones poseen implementaciones
- el SDK define las fronteras

## Dos formatos de plugin

La doc `docs/tools/plugin.md` deja claro que OpenClaw soporta:

- plugins nativos (`openclaw.plugin.json` + runtime module)
- bundles compatibles con layouts de otros agentes

Pero el modelo fuerte es el plugin nativo.

## Pipeline interno del sistema de plugins

La doc `docs/plugins/architecture.md` explica cuatro capas:

1. manifest + discovery
2. enablement + validation
3. runtime loading
4. consumo por el resto del sistema

Es una separacion muy buena porque permite:

- descubrir y validar sin ejecutar codigo arbitrario al inicio
- explicar por que un plugin esta disabled, missing o invalid
- cargar comportamiento solo cuando realmente se necesita

## Discovery y precedencia

OpenClaw descubre plugins en este orden:

1. `plugins.load.paths`
2. extensiones del workspace
3. extensiones globales
4. plugins bundled

Eso permite mezclar:

- producto oficial
- plugins del usuario
- desarrollo local

sin perder una regla clara de precedencia.

## Loader y registry

`../openclaw-main/src/plugins/loader.ts` muestra muchas piezas de madurez:

- `jiti` para carga in-process
- cache de registries
- alias map del SDK
- validacion de schema
- restore/clear de memory plugin state
- runtime options para binding de subagentes
- modo `full` vs `validate`
- scope a subset de plugins

Interpretacion:

- no es un `require()` simple
- es un subsistema completo para vida real

## Capability model

OpenClaw empuja una idea muy importante:

- plugin = ownership boundary
- capability = contrato del core

Ejemplos:

- `openai` puede registrar provider, speech, media understanding e image generation
- `telegram` registra un canal
- `voice-call` puede ser plugin de feature que consume speech del core

Esto evita dos problemas comunes:

- vendor logic regada por todas partes
- features acopladas a un proveedor especifico

## Ejemplo: plugin OpenAI

`extensions/openai/openclaw.plugin.json` ya describe metadata util:

- providers soportados
- cli backends
- auth env vars
- provider auth choices
- contracts adicionales

`extensions/openai/index.ts` registra varias capacidades en una sola entrada:

- CLI backend
- provider OpenAI
- provider OpenAI Codex
- speech
- media understanding
- image generation

Eso demuestra una decision de ownership clara: la superficie OpenAI vive junta.

## Ejemplo: plugin Telegram

`extensions/telegram/index.ts` usa `defineChannelPluginEntry`.

Y `extensions/telegram/src/channel.ts` concentra la complejidad especifica de Telegram:

- allowlists
- pairing
- outbound send
- thread/topic parsing
- exec approvals
- group policy
- status y monitor
- setup adapter
- setup wizard

Esto es muy importante:

- el core no contiene ramas `if (channel === telegram)` por todos lados
- el canal posee su semantica

## SDK y boundaries

En `AGENTS.md` del repo y en los docs del SDK se nota una obsesion saludable con las fronteras:

- los plugins no deben importar `src/**` del core directamente
- deben usar `openclaw/plugin-sdk/*`
- hay guardrails para no mezclar imports estaticos y dinamicos del mismo modulo
- hay checks para no cruzar paquetes con relativos peligrosos

Eso es justo lo que evita que el monorepo se vuelva inseparable.

## Slots exclusivos

OpenClaw tambien introduce slots como:

- `memory`
- `contextEngine`

Esto permite competencia controlada entre plugins:

- varios plugins pueden existir
- pero solo uno puede ocupar cierto rol exclusivo en runtime

Es un patron simple, pero muy util para crecer sin ambiguedad.

## Como evita romperse esta capa

- manifests antes de runtime
- `plugins inspect`, `plugins doctor`, `plugins list`
- config schema por plugin
- registry y cache controlados
- contract tests en `src/plugins/contracts/*`
- docs internas del SDK
- scripts que vigilan fronteras arquitectonicas

## Lo mas importante

OpenClaw pudo crecer a muchos providers, muchos canales y muchas features porque eligio una arquitectura de plugins relativamente estricta.

En vez de "agregar otra integracion al core", casi siempre:

- define un contrato
- crea o amplia el SDK
- delega ownership a una extension

Ese patron aparece una y otra vez en el repo.
