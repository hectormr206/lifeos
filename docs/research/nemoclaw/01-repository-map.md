# 01 - Repository Map

## Idea base

`../NemoClaw-main` no es "otro OpenClaw".
Es un repo bastante mas pequeno, con una idea mucho mas acotada:

- host CLI y scripts para instalar y operar
- un plugin fino dentro de OpenClaw
- un blueprint versionado para OpenShell
- politicas declarativas de sandbox
- docs y tests para convertir eso en experiencia de producto

## Vista de alto nivel

| Ruta | Rol |
| --- | --- |
| `bin/` | CLI host-side real: onboard, connect, status, destroy, policy, recovery |
| `nemoclaw/` | plugin para OpenClaw y runtime TypeScript del blueprint |
| `nemoclaw-blueprint/` | manifiesto versionado y politicas YAML |
| `scripts/` | instalacion, start/stop, Telegram bridge, setup remoto, debug |
| `docs/` | quickstart, arquitectura, troubleshooting, network policy, deployment |
| `test/` | unit, smoke, seguridad y e2e |
| `.github/workflows/` | CI de PRs, docs preview, images y e2e nocturno |
| `.agents/skills/` | habilidades operativas para Claude/Codex sobre NemoClaw |

## Que tiene mas peso real

| Area | Archivos | Que concentra |
| --- | ---: | --- |
| `test/` | 58 | cobertura de onboarding, seguridad, recovery, install y sandbox |
| `docs/` | 54 | producto, operacion y seguridad como parte del entregable |
| `scripts/` | 22 | installer, start-services, setup, deploy, bridge, debug |
| `nemoclaw/` | 22 | plugin, slash command, blueprint runner, state, SSRF |
| `bin/` | 15 | CLI host-side y helpers principales |
| `nemoclaw-blueprint/` | 11 | blueprint manifest + policy baseline + presets |

## El patron arquitectonico

El repo esta partido en tres piezas:

1. `bin/` controla el host.
2. `nemoclaw/` define el plugin y el runtime que se acopla a OpenClaw.
3. `nemoclaw-blueprint/` declara que sandbox, inference route y policy se deben crear.

Eso ya explica bastante del producto:

- el operador usa `nemoclaw`
- OpenClaw sigue siendo el agente
- OpenShell sigue siendo el enforcement layer
- NemoClaw vive en medio como glue productizado

## Directorios que explican el sistema rapido

Si alguien quisiera entender el repo en orden de impacto:

1. `../NemoClaw-main/README.md`
2. `../NemoClaw-main/package.json`
3. `../NemoClaw-main/bin/nemoclaw.js`
4. `../NemoClaw-main/bin/lib/onboard.js`
5. `../NemoClaw-main/nemoclaw/openclaw.plugin.json`
6. `../NemoClaw-main/nemoclaw/src/index.ts`
7. `../NemoClaw-main/nemoclaw/src/commands/slash.ts`
8. `../NemoClaw-main/nemoclaw/src/blueprint/runner.ts`
9. `../NemoClaw-main/nemoclaw/src/blueprint/snapshot.ts`
10. `../NemoClaw-main/nemoclaw/src/blueprint/ssrf.ts`
11. `../NemoClaw-main/nemoclaw-blueprint/blueprint.yaml`
12. `../NemoClaw-main/nemoclaw-blueprint/policies/openclaw-sandbox.yaml`

## Lo mas importante del mapa

El mapa ya responde la pregunta principal:

- NemoClaw esta construido para **operar** OpenClaw, no para reemplazarlo
- la complejidad fuerte esta en onboarding, sandboxing, policy y recovery
- docs y tests pesan casi tanto como el codigo
- el repo esta optimizado para "hacer que funcione en una maquina real" mas que para expandir features del agente
