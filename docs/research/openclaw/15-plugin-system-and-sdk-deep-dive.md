# 15 - Plugin System And SDK Deep Dive

## Tesis

OpenClaw no trata a los plugins como una bolsa de callbacks.
Los trata como una extension platform con ownership, contratos y runtime boundary.

## El pipeline real: discovery -> loader -> registry -> runtime

La mejor forma de entender la capa de plugins es seguir su pipeline:

1. `src/plugins/discovery.ts`
2. `src/plugins/loader.ts`
3. `src/plugins/registry.ts`
4. `src/plugins/runtime.ts`

Cada fase resuelve un problema distinto.
Eso evita que el sistema de extensiones se vuelva un `import *` gigante e inseguro.

## Discovery con seguridad de filesystem

`src/plugins/discovery.ts` no solo "busca carpetas".
Hace varios chequeos serios:

- roots permitidos
- ownership
- `realpath`
- world-writable
- errores de discovery explicitados como diagnosticos

Esto importa mucho porque los plugins, por definicion, son una superficie donde el proyecto se abre a codigo ajeno.

## Loader con normalizacion y policy

`src/plugins/loader.ts` es donde se ve que el sistema esta pensado para operar en entornos mixtos:

- plugins bundled
- plugins externos
- configuracion habilitada o deshabilitada
- allowlist y denylist
- slots y modos runtime distintos
- validacion de schema/config
- carga parcial para surfaces como channel setup

Ademas, el loader no confunde "plugin detectado" con "plugin activo".
Eso le da al producto un espacio intermedio para:

- diagnosticar
- mostrar errores
- prevenir carga insegura
- cargar solo lo que cierta superficie necesita

## Registry como mapa de capacidades

`src/plugins/registry.ts` es probablemente el archivo mas importante de toda la capa.

No registra una sola cosa.
Centraliza muchas:

- tools
- hooks
- channels
- providers
- speech
- media
- image generation
- web search
- gateway handlers
- HTTP routes
- services
- commands
- diagnostics

Interpretacion:

- plugin no significa solo "agregar un comando"
- significa poder extender casi cualquier borde importante del sistema

## Runtime snapshot para estabilidad

`src/plugins/runtime.ts` y la carpeta `src/plugins/runtime/` muestran otro detalle fino:

- el runtime puede fijar snapshots del registry activo
- las capacidades efectivas no dependen de un objeto mutable global sin control

Eso ayuda a que una corrida de agente o un flujo de onboarding no vea el registry cambiar a mitad de camino.

## Capability model: ownership claro

La doc `docs/plugins/architecture.md` y el codigo del SDK reflejan una idea muy sana:

- el plugin es la unidad de ownership
- la capability es la unidad de contrato con el core

Ese modelo hace dos cosas a la vez:

- permite que un plugin exponga varias capacidades
- evita que todo quede mezclado en una sola API vaga

## El SDK no es accidental

`src/plugin-sdk/plugin-entry.ts`, `src/plugin-sdk/core.ts` y `src/plugin-sdk/api-baseline.ts` muestran que el SDK publico esta tratado como contrato.

Eso se combina con:

- generacion de d.ts
- baseline del SDK
- drift checks en CI

La conclusion es fuerte:

- OpenClaw no ve el SDK como un efecto colateral del core
- lo ve como superficie publica que hay que estabilizar

## Ejemplos que prueban que el sistema es real

Dos ejemplos muy buenos son:

- `extensions/openai/`
- `extensions/telegram/`

Por que son utiles:

- `openai` muestra una extension de provider multi-capability
- `telegram` muestra un canal real con suficiente complejidad como para validar que el sistema soporta integraciones serias

Si el sistema de plugins fuera fragil, estos dos ejemplos ya lo habrian hecho evidente.

## Por que esta capa no se desordena tan facil

- discovery con checks de filesystem
- loader separado del registry
- config y policy antes de activar runtime
- capability model explicito
- registry unico para muchas superficies
- runtime snapshots en vez de mutacion descontrolada
- SDK versionado y vigilado por baseline

## Archivos mas importantes

- `../openclaw-main/docs/tools/plugin.md`
- `../openclaw-main/docs/plugins/architecture.md`
- `../openclaw-main/src/plugins/discovery.ts`
- `../openclaw-main/src/plugins/manifest.ts`
- `../openclaw-main/src/plugins/config-state.ts`
- `../openclaw-main/src/plugins/loader.ts`
- `../openclaw-main/src/plugins/registry.ts`
- `../openclaw-main/src/plugins/runtime.ts`
- `../openclaw-main/src/plugins/types.ts`
- `../openclaw-main/src/plugin-sdk/plugin-entry.ts`
- `../openclaw-main/src/plugin-sdk/core.ts`
- `../openclaw-main/src/plugin-sdk/api-baseline.ts`
- `../openclaw-main/extensions/openai/openclaw.plugin.json`
- `../openclaw-main/extensions/openai/index.ts`
- `../openclaw-main/extensions/telegram/openclaw.plugin.json`
- `../openclaw-main/extensions/telegram/index.ts`
- `../openclaw-main/extensions/telegram/src/channel.ts`

## Conclusion

El sistema de plugins de OpenClaw funciona porque separa muy bien:

- descubrimiento
- policy
- carga
- registro
- runtime

Y encima trata el SDK como contrato publico.

Eso explica por que OpenClaw puede seguir creciendo en canales, providers y herramientas sin que cada extension nueva vuelva a abrir toda la arquitectura.

