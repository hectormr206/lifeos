# 21 - Session Durability And Storage Governance

## Tesis

Otra capa que sí merecia un documento propio es la de sesiones y almacenamiento.

OpenClaw no trata las conversaciones como memoria volatil de proceso.
Las trata como datos durables con:

- rutas por agente
- transcripts persistidos
- mantenimiento
- presupuestos de disco
- eventos de cambio
- compatibilidad con estados viejos

## Las sesiones viven por agente

`src/config/sessions/paths.ts` deja clara una decision de producto importante:

- cada agente tiene su propio directorio de sesiones
- el store principal vive en `agents/<agentId>/sessions/sessions.json`
- los transcripts viven al lado

No es solo orden cosmetico.
Eso ayuda con:

- aislamiento por agente
- recovery por agente
- debugging por agente
- mantenimiento dirigido

## Path safety y compatibilidad al mismo tiempo

El mismo archivo `paths.ts` hace varias cosas buenas a la vez:

- valida `sessionId`
- resuelve rutas absolutas y relativas
- mantiene containment dentro del arbol de sesiones
- intenta compatibilidad con rutas absolutas viejas

Eso revela un patrón muy OpenClaw:

- no romper backward compatibility gratis
- pero tampoco aceptar cualquier path fuera de control

## `store.ts` es una pieza mucho mas importante de lo que parece

`src/config/sessions/store.ts` no es solo lectura/escritura de JSON.
Ahí aparece una mini-plataforma de durabilidad:

- locks de escritura
- normalizacion de session keys
- normalizacion de delivery/runtime fields
- caches serializados
- migraciones de store
- mantenimiento y cap de entradas
- enforcement de presupuesto de disco

Y hay otro detalle fino:

- en Windows reintenta lecturas cuando puede ver un archivo vacio o intermedio durante rename/write

Eso ya habla de experiencia real con filesystem y concurrencia.

## Atomicidad operativa y write locks

La presencia de `acquireSessionWriteLock` y escritura atomica revela que OpenClaw no quiere:

- sesiones corruptas por dos escritores
- stores truncados a mitad de update
- lecturas inconsistentes durante mantenimiento

No vi solo "guardamos JSON".
Vi una capa que intenta sobrevivir a procesos concurrentes y plataformas imperfectas.

## Mantenimiento explicito de sesiones

`src/config/sessions/store-maintenance.ts` define varias reglas de higiene:

- `pruneAfter`
- `maxEntries`
- `rotateBytes`
- `resetArchiveRetention`
- `maxDiskBytes`
- `highWaterBytes`

Tambien calcula warnings si la sesion activa seria la que tocaria podar o capar.

Eso es muy importante:

- no solo limpian
- intentan no destruir justo la sesion viva

## Presupuesto de disco como politica real

`src/config/sessions/disk-budget.ts` fue una de las mayores señales nuevas de madurez.

No solo mide el store.
Hace sweep sobre:

- `sessions.json`
- transcripts
- artefactos archivados
- referencias reales desde el store

Y usa conceptos como:

- `maxBytes`
- `highWaterBytes`
- `totalBefore/After`
- archivos removidos
- bytes liberados

Eso indica que OpenClaw ya tuvo que pensar en crecimiento largo y no solo en conversaciones de una tarde.

## Artefactos y archivos archivados

`src/config/sessions/artifacts.ts` define una nomenclatura bien clara para archivos archivados:

- `.bak`
- `.reset`
- `.deleted`

Tambien distingue:

- transcript principal
- transcript archivado
- transcript que aun cuenta para usage

Esto importa porque permite:

- recovery
- accounting
- mantenimiento menos ciego

## Transcripts como primera clase

`src/config/sessions/transcript.ts` muestra que el transcript no es un residuo secundario.
Es una parte integrada del sistema.

La capa hace cosas como:

- resolver o persistir `sessionFile`
- garantizar header del transcript
- espejar respuestas assistant hacia el transcript
- usar `idempotencyKey` para no duplicar mensajes
- emitir eventos de update

Y `src/sessions/transcript-events.ts` vuelve esos cambios observables para otras superficies.
Tambien aparecen piezas complementarias como:

- `session-lifecycle-events.ts`
- `input-provenance.ts`
- `targets.ts`

Eso ayuda a:

- UI
- Gateway
- herramientas de estado
- sync entre procesos
- discovery de stores multi-agent

## Delivery context y continuidad

`store.ts` tambien normaliza `deliveryContext`, `lastChannel`, `lastTo`, `lastAccountId`, `threadId`.

Este detalle es importante porque une dos mundos:

- la memoria conversacional
- y la forma concreta de volver a entregar respuestas al lugar correcto

En OpenClaw, la sesion no guarda solo texto.
Tambien guarda suficiente contexto operacional para seguir siendo util.

## Que agrega esta capa a la imagen general

Antes ya teniamos documentado:

- routing
- compaction
- followups

Pero faltaba remarcar otra verdad:

- OpenClaw tambien funciona porque las sesiones persisten como subsistema de storage relativamente bien gobernado

No es solo "tenemos historial".
Es:

- historial durable
- rutas seguras
- mantenimiento
- archivado
- presupuesto de disco
- eventos de transcript

## Archivos mas importantes

- `../openclaw-main/src/config/sessions/paths.ts`
- `../openclaw-main/src/config/sessions/store.ts`
- `../openclaw-main/src/config/sessions/store-read.ts`
- `../openclaw-main/src/config/sessions/store-maintenance.ts`
- `../openclaw-main/src/config/sessions/disk-budget.ts`
- `../openclaw-main/src/config/sessions/artifacts.ts`
- `../openclaw-main/src/config/sessions/transcript.ts`
- `../openclaw-main/src/config/sessions/session-file.ts`
- `../openclaw-main/src/config/sessions/targets.ts`
- `../openclaw-main/src/sessions/transcript-events.ts`
- `../openclaw-main/src/sessions/session-lifecycle-events.ts`
- `../openclaw-main/src/sessions/input-provenance.ts`
- `../openclaw-main/src/sessions/session-key-utils.ts`

## Conclusion

La pasada extra confirma que la persistencia de sesiones en OpenClaw no es improvisada.

Hay una mezcla bastante madura de:

- durabilidad
- path safety
- mantenimiento
- presupuesto de disco
- y compatibilidad con estados viejos

Eso ayuda mucho a explicar por que el sistema aguanta mejor el uso prolongado y no solo sesiones cortas de prueba.
