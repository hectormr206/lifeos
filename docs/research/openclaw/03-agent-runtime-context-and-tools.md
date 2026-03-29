# 03 - Agent Runtime, Context, And Tools

## Tesis

La segunda gran razon por la que OpenClaw ya sirve en la vida real es que el runtime del agente no es naive.

No se limita a:

- mandar prompt
- recibir respuesta
- imprimir texto

Hace muchas cosas que solo aparecen cuando un sistema ya esta peleando con sesiones largas, herramientas, retries, fallos de provider y context overflow.

## El runtime real

La pieza principal es `../openclaw-main/src/agents/pi-embedded-runner/run.ts`.

Ese archivo coordina:

- lanes de concurrencia global y por sesion
- resolucion de workspace real
- carga de plugins runtime
- seleccion de provider/model
- hooks para override de modelo
- auth profile rotation
- failover entre perfiles y modelos
- accounting de uso
- backoff
- handoff hacia el intento concreto de ejecucion

Es decir: el "agente" ya es un orchestrator serio.

## Workspace contract

La doc `docs/concepts/agent.md` deja claro que OpenClaw piensa en un agente con disco y memoria operativa:

- `AGENTS.md`
- `SOUL.md`
- `TOOLS.md`
- `BOOTSTRAP.md`
- `IDENTITY.md`
- `USER.md`

Esos archivos se inyectan al contexto al principio de sesiones nuevas.

Esto importa porque:

- hace persistente la personalidad y reglas del agente
- convierte el workspace en parte del contrato
- separa memoria editable del codigo del producto

## Sesiones y transcripts

OpenClaw no trata una conversacion como una cadena suelta de prompts.

Tiene:

- `sessionKey` como bucket de contexto y concurrencia
- `sessionId` estable
- transcriptos JSONL en disco
- stores por agente
- politicas de `send`, `queue`, `followup`, `steer`

Eso permite mezclar:

- chat directo
- grupos
- hilos
- subagentes
- canales externos

sin perder el control del historial.

## Compaction y context overflow

La otra gran pieza es `../openclaw-main/src/agents/pi-embedded-runner/compact.ts`.

Ese archivo existe porque el producto ya tuvo que resolver un problema real:

- como mantener sesiones largas sin destruir contexto ni explotar el context window

La compaction incluye:

- lectura y reparacion de session file
- estimacion de tokens
- recorte de resultados enormes de tools
- hooks antes y despues de compaction
- context engines seleccionables
- timeout de seguridad
- mantenimiento post-compaction

La existencia de archivos como estos lo confirma:

- `tool-result-truncation.ts`
- `session-truncation.ts`
- `context-engine-maintenance.ts`
- `compaction-safety-timeout.ts`

Esto ya es runtime engineering, no solo prompting.

## Auth profiles y model failover

La doc `docs/concepts/model-failover.md` y el codigo del runner muestran un sistema bastante maduro:

- auth profiles por provider
- rotacion de perfiles
- preferencia OAuth antes que API key en ciertos casos
- session stickiness para mantener caches calientes
- cooldown exponencial
- disable temporal por errores de billing
- fallback a otros modelos cuando un provider falla

Esto hace que el producto no dependa de una sola credencial o de un solo estado del proveedor.

## Herramientas y politicas

OpenClaw ya piensa en herramientas como una superficie peligrosa, no como feature inocente.

Vemos varias capas:

- profile de tools (`messaging`, `coding`, etc.)
- gating por owner o por canal
- approvals para `system.run`
- sandbox opcional
- workspace-only FS policies
- truncation de tool results para no destruir el prompt

El agente puede hacer cosas potentes, pero hay mucha infraestructura alrededor para que eso no se vuelva caos.

## `system.run` y aprobaciones

El archivo `src/gateway/node-invoke-system-run-approval.ts` es especialmente revelador.

No deja que un cliente le meta flags de aprobacion arbitrarios a `node.invoke`.
Hace varias cosas:

- extrae solo campos permitidos
- exige `runId`
- valida que exista un approval record real
- valida expiracion
- ata la aprobacion al nodo correcto
- ata la aprobacion al dispositivo/cliente correcto
- reconstruye `systemRunPlan` canonico
- compara argv/cwd/agentId/sessionKey aprobados contra lo que realmente se quiere ejecutar

Esto es exactamente el tipo de detalle que separa un sistema demo de uno que ya sufrio incidentes potenciales y los cerro.

## Concurrencia por lanes

En el runner aparece otra idea fuerte:

- `resolveSessionLane`
- `resolveGlobalLane`
- `enqueueCommandInLane`

OpenClaw no deja que todas las corridas del agente compitan a lo loco.
Hace orchestration de concurrencia por sesion y a nivel global.

Eso ayuda con:

- orden
- consistencia
- no mezclar respuestas
- no corromper estado

## Skills y prompt runtime

El runtime tambien inyecta skills y las convierte en herramientas o contexto activo:

- bundled skills
- managed/local skills
- workspace skills

Y todo eso convive con:

- plugin tools
- channel-owned actions
- bootstrap files
- hooks

El resultado es un agente con muchas fuentes de capacidad, pero integradas dentro del mismo pipeline.

## Que revela esta capa sobre el desarrollo de OpenClaw

Revela varias decisiones claras:

- tratar el agente como sistema operativo conversacional, no como request/response
- tratar el contexto como recurso limitado y fragil
- resolver primero los problemas de larga duracion: sesiones, tools, overflow, retries, auth drift
- guardar estado en disco y no solo en memoria del proceso

## Conclusion

OpenClaw ya aguanta uso real porque su runtime de agente:

- recuerda
- compacta
- rota credenciales
- cambia de modelo
- controla tools
- serializa concurrencia
- protege ejecuciones peligrosas

Eso es exactamente lo que suele faltar en clones o demos.

