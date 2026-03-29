# 16 - ACP Control Plane And IDE Bridge

## Tesis

OpenClaw no solo sirve para hablar por chat o desde una app nativa.
Tambien se comporta como backend para clientes ACP.

Eso importa porque lo acerca mucho mas a una plataforma programable y a un backend para IDEs o agentes externos.

## `src/acp/` no es un experimento lateral

La carpeta `src/acp/` tiene demasiadas piezas para ser un puente improvisado:

- servidor
- traductor de eventos
- session manager
- runtime registry
- runtime cache
- policy
- persistent bindings
- reconciliacion de identidad
- tests especificos por stop reason, cancel, rate limit y config options

Eso ya parece un subsistema.

## El servidor ACP espera al Gateway real

`src/acp/server.ts` hace algo muy sano:

- primero resuelve config y auth
- arranca un `GatewayClient`
- espera `hello-ok`
- solo entonces acepta trafico ACP por `stdin/stdout`

Eso evita montar un bridge "a ciegas" antes de tener conectado el control plane real.

En otras palabras:

- ACP no reemplaza al Gateway
- ACP se cuelga del Gateway

## `translator.ts` como adaptador serio de protocolos

`src/acp/translator.ts` es la pieza central del bridge.

Hace varias traducciones importantes:

- sesiones ACP a sesiones del Gateway
- config options ACP a patches de sesion
- eventos del Gateway a chunks y estados ACP
- tool calls y outputs a formatos ACP
- thinking y usage a superficies compatibles con ACP

Tambien impone limites concretos, por ejemplo:

- rate limit para crear sesiones
- tamaño maximo de prompt
- restricciones cuando una opcion ACP no puede mapearse limpiamente

Eso es bueno porque evita fingir compatibilidad total cuando no existe.

## Session manager con actor queue y runtime cache

`src/acp/control-plane/manager.core.ts` es probablemente la pieza mas madura de esta capa.

Su trabajo no es solo abrir sesiones.
Tambien:

- resuelve si una sesion ACP existe, esta lista o quedo stale
- serializa trabajo por sesion con `SessionActorQueue`
- mantiene `activeTurnBySession`
- guarda estadisticas de latencia y errores
- reconcilia identidades pendientes al arrancar
- cachea runtimes por actor para no respawnear todo siempre

Patron importante:

- una sesion ACP no es solo un handle momentaneo
- es un recurso manejado por un pequeño control plane

## Runtime controls aplicados solo si el backend los soporta

`src/acp/control-plane/manager.runtime-controls.ts` y `src/acp/runtime/registry.ts` muestran otra decision muy buena:

- el backend ACP anuncia capacidades
- OpenClaw no asume que todos los backends soportan lo mismo
- solo aplica `setMode` o `setConfigOption` si el runtime lo soporta

Si no, devuelve error explicito de control no soportado.

Eso evita dos males:

- silent no-op
- compatibilidad imaginaria

## Persistent bindings

`src/acp/persistent-bindings.lifecycle.ts` es especialmente interesante porque conecta ACP con el sistema general de sesiones y routing.

La idea es:

- ciertas conversaciones pueden quedar ligadas a una sesion ACP concreta
- si la sesion ya no coincide con el binding configurado, se cierra y se recrea
- si hace falta reset in-place, se conserva la intencion configurada

Eso sugiere que ACP no se usa solo para pruebas.
Se usa como surface duradera que puede convivir con conversaciones reales.

## Policy explicita

`src/acp/policy.ts` agrega otro guardrail importante:

- ACP puede deshabilitarse por config
- el dispatch ACP puede deshabilitarse por separado
- se puede limitar que agentes estan permitidos

Es decir:

- ACP no es una puerta trasera universal
- entra dentro del modelo de policy del producto

## Que revela sobre como se programo OpenClaw

Revela varias decisiones maduras:

- preferir adaptadores explicitos entre protocolos
- mantener estado y observabilidad del bridge
- tratar backends ACP como plugins/runtimes seleccionables
- no mezclar compatibilidad parcial con compatibilidad total
- acoplar ACP al Gateway, no duplicarlo

## Archivos mas importantes

- `../openclaw-main/src/acp/server.ts`
- `../openclaw-main/src/acp/translator.ts`
- `../openclaw-main/src/acp/policy.ts`
- `../openclaw-main/src/acp/control-plane/manager.core.ts`
- `../openclaw-main/src/acp/control-plane/manager.runtime-controls.ts`
- `../openclaw-main/src/acp/control-plane/runtime-cache.ts`
- `../openclaw-main/src/acp/runtime/registry.ts`
- `../openclaw-main/src/acp/persistent-bindings.lifecycle.ts`
- `../openclaw-main/src/acp/persistent-bindings.resolve.ts`
- `../openclaw-main/src/acp/runtime/session-identity.ts`

## Conclusion

La capa ACP demuestra que OpenClaw no fue programado solo como app de chat.
Tambien fue programado como backend adaptable para otros clientes agenticos.

Y lo interesante no es solo que exista el bridge, sino que:

- espera al Gateway real
- controla sesiones y runtimes
- aplica policy
- valida capacidades del backend
- y mantiene bindings persistentes

Eso ya es mentalidad de plataforma.

