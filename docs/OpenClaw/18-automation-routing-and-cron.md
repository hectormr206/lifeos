# 18 - Automation, Routing, And Cron

## Tesis

OpenClaw no solo responde mensajes.
Tambien enruta, deduplica, serializa, agenda y entrega respuestas en varios canales sin mezclar sesiones por accidente.

## Routing determinista, no heuristico

`src/routing/resolve-route.ts` y la doc `docs/channels/channel-routing.md` dejan clara una decision muy buena:

- el modelo no elige a donde responder
- el host resuelve routing de manera determinista

La prioridad de match incluye cosas como:

- peer exacto
- parent peer
- guild + roles
- guild
- team
- account
- channel
- fallback default

Eso evita una clase entera de bugs donde la conversacion "cae" en el agente equivocado.

## Session keys como contrato de aislamiento

`src/routing/session-key.ts` es uno de los archivos mas importantes para entender OpenClaw.

No solo normaliza nombres.
Tambien define la forma en que se aisla contexto y concurrencia:

- `agent:<agentId>:main`
- `agent:<agentId>:<channel>:group:<id>`
- DMs segun `dmScope`
- threads como extensiones del bucket base

Hay varias politicas de DM:

- `main`
- `per-peer`
- `per-channel-peer`
- `per-account-channel-peer`

Y ademas existe `identityLinks` para colapsar identidades relacionadas.

Esto es una de las bases mas fuertes del sistema.

## Pipeline de auto-reply antes del modelo

`src/auto-reply/reply/get-reply.ts` muestra que hay bastante trabajo antes de ejecutar el turno del agente.

El pipeline incluye:

- cargar config efectiva
- resolver agente segun `sessionKey`
- combinar filtros de skills
- asegurar workspace
- resolver modelo por defaults y overrides
- enriquecer con media understanding y link understanding
- correr hooks de preprocess
- validar autorizacion de comandos
- inicializar o resolver estado de sesion

O sea:

- la respuesta no arranca desde cero
- arranca desde una capa de preprocesamiento y policy

## Dedupe y dispatcher para no correr dos veces lo mismo

`src/auto-reply/reply/inbound-dedupe.ts` usa una cache global para marcar mensajes entrantes ya procesados.

La llave no es naive.
Incluye:

- provider
- account
- sesion/agent scope
- peer
- thread
- `messageId`

Eso ayuda a que un mismo inbound no se procese dos veces aunque entre por caminos parecidos.

Encima, `src/auto-reply/dispatch.ts` garantiza cleanup del dispatcher aun si la corrida sale por un error.

## Queue, followups y steering

`src/auto-reply/reply/agent-runner.ts` y `queue-policy.ts` muestran otra parte muy madura del sistema.

Cuando ya hay una corrida activa, OpenClaw no hace siempre lo mismo.
Puede:

- correr ahora
- encolar followup
- descartar heartbeats redundantes
- hacer steering de una corrida streaming existente

Ese comportamiento depende de:

- si ya hay una run activa
- si el mensaje es heartbeat
- si la policy de queue es `steer`
- si la accion debe convertirse en followup

Eso evita mezclar respuestas y reduce carreras absurdas.

## Entrega de respuestas pensada para texto, media y streaming

`src/auto-reply/reply/reply-delivery.ts` deja ver una capa bastante refinada:

- parsea directives incrustadas
- normaliza `replyTo`
- soporta block replies
- entrega media en el momento correcto
- deja que el texto final y los bloques parciales convivan sin duplicarse

Este tipo de detalles suele aparecer solo cuando un producto ya choco con:

- replies vacios
- media que se pierde si esperas al final
- streaming duplicado
- threading inconsistente

## Channel setup como automation productizada

`src/flows/channel-setup.ts` es una pieza interesante porque mezcla onboarding con plugins.

El flujo:

- lista canales core y externos
- consulta status por canal
- instala plugins de setup cuando hacen falta
- usa adapters de wizard por plugin
- ejecuta post-write hooks despues de persistir config

Esto convierte el alta de canales en una surface automatizable, no en una coleccion de pasos manuales dispersos.

## Cron service con restricciones explicitas

`src/cron/service.ts`, `src/cron/service/jobs.ts` y `src/cron/service/store.ts` muestran otra capa seria de automatizacion.

Patrones importantes:

- store persistido y normalizado al cargar
- recomputo de `nextRunAt`
- stagger estable por `jobId`
- restricciones entre `sessionTarget` y `payload.kind`
- validacion de destinos de entrega
- soporte para webhook o canal segun el caso

Hay una idea muy fuerte ahi:

- no todo job puede correr en cualquier target
- y no todo delivery es valido para cualquier tipo de sesion

Eso evita que cron termine rompiendo invariantes del chat normal.

## `isolated-agent` como pista de madurez

La cantidad de archivos y tests bajo `src/cron/isolated-agent/` muestra que OpenClaw ya tuvo que resolver cron serio sobre agentes:

- session keys dedicadas
- model selection especifica
- delivery targets
- retries intermedios
- skill filters
- preservation de sandbox config
- followups de subagentes

Eso ya va mucho mas alla de un `setInterval(() => askModel())`.

## Que patrones explican que no se rompa esta capa

- routing determinista y cacheado
- session keys como contrato estable
- dedupe por mensaje/peer/thread/scope
- dispatcher con cleanup garantizado
- queue policy con followup y steering
- delivery separado de generacion
- cron con validaciones de target y store persistido

## Archivos mas importantes

- `../openclaw-main/docs/channels/channel-routing.md`
- `../openclaw-main/src/routing/resolve-route.ts`
- `../openclaw-main/src/routing/session-key.ts`
- `../openclaw-main/src/auto-reply/reply/get-reply.ts`
- `../openclaw-main/src/auto-reply/reply/agent-runner.ts`
- `../openclaw-main/src/auto-reply/reply/queue-policy.ts`
- `../openclaw-main/src/auto-reply/reply/reply-delivery.ts`
- `../openclaw-main/src/auto-reply/reply/inbound-dedupe.ts`
- `../openclaw-main/src/auto-reply/dispatch.ts`
- `../openclaw-main/src/flows/channel-setup.ts`
- `../openclaw-main/src/flows/provider-flow.ts`
- `../openclaw-main/src/cron/service.ts`
- `../openclaw-main/src/cron/service/jobs.ts`
- `../openclaw-main/src/cron/service/store.ts`
- `../openclaw-main/src/cron/isolated-agent/run.ts`

## Conclusion

OpenClaw logra automatizar bastante sin volverse impredecible porque separa muy bien:

- quien debe responder
- en que sesion debe caer
- como se evita duplicar trabajo
- cuando conviene encolar en vez de correr ya
- y que tipos de jobs o deliveries estan permitidos

Eso es exactamente el tipo de infraestructura que hace que un asistente multi-canal siga pareciendo coherente cuando deja de ser un juguete.

