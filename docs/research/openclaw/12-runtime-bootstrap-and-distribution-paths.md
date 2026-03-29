# 12 - Runtime Bootstrap And Distribution Paths

## Tesis

OpenClaw no tiene una sola forma de arrancar.
Tiene varias rutas de bootstrap y distribucion, y eso esta reflejado directamente en el codigo.

## Ruta de arranque publicada

El binario npm apunta a `openclaw.mjs`.

Ese archivo funciona como wrapper de distribucion:

- asegura version minima de Node
- activa compile cache
- instala filtro de warnings
- intenta servir ayuda de forma rapida
- carga el `entry` compilado real

Es decir:

- el usuario invoca `openclaw`
- pero el producto realmente entra por un bootstrapper de compatibilidad

## Ruta de arranque del runtime principal

Luego entran `src/index.ts` y `src/entry.ts`.

Entre ambos resuelven:

- diferencia entre usar OpenClaw como libreria o como CLI
- fast path de `--help` y `--version`
- normalizacion de `argv` en Windows
- perfiles de CLI
- respawn cuando hace falta
- manejo global de errores

Esto permite que el arranque sea:

- mas rapido
- mas seguro
- mas portable

## Build output y source tree

Una decision muy buena del wrapper es diferenciar claramente:

- package instalado correctamente con `dist/`
- source tree descargado sin build

Si falta `dist`, no falla con un stack trace opaco.
Intenta explicar:

- que parece un source tree sin compilar
- que debes correr `pnpm install && pnpm build`
- o instalar una version empaquetada

Eso es UX operativa muy buena.

## Ruta como libreria

`src/index.ts` exporta funciones del facade `library.ts` cuando no se ejecuta como main.

Eso implica que OpenClaw no fue pensado unicamente como binario.
Tambien deja superficies reusables para consumo programatico.

## Ruta Docker

El `Dockerfile` define otra forma de bootstrap:

- stage de build con Node y Bun
- instalacion de deps con pnpm
- build de artefactos
- stage runtime mas limpio
- copia solo de assets necesarios

Y luego deja variaciones opcionales por flags:

- browser preinstalado
- Docker CLI para sandbox
- extensiones preinstaladas
- paquetes apt extra

Es bootstrap por imagen, no solo por paquete npm.

## Ruta docker-compose

`docker-compose.yml` separa:

- gateway siempre vivo
- CLI compartiendo red con el gateway

Eso muestra otra idea importante:

- OpenClaw entiende al gateway como servicio persistente
- y al CLI como cliente/operador

## Ruta remote/self-hosted

Con `render.yaml`, Tailscale, SSH tunnels y docs de gateway remoto, OpenClaw contempla despliegues como:

- VPS
- contenedores
- hosts remotos con clientes locales

El bootstrap no es solo local desktop.

## Ruta app nativa

Las apps tambien forman parte del bootstrap del sistema:

- macOS puede lanzar/gestionar el gateway
- iOS y Android pairan nodos
- la app macOS hace onboarding y control del runtime

Entonces el bootstrap real del ecosistema no siempre empieza en una terminal.

## Compile cache y startup metadata

Un detalle interesante es que OpenClaw intenta optimizar el costo del arranque:

- compile cache de Node cuando esta disponible
- metadata precomputada para root help
- wrappers que cargan solo lo necesario

Esto revela que el tiempo de arranque importa como experiencia de producto.

## Que problema estan resolviendo con todo esto

Estan resolviendo varios a la vez:

- diferencias entre entornos
- artefactos incompletos
- latencia de arranque
- compatibilidad de version
- misma herramienta en npm, source, Docker y apps

## Conclusion

OpenClaw no tiene un arranque trivial porque no es un programa trivial.
Su bootstrap refleja que ya fue pensado para:

- usuarios finales
- colaboradores
- despliegues remotos
- contenedores
- clientes nativos

Eso es parte importante de la ingenieria real del producto.

