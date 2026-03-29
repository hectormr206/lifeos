# 05 - Channels, Pairing, And Routing

## Tesis

Un asistente multi-canal serio no se rompe por el modelo.
Se rompe por routing, identidad, hilos, grupos, pairing y delivery.

OpenClaw tiene mucho codigo precisamente ahi, y eso explica por que ya es util en canales reales.

## Routing determinista

La doc `docs/channels/channel-routing.md` y el archivo `src/routing/resolve-route.ts` muestran una filosofia central:

- el modelo no decide a donde contestar
- el host decide de forma determinista

El enrutamiento escoge un solo agente por mensaje usando prioridad:

1. peer exacto
2. parent peer
3. guild + roles
4. guild
5. team
6. cuenta del canal
7. canal
8. default agent

Eso evita respuestas "magicas" e inconsistentes.

## Session keys como contrato

El sistema usa `sessionKey` para aislar contexto y concurrencia.

Ejemplos de forma:

- direct message principal: `agent:<agentId>:main`
- grupo: `agent:<agentId>:<channel>:group:<id>`
- canal/hilo: claves mas especificas con `thread` o `topic`

Esto importa porque el problema real no es solo responder.
Es responder desde el contexto correcto.

## DM scope y aislamiento

OpenClaw ya encontro un problema comun en bots compartidos:

- si todos los DMs caen en el mismo contexto, se mezcla informacion de personas distintas

Por eso empuja defaults como:

- `session.dmScope: per-channel-peer`

Y documenta cuando usar scopes mas fuertes como `per-account-channel-peer`.

## Pairing como gate real

La doc `docs/channels/pairing.md` muestra dos superficies de pairing:

- DM pairing
- node pairing

### DM pairing

Si el DM policy es `pairing`:

- un remitente desconocido recibe un codigo
- su mensaje no se procesa aun
- el owner aprueba manualmente

Detalles importantes:

- codigo de 8 caracteres
- TTL de 1 hora
- maximo 3 pendientes por canal

### Implementacion

`src/pairing/pairing-store.ts` es muy revelador:

- usa filenames sanitizados
- usa JSON atomico
- usa file lock
- prunea expirados
- prunea exceso de pendientes
- soporta scoping por `accountId`

Eso es justo el tipo de detalle que evita race conditions y estados corruptos.

## Node pairing

Los nodos tambien se pairan. No son solo clientes "confiables" por defecto.

Los docs muestran:

- setup code
- bootstrap token
- pending requests
- approve/reject explicito

Entonces OpenClaw separa muy bien:

- operador humano
- dispositivo aprobado
- canal aprobado

## Canales como paquetes completos

La carpeta `extensions/telegram` es un ejemplo buenisimo:

- 194 archivos
- runtime propio
- setup entry
- tests para topics, DMs, media, approvals, polling, group policy, chunking, webhook, send, target parsing

Esto significa que Telegram no es "un adapter ligero".
Es una mini-plataforma dentro de la plataforma.

Lo mismo, en distinta escala, se repite con:

- WhatsApp
- Slack
- Discord
- Matrix
- Teams

## Mensajeria compartida, semantica por canal

Una idea arquitectonica muy buena de OpenClaw es esta:

- el core expone un `message` tool compartido
- cada plugin de canal describe sus acciones y ejecuta la semantica final

Con eso obtienen dos beneficios:

- el agente ve una superficie mas uniforme
- el canal conserva sus diferencias reales

## Mention gating y grupos

OpenClaw sabe que los grupos son peligrosos por ruido y por seguridad.
Por eso mezcla:

- allowlists
- DM policy
- group policy
- mention gating
- thread/topic routing

Esto aparece tanto en docs como en los paquetes de canal.

## Por que esta capa ayuda a que "ya funcione"

Porque aqui es donde se mueren muchos productos de bots:

- contestan en el hilo equivocado
- mezclan usuarios
- no controlan accesos
- no soportan bien grupos
- no sobreviven a semanticas distintas de cada plataforma

OpenClaw invirtio bastante en resolver justo eso.

## Conclusion

OpenClaw ya es usable en muchos canales porque:

- enruta de forma determinista
- aisla sesiones con reglas claras
- exige pairing explicito
- delega detalles de canal a plugins dueños de esa complejidad
- convierte groups/threads/accounts en conceptos de primera clase
