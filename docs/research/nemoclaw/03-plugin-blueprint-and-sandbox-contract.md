# 03 - Plugin, Blueprint And Sandbox Contract

## La separacion clave

NemoClaw no mete toda su logica dentro de OpenClaw ni toda fuera.
La separa en dos contratos:

- un plugin dentro de OpenClaw
- un blueprint runner fuera, que orquesta OpenShell

Eso mantiene limpio el ownership.

## El plugin

El plugin vive en `../NemoClaw-main/nemoclaw/`.

Su manifest `openclaw.plugin.json` deja claro que NemoClaw se presenta como extension de OpenClaw, con configuracion para:

- `blueprintVersion`
- `blueprintRegistry`
- `sandboxName`
- `inferenceProvider`

En `nemoclaw/src/index.ts` el plugin registra principalmente dos cosas:

- el slash command `/nemoclaw`
- un provider "managed inference route"

## Que hace el plugin y que no hace

El plugin no pretende ser otro runtime entero.
Hace cosas puntuales:

- exponer estado y onboarding desde chat
- reflejar el provider y modelo configurados por NemoClaw
- dar una capa minima de UX dentro del sandbox

El slash command en `nemoclaw/src/commands/slash.ts` soporta sobre todo:

- `status`
- `onboard`
- `eject`

Eso confirma el rol del plugin:

> dar visibilidad y control minimo desde OpenClaw, no reimplementar el host CLI.

## El blueprint

`nemoclaw-blueprint/blueprint.yaml` es el contrato declarativo del despliegue.

Define:

- version y compatibilidad minima
- perfiles de inferencia
- imagen y nombre del sandbox
- puertos forwardeados
- additions de policy

El runner en `nemoclaw/src/blueprint/runner.ts` ejecuta cuatro acciones:

- `plan`
- `apply`
- `status`
- `rollback`

Y su protocolo de salida tambien esta pensado:

- `RUN_ID:<id>`
- `PROGRESS:<0-100>:<label>`

Eso hace que la ejecucion del blueprint sea observable y embebible por otras capas.

## Que coordina realmente el runner

En `apply`, el runner hace esta secuencia:

1. resolver el profile del blueprint
2. validar endpoint con SSRF guard
3. crear o reutilizar sandbox en OpenShell
4. crear provider
5. setear inference route
6. persistir `plan.json` en `~/.nemoclaw/state/runs/<run-id>/`

No es un "deploy tool" generico.
Es un orquestador opinionado para la topologia OpenClaw + OpenShell.

## Por que esta separacion funciona

Porque cada capa tiene un trabajo muy claro:

- plugin: UX dentro del agente
- CLI: operacion del host
- blueprint: reconciliacion reproducible del sandbox
- OpenShell: enforcement de verdad

Eso reduce la tentacion de mezclar comandos del host dentro del plugin o policy del sandbox dentro del chat runtime.
