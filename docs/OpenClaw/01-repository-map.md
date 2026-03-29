# 01 - Repository Map

## Idea base

`../openclaw-main` no es "una app". Es un monorepo con varias lineas de producto y una sola arquitectura compartida.

La unidad real del sistema es:

- un core TypeScript (`src/`)
- una capa de extensiones/plugin packages (`extensions/`)
- clientes de operador y nodos (`ui/`, `apps/`)
- skills y tooling (`skills/`, `scripts/`)
- documentacion tratada como parte del producto (`docs/`)

## Vista de alto nivel

| Ruta | Rol |
| --- | --- |
| `src/` | Core runtime, gateway, agent runtime, config, routing, CLI, plugin runtime |
| `extensions/` | Providers, canales, speech, memory y features empaquetados como plugins |
| `apps/` | Clientes nativos y nodos para macOS, iOS y Android |
| `ui/` | Control UI y WebChat |
| `docs/` | Documentacion funcional, operativa, de seguridad y de plugin SDK |
| `scripts/` | Build, checks, CI planning, release helpers, regression guards |
| `skills/` | Skills instalables y bundled |
| `packages/` | Paquetes auxiliares separados del core |
| `test/` | E2E, smoke y fixtures de soporte |

## Zonas mas grandes dentro de `src/`

Las carpetas con mas peso real son estas:

| Carpeta | Archivos | Que concentra |
| --- | ---: | --- |
| `src/agents` | 1039 | runtime del agente, auth profiles, skills, sandbox, prompt pipeline |
| `src/infra` | 550 | helpers de sistema, red, seguridad, errores, env, archivos |
| `src/commands` | 432 | comandos de CLI y flows de configuracion |
| `src/gateway` | 427 | WebSocket/HTTP gateway, auth, pairing, methods, node invoke |
| `src/auto-reply` | 367 | mensajeria, delivery y politicas de respuesta |
| `src/plugin-sdk` | 321 | SDK publico para plugins |
| `src/cli` | 306 | superficie del CLI, perfiles, contenedores, send runtime |
| `src/config` | 276 | configuracion, schema, paths y stores |
| `src/plugins` | 262 | discovery, registry, loading, manifests, runtime plugin |
| `src/channels` | 190 | abstracciones compartidas de canales |

Esto ya dice mucho: OpenClaw invierte mas en runtime, gateway, plugins y operaciones que en una sola interfaz.

## Extensiones mas pesadas

Las extensiones no son decoracion. Muchas concentran su propia complejidad:

| Extension | Archivos | Lectura |
| --- | ---: | --- |
| `discord` | 263 | canal complejo y muy integrado |
| `browser` | 240 | browser automation como feature seria |
| `matrix` | 228 | otro canal completo con runtime propio |
| `telegram` | 194 | uno de los canales mas maduros |
| `slack` | 172 | canal de trabajo con reglas de auth/routing |
| `feishu` | 138 | canal adicional bien separado |
| `whatsapp` | 132 | canal principal del producto |
| `msteams` | 123 | canal empresarial como plugin |
| `open-prose` | 92 | feature/plugin de texto |
| `voice-call` | 89 | plugin funcional grande, no mini-demo |

Patron importante:

- los canales y providers grandes viven como paquetes separados
- la complejidad de cada integracion no contamina por completo al core

## Apps y clientes

| App | Archivos | Lectura |
| --- | ---: | --- |
| `apps/macos` | 369 | menu bar app, gateway control, node mode, onboarding |
| `apps/ios` | 188 | nodo movil, gateway pairing, voice, camera, screen |
| `apps/android` | 164 | nodo Android y commands del dispositivo |
| `apps/shared` | 120 | `OpenClawKit`, la libreria Swift compartida |

## Archivos que explican la arquitectura rapido

Si alguien quisiera entender el repo en orden de impacto:

1. `../openclaw-main/package.json`
2. `../openclaw-main/README.md`
3. `../openclaw-main/src/index.ts`
4. `../openclaw-main/src/entry.ts`
5. `../openclaw-main/src/library.ts`
6. `../openclaw-main/docs/concepts/architecture.md`
7. `../openclaw-main/src/gateway/boot.ts`
8. `../openclaw-main/src/agents/pi-embedded-runner/run.ts`
9. `../openclaw-main/src/agents/pi-embedded-runner/compact.ts`
10. `../openclaw-main/src/plugins/loader.ts`
11. `../openclaw-main/docs/plugins/architecture.md`
12. `../openclaw-main/docs/start/wizard.md`

## Como esta pensado el monorepo

El repo sigue una idea muy clara:

- `src/` define contratos y orchestration
- `extensions/` posee integraciones concretas
- `apps/` consume el mismo gateway protocol
- `docs/` documenta superficies que tambien son contratos
- `scripts/` evita que el crecimiento rompa las fronteras

## Lo mas importante del mapa

El mapa del repo ya responde parte de la pregunta del usuario:

- OpenClaw ya funciona porque tiene ownership explicito por capa
- cada area compleja tiene su propio paquete, docs y pruebas
- no depende de una sola UI ni de un solo canal
- el repo esta organizado para crecer sin convertir todo en una bola de barro
