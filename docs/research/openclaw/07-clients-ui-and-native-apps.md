# 07 - Clients, UI, And Native Apps

## Tesis

OpenClaw no depende de una sola interfaz.
Tiene varias superficies serias de operacion y eso multiplica su utilidad real.

## Superficies principales

Segun el repo y la documentacion, el producto se opera desde:

- CLI
- Control UI / WebChat
- app de macOS
- app de iOS
- app de Android
- nodos headless

Todas se conectan al mismo gateway protocol.

## UI web

La carpeta `ui/` no es un demo sencillo.
Contiene:

- estado de conexion al gateway
- sesiones
- chat
- cron
- config
- canales
- nodos
- exec approvals
- logs
- usage
- i18n

El hecho de que existan tantos `*.test.ts` en `ui/src/ui/` y `ui/src/ui/controllers/` dice mucho:

- la UI es una superficie operacional de verdad
- no solo un panel bonito

## Control UI y WebChat

En la arquitectura de OpenClaw, la web UI no vive aparte del producto.

El gateway:

- sirve la superficie web
- usa el mismo auth model
- usa el mismo protocolo WS
- comparte estado con el resto de clientes

Eso reduce drift entre "API real" y "panel web".

## App de macOS

`apps/macos/` es una pieza enorme del producto.

Al revisar nombres de archivos, se ve que la app de macOS hace mucho mas que abrir una ventana:

- menu bar app
- onboarding
- gateway process management
- launch agents
- channels settings
- cron jobs
- config store
- nodes menu
- pairing approval UI
- exec approvals
- canvas windows
- voice wake y overlays
- remote tunneling
- Tailscale integration

Interpretacion:

- la app de macOS es operador, nodo y shell de producto a la vez

## App de iOS

`apps/ios/` muestra un nodo movil bastante completo:

- gateway pairing
- QR scanner
- health monitoring
- camera
- location
- motion
- screen recording
- push relay
- reminders/contacts/calendar
- voice wake y talk mode
- chat sheet

No es "una app compañera minima".
Es un nodo de dispositivo real.

## Android

La app Android sigue la misma idea:

- capacidad de nodo
- integracion de comandos del dispositivo
- superficies de chat y voz
- screen y camera
- tests e integracion

## `OpenClawKit`

La carpeta `apps/shared/OpenClawKit` es probablemente una de las piezas mas importantes para la calidad del ecosistema Apple.

Ahí viven:

- modelos del protocolo
- gateway payload decoding
- device auth
- node session
- commands de camera/canvas/location/screen/system/talk
- Chat UI shared
- TLS pinning
- keychain stores
- deep links
- tests de seguridad y parsing

Esto permite:

- reutilizar logica entre macOS e iOS
- bajar drift entre clientes
- consolidar protocolos y seguridad en un solo lugar

## Por que esta capa importa tanto

Muchos proyectos de asistentes tienen:

- un backend
- una CLI
- y luego "algun dia" una app

OpenClaw ya cruzo esa barrera.

Tiene clients reales que:

- descubren gateways
- pairan dispositivos
- muestran approvals
- operan cron y sesiones
- usan voice/canvas/chat

## Efecto en adopcion

Esto explica mucho de la sensacion de producto terminado:

- el usuario puede entrar por CLI
- o por navegador
- o por macOS menu bar
- o por movil

Y todos hablan el mismo idioma.

## Conclusion

OpenClaw ya se usa como sistema real porque no depende de una unica UX.
Construyo varias superficies operatorias coherentes sobre el mismo control plane.
