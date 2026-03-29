# NemoClaw Reverse Engineering

## Objetivo

Esta carpeta documenta una ingenieria inversa de `../NemoClaw-main` para responder una pregunta practica:

> Que tiene implementado NemoClaw, que capas aporta por encima de OpenClaw, y por que NVIDIA lo presenta como una referencia operativa para correr asistentes "always-on" dentro de OpenShell.

La idea no es tratar a NemoClaw como si fuera otro OpenClaw gigante. No lo es.
NemoClaw es mas bien una capa de producto y operacion que junta:

- un CLI host-side para instalar, onboardear y operar
- un plugin pequeno que vive dentro de OpenClaw
- un blueprint versionado que orquesta OpenShell
- politicas declarativas de sandbox, inferencia y red
- instaladores, recovery, docs y pruebas para volverlo usable

## Hallazgo principal

NemoClaw no intenta competir con OpenClaw en superficie de producto. Hace otra cosa:

- encapsula OpenClaw dentro de OpenShell
- empuja seguridad y policy al centro del flujo
- productiza onboarding, inference routing y sandbox lifecycle
- deja a OpenClaw como "payload" del asistente y a NemoClaw como "control de despliegue y operacion"

La conclusion corta es esta:

> NemoClaw no es otro agente. Es una capa opinionada para ejecutar OpenClaw con mas aislamiento, defaults guiados y control operativo.

## Tamano aproximado del repo analizado

| Area | Archivos |
| --- | ---: |
| repo total | 245 |
| `bin/` | 15 |
| `scripts/` | 22 |
| `nemoclaw/` | 22 |
| `nemoclaw/src/` | 16 |
| `nemoclaw-blueprint/` | 11 |
| `docs/` | 54 |
| `test/` | 58 |
| `.agents/` | 18 |

## Como leer esta carpeta

1. Empieza por [01-repository-map](./01-repository-map.md).
2. Luego sigue con [02-host-cli-and-onboarding](./02-host-cli-and-onboarding.md) y [03-plugin-blueprint-and-sandbox-contract](./03-plugin-blueprint-and-sandbox-contract.md).
3. Despues pasa a [04-inference-routing-and-policy](./04-inference-routing-and-policy.md) y [05-state-migration-and-recovery](./05-state-migration-and-recovery.md).
4. Para instalacion, empaquetado y operacion diaria, lee [06-packaging-installer-and-ops](./06-packaging-installer-and-ops.md).
5. Para calidad, seguridad y guardrails, termina con [07-quality-security-and-reliability](./07-quality-security-and-reliability.md) y [08-why-nemoclaw-works](./08-why-nemoclaw-works.md).
6. Si quieres un mapa rapido por archivos, usa [appendix-key-files](./appendix-key-files.md).

## Documentos incluidos

- [01-repository-map](./01-repository-map.md): mapa del repo, ownership y capas principales.
- [02-host-cli-and-onboarding](./02-host-cli-and-onboarding.md): el binario `nemoclaw`, el wizard de onboard y la logica host-side.
- [03-plugin-blueprint-and-sandbox-contract](./03-plugin-blueprint-and-sandbox-contract.md): como se conectan el plugin, el blueprint y OpenShell.
- [04-inference-routing-and-policy](./04-inference-routing-and-policy.md): profiles de inferencia, policy YAML, presets y restricciones de red/FS.
- [05-state-migration-and-recovery](./05-state-migration-and-recovery.md): estado local, snapshots, registry de sandboxes y recovery.
- [06-packaging-installer-and-ops](./06-packaging-installer-and-ops.md): instalador, scripts auxiliares, servicios y flujo operativo.
- [07-quality-security-and-reliability](./07-quality-security-and-reliability.md): tests, CI, medidas de seguridad y riesgos residuales.
- [08-why-nemoclaw-works](./08-why-nemoclaw-works.md): respuesta ejecutiva y patrones que hacen que el producto aguante.
- [appendix-key-files](./appendix-key-files.md): ruta de lectura por archivos clave.

## Metodologia usada

Para armar esto revise sobre todo:

- raiz del repo: `README.md`, `package.json`, `install.sh`
- CLI host-side en `bin/` y sus helpers
- plugin y runtime de blueprint en `nemoclaw/src/`
- manifests y politicas en `nemoclaw/openclaw.plugin.json` y `nemoclaw-blueprint/`
- docs oficiales del propio proyecto
- scripts de setup, recovery, bridge y operacion
- workflows de CI y bateria de tests

Tambien hice una pasada de seguridad de alto nivel antes de documentar:

- no vi indicadores claros de repo comprometido ni payloads ofuscados en las superficies principales
- si vi bastante shell orchestration y manejo de credenciales por entorno, pero aparece de forma explicita y con tests dedicados
- la mayor complejidad y riesgo practico esta en el bootstrap, los wrappers `bash -c` y los bridges auxiliares, no en una capa oculta o rara

## Respuesta muy corta

Si tuviera que resumir NemoClaw en una sola frase:

> Es una capa de despliegue, policy y operacion que mete a OpenClaw dentro de OpenShell con onboarding guiado, routing de inferencia y recovery suficiente para que el sistema se use de verdad.
