# 13 - Gateway Control Plane Deep Dive

## Tesis

El documento `02` explica por que el Gateway es el corazon de OpenClaw.
Este documento baja un nivel mas: como esta construido para aguantar clientes reales, nodos moviles, UIs y operaciones peligrosas sin convertirse en caos.

## Un solo proceso, muchas superficies

`src/gateway/server-http.ts` deja ver una decision arquitectonica muy fuerte:

- HTTP y WebSocket viven en el mismo servidor
- el mismo puerto sirve Control UI, canvas, A2UI y endpoints API
- el mismo proceso hace `upgrade` a WebSocket para operadores y nodos
- las rutas de plugins y hooks cuelgan del mismo control plane

Consecuencia:

- no hay dos planos de control paralelos
- auth, origin checks y estado viven en un solo lugar
- web, CLI, macOS, iOS y nodos hablan con la misma fuente de verdad

## Handshake fail-closed

Los archivos `src/gateway/server/ws-connection.ts` y `src/gateway/server/ws-connection/message-handler.ts` muestran que OpenClaw no confia en un socket solo por estar abierto.

El flujo real es:

1. el servidor manda `connect.challenge`
2. el primer frame del cliente debe ser `req/connect`
3. se valida version de protocolo, rol, scopes, origin y auth
4. se valida identidad del dispositivo y firma sobre el nonce
5. solo entonces se acepta la sesion

Tambien aparecen varios guardrails operativos:

- timeout de handshake
- limite de payload
- presupuesto de sockets pre-auth por IP
- cierre duro si el primer frame no es `connect`
- rechazo de `connect` tardio despues del handshake

Esto no es un detalle menor. Es la diferencia entre un WS de demo y un WS expuesto a clientes reales.

## Auth por capas, no por una sola credencial

La capa de auth esta repartida entre varios archivos porque realmente resuelve varios problemas distintos:

- `src/gateway/auth.ts`: modos `none`, `token`, `password`, `trusted-proxy` y escenarios Tailscale
- `src/gateway/server/ws-connection/auth-context.ts`: decide si la sesion entra por auth compartida, bootstrap token o device token
- `src/gateway/device-auth.ts`: define payloads firmados y versionados
- `src/gateway/server/ws-connection/connect-policy.ts`: aplica pairing y reglas segun rol/superficie

El patron importante es este:

- gateway auth protege el acceso general
- device auth protege la identidad del cliente concreto
- pairing protege confianza persistente
- la firma del nonce evita reusar handshake material sin prueba de posesion

## Pairing unido a metadatos reales

OpenClaw no solo aprueba un `deviceId`.
Tambien amarra la confianza a metadatos del dispositivo.

Por eso detecta cambios como:

- plataforma
- `deviceFamily`
- rol
- scopes

Si esos metadatos cambian, el sistema puede exigir re-pair.
Eso evita que una aprobacion vieja se convierta en acceso silencioso para un cliente distinto o mas privilegiado.

## Roles, scopes y metodos centralizados

`src/gateway/server-methods-list.ts`, `src/gateway/method-scopes.ts`, `src/gateway/role-policy.ts` y `src/gateway/server-methods.ts` muestran otra decision muy madura:

- el inventario de metodos esta centralizado
- cada metodo se clasifica por scope
- operadores y nodos comparten bus, pero no privilegios
- los handlers no cargan con toda la autorizacion por su cuenta

Esto reduce mucho el riesgo de:

- agregar un metodo nuevo sin policy clara
- dejar una ruta sensible accesible por accidente
- duplicar logica de seguridad en varios handlers

La filosofia es bastante clara:

- metodo no clasificado, metodo sospechoso
- scope vacio por defecto
- side effects sensibles con controles extra

## Event bus pensado para UIs de verdad

`src/gateway/server-broadcast.ts` y `src/gateway/server-chat.ts` muestran que OpenClaw ya resolvio problemas de streaming y sincronizacion que suelen romper UIs en sistemas jovenes.

Patrones importantes:

- eventos con `seq`
- `stateVersion`
- snapshots iniciales
- suscriptores por sesion y por run
- `dropIfSlow` para no dejar que un cliente lento ahogue al servidor
- cierre de slow consumers cuando hace falta
- flush final para no perder el ultimo estado visible

Eso explica por que el mismo Gateway puede alimentar:

- Control UI
- apps nativas
- CLI
- ACP bridge

sin reimplementar la semantica de eventos en cada cliente.

## Nodos, wake y pending invoke

La dupla `src/gateway/node-registry.ts` y `src/gateway/server-methods/nodes.ts` es especialmente reveladora.

OpenClaw asume que los nodos no siempre estan disponibles de forma ideal.
Por eso el sistema:

- mantiene un registro de nodos conectados
- enruta `node.invoke.request`
- intenta wake remoto cuando el nodo no esta listo
- mantiene trabajos pendientes para foreground execution en iOS
- deduplica acciones por `idempotencyKey`

Esa parte ya esta pensada para dispositivos moviles reales, no solo para un daemon local perfecto.

## Aprobaciones de ejecucion con control de concurrencia

`src/gateway/server-methods/exec-approvals.ts`, `src/gateway/exec-approval-manager.ts` y `src/gateway/node-invoke-system-run-approval.ts` forman una mini-plataforma de safety.

Lo importante:

- las aprobaciones persistentes usan `baseHash`
- hay soporte de `allow-once`
- existen expiraciones y limpieza
- los awaiters tardios se resuelven correctamente
- no se acepta cualquier payload del cliente como si ya estuviera aprobado

La logica canonica reconstruye y compara:

- `argv`
- `cwd`
- `agentId`
- `sessionKey`
- `runId`
- nodo y dispositivo destino

Eso cierra un monton de agujeros de "approval laundering" entre UI, Gateway y nodo.

## Control UI endurecida

`src/gateway/control-ui.ts`, `src/gateway/control-ui-csp.ts` y los origin checks dentro de `server-http.ts` muestran que la web local no esta tratada como interfaz confiable por defecto.

Se ve:

- CSP fuerte
- origins permitidos calculados
- reglas especiales y acotadas para browser pairing
- rutas y recursos estaticos servidos desde el propio Gateway

En otras palabras:

- la UI no se monta al costado del sistema
- se integra dentro de la politica de seguridad del control plane

## Que patrones explican que no se rompa tanto

- un solo control plane para HTTP, WS, UI y nodos
- handshake fail-closed con nonce y versionado
- auth multi-capa en vez de un token unico
- pairing ligado a metadatos, no solo a IDs
- event bus con semantica explicita para clientes lentos y resync
- `node.invoke` pensado para wake, offline y moviles
- aprobaciones sensibles con control de concurrencia y revalidacion canonica

## Archivos mas importantes

- `../openclaw-main/src/gateway/server-http.ts`
- `../openclaw-main/src/gateway/server/ws-connection.ts`
- `../openclaw-main/src/gateway/server/ws-connection/message-handler.ts`
- `../openclaw-main/src/gateway/server/ws-connection/auth-context.ts`
- `../openclaw-main/src/gateway/server/ws-connection/connect-policy.ts`
- `../openclaw-main/src/gateway/auth.ts`
- `../openclaw-main/src/gateway/device-auth.ts`
- `../openclaw-main/src/gateway/server-methods.ts`
- `../openclaw-main/src/gateway/server-methods-list.ts`
- `../openclaw-main/src/gateway/node-registry.ts`
- `../openclaw-main/src/gateway/server-methods/nodes.ts`
- `../openclaw-main/src/gateway/server-broadcast.ts`
- `../openclaw-main/src/gateway/server-chat.ts`
- `../openclaw-main/src/gateway/server-methods/exec-approvals.ts`
- `../openclaw-main/src/gateway/exec-approval-manager.ts`
- `../openclaw-main/src/gateway/control-ui.ts`

## Conclusion

Lo mas notable del Gateway no es que tenga muchas features.
Es que ya parece una pieza de infraestructura.

OpenClaw aguanta mejor que la media porque su plano de control fue programado como sistema distribuido pequeno:

- clientes con roles distintos
- dispositivos con confianza persistente
- eventos que pueden llegar lento
- operaciones sensibles que necesitan aprobacion
- nodos que a veces duermen, despiertan o cambian de contexto

