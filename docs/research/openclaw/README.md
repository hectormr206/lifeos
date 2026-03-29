# OpenClaw Reverse Engineering

## Objetivo

Esta carpeta documenta una ingenieria inversa de `../openclaw-main` para responder una pregunta practica:

> Que tiene implementado OpenClaw para que ya funcione como producto real, no como demo, y por que parece aguantar uso serio por muchas personas.

En vez de meter todo en un solo markdown enorme, organice el analisis por capas.

## Hallazgo principal

OpenClaw no funciona por "un gran prompt". Funciona porque junta varias capas que casi siempre estan separadas en proyectos menos maduros:

- un gateway unico como control plane
- un runtime de agente con sesiones, compaction, failover y herramientas reales
- un sistema de plugins/extensiones con ownership claro
- onboarding y configuracion como parte del producto
- clientes reales para web, macOS, iOS y Android
- una disciplina fuerte de testing, CI, seguridad y release engineering

La conclusion corta es esta: OpenClaw ya se comporta como una plataforma, no como un wrapper de LLM.

## Tamano aproximado del repo analizado

| Area | Archivos |
| --- | ---: |
| `src/` | 5127 |
| `extensions/` | 3082 |
| `apps/` | 841 |
| `ui/` | 250 |
| `docs/` | 752 |
| `scripts/` | 269 |
| `skills/` | 69 |
| `packages/` | 90 |
| `test/` | 153 |

## Como leer esta carpeta

1. Empieza por [01-repository-map](./01-repository-map.md).
2. Luego sigue con [02-core-runtime-and-gateway](./02-core-runtime-and-gateway.md) y su ampliacion [13-gateway-control-plane-deep-dive](./13-gateway-control-plane-deep-dive.md).
3. Despues pasa a [03-agent-runtime-context-and-tools](./03-agent-runtime-context-and-tools.md), [14-agent-runtime-execution-pipeline](./14-agent-runtime-execution-pipeline.md), [04-plugin-and-extension-system](./04-plugin-and-extension-system.md) y [15-plugin-system-and-sdk-deep-dive](./15-plugin-system-and-sdk-deep-dive.md).
4. Si quieres entender las superficies menos obvias del producto, sigue con [16-acp-control-plane-and-ide-bridge](./16-acp-control-plane-and-ide-bridge.md), [05-channels-pairing-and-routing](./05-channels-pairing-and-routing.md) y [18-automation-routing-and-cron](./18-automation-routing-and-cron.md).
5. Para setup y operacion, lee [06-onboarding-and-operator-experience](./06-onboarding-and-operator-experience.md), [17-configuration-onboarding-and-self-repair](./17-configuration-onboarding-and-self-repair.md), [07-clients-ui-and-native-apps](./07-clients-ui-and-native-apps.md) y [09-packaging-and-ops](./09-packaging-and-ops.md).
6. Si quieres cerrar huecos estructurales, sigue con [20-node-execution-sandbox-and-canvas](./20-node-execution-sandbox-and-canvas.md) y [21-session-durability-and-storage-governance](./21-session-durability-and-storage-governance.md).
7. Para la respuesta directa a "por que esto no se rompe tan facil", termina con [08-quality-security-and-reliability](./08-quality-security-and-reliability.md), [10-why-openclaw-works](./10-why-openclaw-works.md), [19-anti-breakage-engineering-patterns](./19-anti-breakage-engineering-patterns.md) y [appendix-key-files](./appendix-key-files.md).

## Documentos incluidos

- [01-repository-map](./01-repository-map.md): mapa del monorepo, jerarquia y directorios que importan.
- [02-core-runtime-and-gateway](./02-core-runtime-and-gateway.md): el gateway WS/HTTP, el handshake, los roles y el control plane.
- [03-agent-runtime-context-and-tools](./03-agent-runtime-context-and-tools.md): el runtime del agente, sesiones, compaction, auth rotation y herramientas.
- [04-plugin-and-extension-system](./04-plugin-and-extension-system.md): discovery, manifests, loader, registry y capability model.
- [05-channels-pairing-and-routing](./05-channels-pairing-and-routing.md): como enruta mensajes, aisla sesiones y controla pairing.
- [06-onboarding-and-operator-experience](./06-onboarding-and-operator-experience.md): por que instalarlo y dejarlo usable es mucho mas facil que en otros proyectos.
- [07-clients-ui-and-native-apps](./07-clients-ui-and-native-apps.md): Control UI, macOS, iOS, Android y `OpenClawKit`.
- [08-quality-security-and-reliability](./08-quality-security-and-reliability.md): tests, CI, formal verification, audits y guardrails.
- [09-packaging-and-ops](./09-packaging-and-ops.md): npm, Docker, compose, render, launch agents y canales de release.
- [10-why-openclaw-works](./10-why-openclaw-works.md): respuesta ejecutiva y patrones de desarrollo.
- [11-contracts-build-and-code-governance](./11-contracts-build-and-code-governance.md): build, baselines, CI por alcance y guardrails del repo.
- [12-runtime-bootstrap-and-distribution-paths](./12-runtime-bootstrap-and-distribution-paths.md): wrappers de arranque, rutas de distribucion y bootstrap del runtime.
- [13-gateway-control-plane-deep-dive](./13-gateway-control-plane-deep-dive.md): handshake, auth, eventos, nodos, approvals y Control UI a nivel de implementacion.
- [14-agent-runtime-execution-pipeline](./14-agent-runtime-execution-pipeline.md): setup, intentos, compaction, contexto selectivo y failover del runner principal.
- [15-plugin-system-and-sdk-deep-dive](./15-plugin-system-and-sdk-deep-dive.md): discovery, loader, registry, runtime snapshots y contrato del SDK.
- [16-acp-control-plane-and-ide-bridge](./16-acp-control-plane-and-ide-bridge.md): bridge ACP, session manager, runtime cache, policy y bindings persistentes.
- [17-configuration-onboarding-and-self-repair](./17-configuration-onboarding-and-self-repair.md): config IO auditado, redaccion de secretos, onboarding, daemon install y doctor.
- [18-automation-routing-and-cron](./18-automation-routing-and-cron.md): routing determinista, auto-reply, colas, dedupe, channel setup y cron.
- [19-anti-breakage-engineering-patterns](./19-anti-breakage-engineering-patterns.md): patrones repetidos de ingenieria que explican como OpenClaw crecio sin romperse tan facil.
- [20-node-execution-sandbox-and-canvas](./20-node-execution-sandbox-and-canvas.md): plano de ejecucion local, `system.run`, sandbox, supervision de procesos y canvas/A2UI.
- [21-session-durability-and-storage-governance](./21-session-durability-and-storage-governance.md): stores, transcripts, mantenimiento, presupuestos de disco y durabilidad conversacional.
- [appendix-key-files](./appendix-key-files.md): ruta de lectura por archivos clave.

## Metodologia usada

Para armar esto revise sobre todo:

- raiz del repo: `README.md`, `AGENTS.md`, `package.json`, `pnpm-workspace.yaml`
- docs tecnicas del propio proyecto
- entrypoints y capas core en `src/`
- ejemplos reales de extensiones como `openai` y `telegram`
- carpetas de apps nativas y `ui/`
- `Dockerfile`, `docker-compose.yml`, `render.yaml`
- pipeline de CI, scripts de guardrails y pruebas

Tambien hice una pasada de seguridad de alto nivel antes de documentar:

- el repo ya trae `.detect-secrets.cfg`, `.secrets.baseline`, pre-commit y auditorias
- no vi indicadores obvios de codigo ofuscado o payloads sospechosos en las superficies principales
- si vi patrones esperados de bootstrap como `curl | bash` para instalar Bun en build scripts y Docker, pero aparecen de forma explicita, documentada y sin ocultamiento

## Respuesta muy corta

Si tuviera que resumir OpenClaw en una sola frase:

> Es un sistema completo de asistente personal multi-canal, con gateway tipado, runtime de agente serio, clientes reales, plugins bien separados y una cantidad inusual de guardrails para evitar regresiones.
