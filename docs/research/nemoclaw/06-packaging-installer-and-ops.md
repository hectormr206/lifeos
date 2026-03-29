# 06 - Packaging, Installer And Ops

## Installer como superficie principal

`../NemoClaw-main/install.sh` no es un script minimo.
Es un instalador bastante productizado:

- resuelve version desde release o tag
- muestra UX cuidada de terminal
- instala prerequisitos
- detecta PATH y shims
- puede correr onboarding al final
- da siguientes pasos claros

Eso se alinea con el posicionamiento del proyecto:

- usuario final primero
- repo y docs despues

## Packaging real

En `package.json`, NemoClaw publica el binario `nemoclaw` y empaqueta:

- `bin/`
- `nemoclaw/dist/`
- manifest del plugin
- `nemoclaw-blueprint/`
- `scripts/`
- Dockerfiles relevantes

Y depende de `openclaw@2026.3.11`.

Eso deja clara la relacion:

- OpenClaw es dependencia
- NemoClaw empaqueta la operacion alrededor

## Scripts operativos

Los scripts mas relevantes son:

- `scripts/install.sh`: wrapper legacy
- `scripts/install-openshell.sh`: bootstrap de OpenShell
- `scripts/start-services.sh`: Telegram bridge + cloudflared
- `scripts/nemoclaw-start.sh`: arranque del runtime dentro del sandbox
- `scripts/setup.sh`: setup guiado/no interactivo
- `scripts/brev-setup.sh`: ruta de despliegue remoto
- `scripts/debug.sh`: debugging y redaccion de secretos

## Servicios auxiliares

`start-services.sh` deja ver que NemoClaw no se queda en el sandbox:

- puede levantar bridge de Telegram
- puede publicar dashboard via cloudflared
- maneja PID files y logs por sandbox

Eso extiende el producto hacia "always-on assistant" de forma practica.

## El bridge de Telegram

`scripts/telegram-bridge.js` implementa un puente directo:

- lee mensajes desde Telegram
- ejecuta el agente dentro del sandbox por SSH
- devuelve la respuesta al chat
- mantiene typing indicator
- filtra chats permitidos si se configura

No es un canal profundo tipo OpenClaw nativo.
Es un puente operativo util para demo, soporte y uso remoto.

## Docs como parte de ops

La carpeta `docs/` cubre:

- quickstart
- architecture
- commands
- inference
- network policy
- monitoring
- troubleshooting
- backup/restore
- deploy remoto

Eso es importante porque el repo no obliga a leer codigo para operar el sistema.

## Conclusion de ops

NemoClaw funciona mejor de lo que cabria esperar de un alpha porque invierte bastante en:

- instalador
- docs
- recovery
- scripts de servicio
- rutas concretas de deploy y troubleshooting
