# 05 - State, Migration And Recovery

## Estado local del operador

NemoClaw guarda estado en `~/.nemoclaw/`.
Las piezas mas importantes son:

- `credentials.json`
- `sandboxes.json`
- `state/nemoclaw.json`
- `state/runs/<run-id>/plan.json`
- `snapshots/`

Eso separa varias responsabilidades:

- credenciales
- inventario de sandboxes
- ultimo estado operativo
- historial por corrida
- snapshots para migracion y rollback

## Registry de sandboxes

`bin/lib/registry.js` maneja `~/.nemoclaw/sandboxes.json`.

Guarda por sandbox:

- nombre
- fecha de creacion
- modelo
- provider
- contenedor NIM
- GPU enabled
- presets de policy

Tambien mantiene `defaultSandbox`.

No es sofisticado, pero si suficiente para que el CLI sea multi-sandbox sin meter una base de datos.

## State operativo

`nemoclaw/src/blueprint/state.ts` maneja `nemoclaw.json` con campos como:

- `lastRunId`
- `lastAction`
- `blueprintVersion`
- `sandboxName`
- `migrationSnapshot`
- `hostBackupPath`

Eso alimenta varias superficies:

- `/nemoclaw status`
- hints de rollback
- recovery despues de fallos o reinicios

## Migracion desde host OpenClaw

La pieza mas interesante esta en `snapshot.ts`.

El flujo contempla:

1. snapshot de `~/.openclaw`
2. copia del snapshot al sandbox
3. cutover del host
4. rollback si hace falta

Las funciones clave son:

- `createSnapshot()`
- `restoreIntoSandbox()`
- `cutoverHost()`
- `rollbackFromSnapshot()`
- `listSnapshots()`

Esto revela algo importante:

> NemoClaw no solo crea un sandbox nuevo; tambien piensa en el caso de migrar una instalacion existente.

## Recovery de runtime

La familia `runtime-recovery.js` y los bloques de reconciliacion en `bin/nemoclaw.js` distinguen estados como:

- sandbox presente
- sandbox faltante
- gateway inactivo
- gateway inaccesible
- drift de identidad/handshake

Y a partir de eso deciden si:

- reintentar seleccion de gateway
- reiniciar gateway
- sugerir `nemoclaw onboard --resume`
- o declarar que el sandbox debe recrearse

## Por que esto importa

Muchos proyectos de agentes suponen una ruta lineal:

- install
- run

NemoClaw ya asume una vida real mas sucia:

- host rebooteado
- gateway roto
- sandbox medio vivo
- operator state parcial
- migracion desde config vieja

Ese modelo mental de recovery es de las capas que mas lo acercan a producto real.
