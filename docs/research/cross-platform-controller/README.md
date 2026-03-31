# Investigacion: Cross-Platform Controller

> LifeOS como cerebro central que gobierna todos los dispositivos del usuario.
> Fecha: 2026-03-30

---

## 1. Vision

LifeOS corre en una maquina Linux (desktop/mini-PC) como servidor central. Clientes ligeros en
Windows, Mac, Android e iOS se conectan al servidor y extienden los sentidos de Axi a cada
dispositivo. El usuario tiene UN asistente que lo sigue a todas partes.

```
                    +-------------------+
                    |   LifeOS Server   |
                    |  (Linux, Fedora   |
                    |   bootc, GPU)     |
                    +--------+----------+
                             |
              WebSocket + Tailscale/WireGuard
                             |
         +--------+----------+----------+--------+
         |        |          |          |        |
      Windows   macOS     Android     iOS    Linux
      (Tauri)  (Tauri)   (Kotlin+   (Swift)  (nativo)
                          Rust FFI)
```

---

## 2. Arquitectura

### 2.1 Servidor (ya existe parcialmente)

| Componente | Estado | Descripcion |
|-----------|--------|-------------|
| WebSocket gateway | EXISTE | `/ws` en daemon, bidireccional, JSON |
| REST API | EXISTE | `/api/v1/*` con auth por token |
| LLM Router | EXISTE | 13+ providers, fallback automatico |
| Telegram bot | EXISTE | Texto, voz, archivos, comandos |
| Event bus | EXISTE | Publicar/suscribir eventos internos |
| Tailscale tunnel | PENDIENTE | NAT traversal para acceso remoto |
| Client registry | PENDIENTE | Registro de dispositivos conectados |
| Push notifications | PENDIENTE | Firebase/APNS para mobile |

### 2.2 Protocolo de Comunicacion

El protocolo ya esta parcialmente definido (WebSocket JSON). Se extiende asi:

```json
{
  "type": "message|command|event|stream|sync",
  "device_id": "pixel7-abc123",
  "platform": "android",
  "capabilities": ["screen_read", "notifications", "clipboard", "voice", "camera"],
  "payload": { ... },
  "timestamp": "2026-03-30T12:00:00Z"
}
```

**Tipos de mensaje:**
- `message`: texto/voz del usuario a Axi
- `command`: accion que Axi quiere ejecutar en el dispositivo
- `event`: notificacion/cambio de estado del dispositivo
- `stream`: audio/video en tiempo real
- `sync`: sincronizacion de estado (clipboard, archivos, contexto)

### 2.3 NAT Traversal (Tailscale / WireGuard)

- **Problema:** el servidor LifeOS esta detras de NAT domestico.
- **Solucion:** Tailscale (basado en WireGuard) crea VPN mesh sin abrir puertos.
- **Gratis:** hasta 100 dispositivos en plan personal.
- **Alternativa self-hosted:** Headscale (servidor Tailscale open-source).
- **Implementacion:** daemon corre `tailscaled`, expone IP de tailnet. Clientes se unen al mismo tailnet.

---

## 3. Clientes por Plataforma

### 3.1 Linux (nativo)

- **Estado:** YA EXISTE. CLI `life` + daemon `lifeosd`.
- **Capacidades:** todas (screen read, X11/Wayland, clipboard, audio, archivos, systemd).
- **Restricciones:** ninguna relevante.

### 3.2 Windows (Tauri)

- **Tecnologia:** Tauri 2.0 (Rust backend + WebView2 frontend)
- **Por que Tauri:** binario ~5MB (vs ~150MB Electron), Rust nativo, acceso a APIs del SO
- **Capacidades:**
  - Clipboard: si (API de Windows)
  - Notificaciones: si (toast notifications)
  - Screen read: parcial (accessibility API, UI Automation)
  - Voz: si (Windows Speech API o Whisper local)
  - Autostart: si (registro de Windows, Task Scheduler)
  - System tray: si (iconos en bandeja)
- **Restricciones:**
  - No puede controlar aplicaciones tan profundamente como en Linux (no hay equivalente a D-Bus universal)
  - Antivirus puede bloquear acceso a pantalla/teclado
  - UAC limita acciones administrativas
- **Esfuerzo estimado:** 2-3 semanas para MVP

### 3.3 macOS (Tauri)

- **Tecnologia:** Tauri 2.0 (mismo codigo base que Windows, con adaptaciones)
- **Capacidades:**
  - Clipboard: si (NSPasteboard)
  - Notificaciones: si (UserNotifications framework)
  - Screen read: parcial (Accessibility API, requiere permiso explicito)
  - Voz: si (Speech framework o Whisper local)
  - Autostart: si (LaunchAgent)
  - Menu bar app: si (icono en barra superior)
- **Restricciones:**
  - Gatekeeper: requiere firmar con Apple Developer ID ($99/ano) o instruir al usuario para aceptar
  - Accessibility: el usuario debe dar permisos manualmente en System Preferences
  - App Sandbox: limita acceso a archivos y red si se distribuye por App Store
- **Esfuerzo estimado:** 2-3 semanas para MVP (si Windows ya existe, ~1 semana adicional)

### 3.4 Android (Kotlin + Rust FFI)

- **Tecnologia:** Kotlin nativo + libreria Rust via JNI/uniffi
- **Por que no Tauri:** en mobile, Tauri es inmaduro. Kotlin nativo da acceso completo a APIs de Android.
- **Capacidades:**
  - Notificaciones: si (leer y crear, requiere NotificationListenerService)
  - Clipboard: si (ClipboardManager)
  - Voz: si (SpeechRecognizer + Whisper)
  - Camera: si (CameraX)
  - Ubicacion: si (FusedLocationProvider)
  - Screen read: parcial (AccessibilityService, requiere permiso manual)
  - Archivos: si (Storage Access Framework)
  - Contactos/Calendario: si (ContentProvider)
  - Sensores: si (acelerometro, giroscopio, luz, etc.)
- **Restricciones:**
  - Background limits: Android mata servicios en background agresivamente
  - Solucion: foreground service con notificacion persistente
  - Google Play: podrian rechazar por uso de AccessibilityService
  - Solucion: distribuir via F-Droid + APK directo
- **Esfuerzo estimado:** 4-6 semanas para MVP
- **Nota:** Fase AT ya documenta esta app en detalle.

### 3.5 iOS (Swift)

- **Tecnologia:** Swift nativo + libreria Rust via C FFI (swift-bridge o cbindgen)
- **Capacidades:**
  - Notificaciones: crear si, leer las de otras apps NO
  - Clipboard: si (UIPasteboard, pero solo en foreground)
  - Voz: si (Speech framework + Whisper)
  - Camera: si (AVFoundation)
  - Ubicacion: si (CoreLocation)
  - Screen read: NO (Apple no permite)
  - Archivos: limitado (solo dentro de sandbox de la app)
  - Contactos/Calendario: si (con permiso)
  - Shortcuts/Siri: si (App Intents, Shortcuts framework)
- **Restricciones SEVERAS:**
  - No puede leer pantalla de otras apps
  - No puede leer notificaciones de otras apps
  - Background execution muy limitado (BGTaskScheduler, max ~30s)
  - App Store Review: estricto, pueden rechazar por "demasiados permisos"
  - Requiere Apple Developer Program ($99/ano)
  - No se puede distribuir fuera del App Store (excepto EU con DMA)
- **Esfuerzo estimado:** 6-8 semanas para MVP
- **Estrategia:** enfocarse en lo que SI puede: voz, camara, ubicacion, Siri Shortcuts, widgets.

---

## 4. Matriz de Capacidades por Plataforma

| Capacidad | Linux | Windows | macOS | Android | iOS |
|-----------|-------|---------|-------|---------|-----|
| Texto a Axi | FULL | FULL | FULL | FULL | FULL |
| Voz a Axi | FULL | FULL | FULL | FULL | FULL |
| Leer pantalla | FULL | PARCIAL | PARCIAL | PARCIAL | NO |
| Controlar apps | FULL | PARCIAL | PARCIAL | PARCIAL | NO |
| Clipboard sync | FULL | FULL | FULL | FULL | PARCIAL |
| Notificaciones | FULL | FULL | FULL | FULL | CREAR |
| Archivos | FULL | FULL | FULL | FULL | SANDBOX |
| Ubicacion | N/A | N/A | N/A | FULL | FULL |
| Camera | FULL | FULL | FULL | FULL | FULL |
| Background | FULL | FULL | FULL | PARCIAL | MUY LIMITADO |
| Autostart | FULL | FULL | FULL | PARCIAL | NO |
| System tray | FULL | FULL | FULL | NOTIF BAR | NO |

---

## 5. Precedentes y Competencia

### 5.1 Apple Continuity

- **Que hace:** clipboard universal, handoff de apps, AirDrop, llamadas en Mac, SMS en Mac
- **Limitacion:** solo ecosistema Apple. Cerrado. No extensible.
- **Leccion para LifeOS:** la experiencia cross-device es transformacional. Usuarios la aman.

### 5.2 KDE Connect

- **Que hace:** notificaciones, clipboard, transferencia de archivos, control remoto, SMS
- **Plataformas:** Linux, Android, Windows (parcial)
- **Limitacion:** no tiene AI, no tiene voz, no tiene screen reading. Solo sincroniza.
- **Leccion para LifeOS:** el protocolo KDE Connect es simple y funciona bien. Inspiracion para el nuestro.

### 5.3 Home Assistant

- **Que hace:** automatizacion del hogar. Servidor central + apps companion.
- **Plataformas:** Linux (servidor), Android, iOS (apps)
- **Limitacion:** enfocado en IoT, no en AI personal.
- **Leccion para LifeOS:** modelo servidor+companion funciona. Su app iOS es un buen ejemplo de lo que se puede hacer dentro de las restricciones de Apple.

### 5.4 Pushbullet / Join

- **Que hace:** notificaciones cross-device, clipboard, links, archivos
- **Limitacion:** servicio cloud centralizado, no AI
- **Leccion para LifeOS:** la gente paga por sincronizar notificaciones. Hay mercado.

### 5.5 Beeper / Matrix

- **Que hace:** unifica todos los chats (WhatsApp, Telegram, Signal, etc.)
- **Limitacion:** solo mensajeria, no asistente AI
- **Leccion para LifeOS:** Axi podria ser la interfaz unificada de TODAS las comunicaciones.

---

## 6. Orden de Implementacion Recomendado

1. **Tailscale integration** (1 semana) — habilitar acceso remoto seguro al servidor
2. **Client registry + protocol** (1 semana) — registro de dispositivos, heartbeat, capabilities
3. **Android MVP** (4-6 semanas) — mercado mas grande, menos restricciones que iOS
4. **Windows Tauri** (2-3 semanas) — segundo mercado mas grande
5. **macOS Tauri** (1-2 semanas) — reusar codigo de Windows
6. **iOS MVP** (6-8 semanas) — al final por restricciones severas

**Total estimado:** 15-21 semanas para cubrir todas las plataformas con MVP funcional.

---

## 7. Decisiones Tecnicas Clave

### Tauri vs Flutter vs React Native

| Criterio | Tauri | Flutter | React Native |
|----------|-------|---------|-------------|
| Tamano binario | ~5MB | ~15MB | ~30MB |
| Lenguaje backend | Rust (ya lo usamos) | Dart | JS/TS |
| Desktop soporte | Excelente | Bueno | Limitado |
| Mobile soporte | Inmaduro | Excelente | Excelente |
| Acceso nativo | Via Rust plugins | Via platform channels | Via native modules |

**Decision:** Tauri para desktop (Windows/Mac), nativo para mobile (Kotlin/Swift).
Razon: reutilizamos Rust, binarios pequenos en desktop, acceso completo a APIs en mobile.

### Protocolo: WebSocket vs gRPC vs MQTT

| Criterio | WebSocket | gRPC | MQTT |
|----------|-----------|------|------|
| Ya implementado | SI | No | No |
| Bidireccional | SI | SI (streaming) | SI |
| Mobile friendly | SI | Parcial | SI |
| Browser friendly | SI | No (sin proxy) | No |
| Overhead | Bajo | Bajo | Muy bajo |

**Decision:** mantener WebSocket (ya existe). Agregar MQTT solo si se integran dispositivos IoT.

---

## 8. Riesgos y Mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|-----------|
| Apple rechaza app iOS | Alta | Medio | Distribuir via TestFlight/AltStore. EU: sideloading legal |
| Android mata servicio background | Alta | Medio | Foreground service + battery optimization whitelist |
| Tailscale cambia plan gratis | Baja | Alto | Headscale self-hosted como fallback |
| Google Play rechaza por AccessibilityService | Media | Medio | F-Droid + APK directo |
| Mantenimiento de 5 plataformas | Alta | Alto | Maximizar codigo Rust compartido via FFI |

---

## Notas Finales

- **Empezar con Android:** mas usuarios, menos restricciones, Fase AT ya documenta la app.
- **iOS es el mas restrictivo:** planificar features alrededor de lo que Apple permite.
- **El servidor LifeOS ya tiene el 70% de la infra necesaria** (WebSocket, API, LLM, event bus).
- **Tailscale es el habilitador clave:** sin NAT traversal, el cross-platform no funciona fuera de LAN.
