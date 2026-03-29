# 09 - Packaging And Ops

## Tesis

Un producto "ya funciona" cuando no solo corre desde source, sino cuando se puede:

- instalar
- actualizar
- correr como servicio
- empaquetar
- desplegar

OpenClaw ya resolvio bastante de eso.

## Instalacion principal

El README deja clara la ruta principal:

- `npm install -g openclaw@latest`
- `openclaw onboard --install-daemon`

Ese detalle importa:

- npm global da distribucion rapida
- onboarding + daemonizacion convierte la instalacion en servicio util

## Docker serio, no improvisado

El `Dockerfile` es una de las piezas mas claras de madurez operativa.

Tiene:

- multi-stage build
- imagenes base pineadas por digest
- runtime final mas chico
- opcion de browser preinstalado
- opcion de Docker CLI para sandbox
- soporte para extensiones opt-in en build
- copiado explicito de `dist`, `extensions`, `skills` y `docs`

Esto ya es packaging de producto, no Dockerfile de laboratorio.

## `docker-compose.yml`

Tambien hay un compose util que separa:

- `openclaw-gateway`
- `openclaw-cli`

Con:

- volumen para config y workspace
- healthcheck
- token por env
- restart policy
- posibilidad de sandbox via Docker socket

Interpretacion:

- pensaron tanto en operador local como en despliegue contenedorizado

## Despliegue remoto

Hay tambien `render.yaml`, ademas de docs para Tailscale, remote gateway y SSH tunnels.

El producto ya asume escenarios como:

- VPS pequeno
- gateway remoto
- cliente local conectado a distancia
- nodos en dispositivos aparte

## Actualizaciones y canales

El README documenta canales:

- `stable`
- `beta`
- `dev`

Esto es senal de release discipline.
No es lo mismo que publicar "main" todo el tiempo.

## Daemonizacion y permanencia

Segun docs y onboarding:

- macOS usa LaunchAgent
- Linux/WSL2 usa systemd user service

Eso cambia por completo la experiencia:

- el gateway vive aunque cierres una terminal
- el asistente realmente queda "always on"

## Packaging de apps nativas

El repo tambien contiene:

- scripts de codesign y notarization
- appcast
- flows de beta iOS
- packaging de app macOS

Eso confirma que OpenClaw ya opera como producto distribuido en varios formatos.

## Operacion diaria

Ademas del packaging, el repo incluye mucho tooling para operar:

- `openclaw doctor`
- health checks
- status commands
- plugins doctor
- logging docs
- scripts de restart, auth status y recovery

## Por que esta capa explica la adopcion

Porque muchas personas no usan una herramienta solo por sus features.
La usan cuando:

- la pueden instalar rapido
- la pueden actualizar sin drama
- no depende de una sola terminal viva
- tienen docs y rutas de recovery

OpenClaw ya penso bastante en eso.

## Conclusion

OpenClaw ya es consumible porque tiene varias rutas de empaquetado y operacion reales:

- npm
- Docker
- clientes nativos
- despliegue remoto
- canales de release
- comandos de diagnosis

