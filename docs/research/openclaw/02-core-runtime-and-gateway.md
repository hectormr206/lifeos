# 02 - Core Runtime And Gateway

## Tesis

El verdadero corazon de OpenClaw es el Gateway. Todo lo demas gira alrededor de el.

No es solo "un websocket server". Es el control plane unico que:

- mantiene las conexiones con canales
- recibe clientes operador
- recibe nodos de dispositivos
- expone metodos tipados
- empuja eventos en streaming
- sirve superficies web y canvas

## Entry points importantes

### `src/index.ts`

Cumple dos roles:

- si corre como entrypoint, instala handlers globales de error y arranca el CLI legado
- si se importa como libreria, exporta un facade de funciones utiles sin levantar el runtime entero

Idea importante:

- OpenClaw cuida el caso `CLI as binary`
- y tambien el caso `OpenClaw as library`

### `src/entry.ts`

Aqui se ve un proyecto maduro:

- normaliza `argv`
- aplica perfiles del CLI
- usa fast paths para `--help` y `--version`
- instala compile cache
- prepara respawn del CLI cuando hace falta
- evita side effects si el modulo fue importado y no ejecutado como main

Esto reduce tiempo de arranque y evita comportamientos duplicados o extraños.

### `src/library.ts`

Este archivo confirma otro patron fuerte: lazy loading.

OpenClaw no quiere pagar el costo completo del runtime cuando solo necesita una parte.
Por eso exporta funciones que cargan modulos pesados bajo demanda:

- prompt helpers
- binaries helpers
- exec runtime
- WhatsApp runtime

## Arquitectura del Gateway

La doc `docs/concepts/architecture.md` lo resume muy bien:

- un Gateway de larga vida por host
- clientes operador por WebSocket
- nodos por el mismo WebSocket, pero con `role: node`
- WebChat y Control UI usando el mismo control plane
- canvas host servido por el mismo proceso HTTP

### Por que esta decision importa

Muchos proyectos tienen varias mini-APIs, varios puentes y varias sesiones inconsistentes.
OpenClaw evita eso con una sola espina dorsal:

- un protocolo
- un auth model
- un sistema de eventos
- un lugar para la verdad del estado

## Gateway protocol

Los docs `docs/gateway/protocol.md` y `docs/concepts/architecture.md` muestran una capa muy trabajada.

### Handshake

El primer frame no puede ser cualquier cosa. Debe ser `connect`.

Antes de eso, el gateway manda un `connect.challenge` con nonce.
Luego el cliente responde con:

- version minima y maxima del protocolo
- metadata de cliente
- `role`
- `scopes`
- `caps`
- `commands`
- `permissions`
- auth token
- identidad de dispositivo
- firma sobre el nonce

### Consecuencia

No estan improvisando autenticacion por socket.
Ya hay:

- challenge/response
- device identity
- device token
- versioning del protocolo
- detalle de errores para recovery

## Roles y scopes

El protocolo separa dos grandes familias:

- `operator`
- `node`

Y encima agrega scopes para hacer auth mas fino:

- `operator.read`
- `operator.write`
- `operator.admin`
- `operator.approvals`
- `operator.pairing`

Esto le permite al producto tener clients con privilegios diferentes sin inventar un segundo sistema de permisos por superficie.

## Que resuelve el Gateway en la practica

Mirando `src/gateway/` se ve que el Gateway no es una sola clase central, sino un conjunto de subsistemas:

- auth y rate limits
- chat attachments y sanitizacion
- control UI
- pairing y device auth
- exec approvals
- openai/openresponses HTTP compatibility
- node registry
- model pricing cache
- methods list y method scopes
- server WS y server HTTP

Hay mucha especializacion, lo que indica que el producto ya choco con muchos edge cases reales.

## Invariantes mas importantes

De la documentacion y el codigo se desprenden varias reglas de diseño:

- un solo gateway controla una sesion real de canal por host
- el handshake es obligatorio
- las operaciones con side effects usan idempotency
- el protocolo esta tipado con schemas
- los nodos no son sockets "magicos"; se conectan con identidad, claims y pairing

## `src/gateway/boot.ts`

Este archivo es pequeno pero revela filosofia de producto:

- si existe `BOOT.md` en el workspace, el agente lo ejecuta una vez como boot check
- crea una sesion temporal
- restaura el mapping principal al terminar
- si BOOT pide enviar mensajes, usa el `message tool`

Interpretacion:

- OpenClaw piensa el primer uso y la operacion continua como parte del sistema
- no solo arranca un modelo; arranca un operador asistido

## Que hace que esta capa no se rompa tan facil

- Protocolo explicito y versionado.
- Roles y scopes en el handshake, no despues.
- Device auth con challenge nonce.
- Lazy loading para no cargar todo en cada ejecucion.
- Fast paths de CLI para bajar latencia y complejidad.
- HTTP y WS en el mismo control plane, no en sistemas paralelos.
- Muchas pruebas especificas en `src/gateway/*.test.ts`.

## Conclusiones

OpenClaw funciona como producto serio porque el Gateway ya no es un experimento.
Es una plataforma de control unificada, con auth, pairing, typing, streaming y superficies web/native alrededor del mismo protocolo.
