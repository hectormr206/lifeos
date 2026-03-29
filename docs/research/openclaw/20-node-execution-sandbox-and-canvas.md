# 20 - Node Execution, Sandbox, And Canvas

## Tesis

Despues de revisar mas el repo, aparecio una capa que estaba subdocumentada:

- el execution plane local

OpenClaw no solo tiene un control plane en el Gateway.
Tambien tiene una capa bastante seria para:

- ejecutar comandos de forma controlada
- aislar ejecucion en sandbox
- correr capacidades en nodos
- exponer superficies interactivas tipo canvas/A2UI

## Un segundo plano: ejecutar sin confiar ciegamente

La ruta `src/node-host/` muestra que el nodo no es solo "un cliente que recibe ordenes".
Es un runtime propio que:

- se conecta al Gateway como `role: node`
- anuncia `caps` y `commands`
- mantiene identidad de dispositivo
- recibe `node.invoke.request`
- revalida localmente que lo que va a ejecutar siga siendo permitido
- empuja capacidades y superficies fuera del host central

Archivos clave:

- `../openclaw-main/docs/nodes/index.md`
- `../openclaw-main/src/node-host/runner.ts`
- `../openclaw-main/src/node-host/invoke.ts`
- `../openclaw-main/src/node-host/invoke-system-run.ts`
- `../openclaw-main/src/node-host/exec-policy.ts`

## `system.run` se valida dos veces

Esta parte es de las mas importantes de toda la pasada extra.

Ya sabíamos que el Gateway cuidaba approvals.
Lo que faltaba subrayar es esto:

- el nodo no ejecuta "lo aprobado" a ciegas

La capa local vuelve a revisar:

- allowlist
- `ask`
- wrappers de shell
- `cwd`
- operandos mutables
- overrides de entorno
- plan canonico de ejecucion

`invoke-system-run.ts` y `invoke-system-run-plan.ts` revelan un patrón muy fuerte:

- aprobar no basta
- la aprobacion sigue amarrada a una forma concreta de ejecutar

Eso evita que el approval del Gateway se convierta en permiso general reutilizable.

## `bash-tools.exec.ts` no es un wrapper inocente

El archivo `src/agents/bash-tools.exec.ts` confirma que OpenClaw piensa la ejecucion como superficie peligrosa y muy configurable.

El tool decide entre varios hosts:

- local
- sandbox
- gateway
- node

Y ademas mezcla:

- `security=deny|allowlist|full`
- `ask`
- sanitizacion de env
- PTY
- background/yield
- policy de safe bins
- preflight para detectar errores comunes en scripts

Esto es importantisimo porque demuestra que el producto ya resolvio parte del problema de "dar poder sin regalar ejecucion arbitraria".

## Sandboxes de verdad, no solo una bandera

`src/agents/sandbox/` es una capa mucho mas grande de lo que parecia a simple vista.

Patrones que aparecieron:

- backends registrables (`docker`, `ssh`)
- registry de runtimes
- policy de tools especifica para sandbox
- workspace mounts
- bridging de filesystem
- chequeos de seguridad para binds, targets y red

Archivos mas importantes:

- `../openclaw-main/src/agents/sandbox/config.ts`
- `../openclaw-main/src/agents/sandbox/backend.ts`
- `../openclaw-main/src/agents/sandbox/registry.ts`
- `../openclaw-main/src/agents/sandbox/tool-policy.ts`
- `../openclaw-main/src/agents/sandbox/validate-sandbox-security.ts`
- `../openclaw-main/src/agents/sandbox/fs-bridge.ts`
- `../openclaw-main/src/agents/sandbox/docker-backend.ts`

Lo mas revelador es que `validate-sandbox-security.ts` bloquea cosas concretas como:

- binds a rutas host peligrosas
- targets reservados dentro del contenedor
- modos de red inseguros
- perfiles `unconfined`

Eso ya es hardening operativo, no marketing.

## FS bridge con operaciones ancladas

`fs-bridge.ts` y sus helpers son otra señal de madurez.

No hacen mutaciones "por path" sin mas.
Construyen planes anclados y pasan por guards de seguridad para:

- escribir
- renombrar
- borrar
- crear directorios
- hacer stat

Interpretacion:

- OpenClaw no quiere que el sandbox sea una caja negra con permisos opacos
- quiere modelar operaciones de FS con restricciones comprensibles y verificables

## Supervisión de procesos separada del tool

La carpeta `src/process/` y sobre todo `src/process/supervisor/` muestran otra capa importante que estaba medio escondida en la ingeniería inversa anterior.

Hay una infraestructura reusable para:

- `child` y `pty`
- cancelacion por `scopeKey`
- reemplazo de corridas previas
- timeout global
- timeout por falta de salida
- registry de runs
- captura y cleanup consistente

Archivos clave:

- `../openclaw-main/src/process/exec.ts`
- `../openclaw-main/src/process/command-queue.ts`
- `../openclaw-main/src/process/supervisor/supervisor.ts`

Esto ayuda a que la ejecucion peligrosa o larga no dependa de cada tool individual.

## `exec.ts` cuida semantica multiplataforma

`src/process/exec.ts` trae varios detalles que muestran experiencia real:

- wrappers especiales para Windows `.cmd/.bat`
- rechazo de caracteres peligrosos para `cmd.exe`
- manejo especial de `npm/npx`
- `shell` deshabilitado por defecto para argv-based execution
- merge de env con marcado propio de OpenClaw

Ese archivo parece pequeño al lado del repo entero, pero es muy representativo de la filosofía:

- la portabilidad no se deja "a ver si Node lo resuelve"
- se controla explicitamente

## Canvas host y A2UI

Otra pieza que sí merecía aparecer mejor es `src/canvas-host/`.

`server.ts`, `a2ui.ts` y `file-resolver.ts` muestran que OpenClaw tiene una superficie local para:

- servir canvas agent-editable
- servir A2UI
- hacer live reload
- inyectar un bridge de acciones para iOS/Android
- resolver archivos dentro de un root seguro

Lo importante aqui no es solo lo visual.
Es que OpenClaw ya trata interfaces interactivas embebidas como parte de la plataforma.

Detalles reveladores:

- usa `resolveFileWithinRoot`
- evita traversal y symlink surprises
- genera un bridge `openclawSendUserAction`
- integra WebSocket para reload y mensajes hacia nodos

Eso conecta muy bien con las apps nativas y con la idea de nodos como superficies activas, no solo como terminales pasivas.

## Lo que esta capa agrega a la respuesta de "por que funciona"

Antes teniamos muy claro:

- Gateway
- runtime del agente
- plugins
- onboarding

Con esta pasada extra queda mas completa otra respuesta:

- OpenClaw tambien funciona porque su plano de ejecucion ya esta bastante domesticado

No entrega `exec` bruto.
Entrega:

- policy
- approvals
- sandbox
- supervisor
- revalidacion local
- surfaces interactivas canvas

## Archivos mas importantes

- `../openclaw-main/docs/nodes/index.md`
- `../openclaw-main/src/agents/bash-tools.exec.ts`
- `../openclaw-main/src/node-host/runner.ts`
- `../openclaw-main/src/node-host/invoke.ts`
- `../openclaw-main/src/node-host/invoke-system-run.ts`
- `../openclaw-main/src/node-host/invoke-system-run-plan.ts`
- `../openclaw-main/src/node-host/exec-policy.ts`
- `../openclaw-main/src/agents/sandbox/config.ts`
- `../openclaw-main/src/agents/sandbox/backend.ts`
- `../openclaw-main/src/agents/sandbox/registry.ts`
- `../openclaw-main/src/agents/sandbox/tool-policy.ts`
- `../openclaw-main/src/agents/sandbox/validate-sandbox-security.ts`
- `../openclaw-main/src/agents/sandbox/fs-bridge.ts`
- `../openclaw-main/src/process/exec.ts`
- `../openclaw-main/src/process/command-queue.ts`
- `../openclaw-main/src/process/supervisor/supervisor.ts`
- `../openclaw-main/src/canvas-host/server.ts`
- `../openclaw-main/src/canvas-host/a2ui.ts`
- `../openclaw-main/src/canvas-host/file-resolver.ts`

## Conclusion

Esta capa era un hueco real en la documentación.

OpenClaw no solo esta bien diseñado para conversar.
Tambien esta bastante bien diseñado para ejecutar, supervisar, aislar y exponer acciones locales sin perder demasiado control.

Eso lo aleja mucho mas de una demo de agente y lo acerca a una plataforma operativa y distribuida de verdad.
