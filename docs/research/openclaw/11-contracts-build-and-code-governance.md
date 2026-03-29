# 11 - Contracts, Build, And Code Governance

## Tesis

OpenClaw no se mantiene solo por buenas intenciones.
Tiene una capa de gobernanza tecnica bastante fuerte que convierte decisiones de arquitectura en verificaciones automáticas.

## Build como pipeline de ensamblaje, no como un solo `tsc`

El script `build` en `package.json` no hace una sola cosa.
Encadena varias:

- bundle de A2UI
- build TypeScript principal
- postbuild de runtime
- stamp de build
- generacion de DTS del plugin SDK
- escritura de entradas del SDK
- copias de metadata de hooks y templates HTML
- escritura de build info y metadata de startup del CLI

Interpretacion:

- el artefacto final de OpenClaw no es solo JS compilado
- es un ensamblaje de runtime, contratos, metadata y surfaces publicas

## Drift checks como politica del repo

OpenClaw tiene checks dedicados para detectar drift en contratos publicos:

- `pnpm plugin-sdk:api:check`
- `pnpm config:docs:check`
- `pnpm check:bundled-plugin-metadata`
- `pnpm check:bundled-provider-auth-env-vars`
- `pnpm check:base-config-schema`

Esto significa que cuando cambia una superficie importante:

- o actualizas el baseline deliberadamente
- o el repo te dice que estas rompiendo algo

## Baseline del Plugin SDK

`scripts/generate-plugin-sdk-api-baseline.ts` y `src/plugin-sdk/api-baseline.ts` muestran una decision muy madura:

- el SDK publico se renderiza como baseline generado
- ese baseline se compara en CI
- si cambias exports o formas publicas, el diff no pasa silenciosamente

La implementacion usa TypeScript compiler API para:

- cargar `tsconfig`
- recorrer entrypoints del SDK
- inferir kinds de exports
- producir archivos bajo `docs/.generated/`

Esto es basicamente tratar el SDK como contrato versionable, no como consecuencia accidental del codigo.

## Baseline de documentacion de config

`scripts/generate-config-doc-baseline.ts` hace lo mismo para la superficie de configuracion.

La idea es excelente:

- el schema/config help
- la documentacion derivada
- y el contrato real

deben moverse juntos.

Asi se evita uno de los males clasicos de proyectos complejos:

- la config real cambia
- la doc queda vieja
- nadie sabe cual es la verdad

## CI guiado por alcance

`scripts/ci-changed-scope.mjs` y `scripts/ci-write-manifest-outputs.mjs` enseñan otro patron muy fuerte:

- el CI no corre ciegamente todo siempre
- primero detecta el alcance del cambio
- luego genera un manifest de ejecucion
- despues habilita solo jobs pertinentes

Esto ya es optimizacion de monorepo seria.

### Que detecta

El scope detector separa cosas como:

- docs
- Node/core
- macOS/iOS/shared Swift
- Android
- Windows
- Python skills
- smoke relacionado a instalacion

### Por que importa

Porque OpenClaw ya tiene suficientes superficies como para que un CI ingenuo sea:

- lento
- caro
- y facil de ignorar

Su solucion no fue aflojar checks, sino planificarlos mejor.

## Test planner como infraestructura

`scripts/test-planner/planner.mjs` demuestra que hasta la ejecucion de tests esta orquestada con inteligencia:

- carga manifests de timing
- calcula budgets de ejecucion
- empaqueta archivos por duracion
- separa surfaces como `unit`, `extensions`, `channels`, `contracts`, `gateway`
- arma matrices dinamicas

Eso habla de un repo que ya sufrio con:

- suites grandes
- paralelismo mal equilibrado
- tiempo de CI excesivo

Y respondio con planificacion, no solo con "compren runners mas grandes".

## Pre-commit muy alineado con CI

`.pre-commit-config.yaml` no es decorativo.
Replica bastante bien la filosofia del CI:

- higiene basica de archivos
- detect-private-key
- detect-secrets con baseline
- shellcheck
- actionlint
- zizmor
- ruff para skills Python
- audit de dependencias
- oxlint/oxfmt
- swiftlint/swiftformat

Esto reduce la distancia entre:

- lo que un colaborador rompe localmente
- y lo que luego rompe en CI

## Guardrails arquitectonicos hechos a medida

OpenClaw no se conforma con lints genericos.
Agrega scripts propios para vigilar errores de arquitectura que ellos ya conocen:

- imports cruzados indebidos
- runtime boundaries
- APIs viejas que no deben reaparecer
- politicas de pairing/account scope
- reglas de channel/plugin boundaries

Esto revela un patron muy sano:

- cuando un problema se repite, lo convierten en check

## `openclaw.mjs` como wrapper de distribucion

El wrapper de raiz `openclaw.mjs` hace varias cosas que parecen pequenas, pero son muy importantes:

- valida version minima de Node
- activa compile cache cuando puede
- intenta servir `--help` por ruta rapida
- carga `dist/entry.js` o `dist/entry.mjs`
- si falta `dist`, da un error explicando si parece source tree sin build

Eso mejora dos cosas:

- UX de instalacion
- claridad operativa cuando el artefacto esta incompleto

## Que revela esta capa sobre como se programo OpenClaw

Revela que el equipo no programo solo features.
Programo tambien mecanismos para sostener el crecimiento:

- contratos visibles
- artefactos generados
- drift detection
- CI adaptativo
- planners de test
- wrappers de arranque
- hooks alineados con CI

## Conclusion

OpenClaw no se entiende del todo si solo miras runtime y features.
Tambien hay que mirar la capa de gobernanza del codigo.

Esa capa explica mucho de por que el proyecto pudo crecer sin volverse completamente inmanejable.

