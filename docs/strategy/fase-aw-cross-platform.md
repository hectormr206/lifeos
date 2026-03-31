# Fase AW: Cross-Platform Controller

> Estado: VISION FUTURA
> Investigacion completa: [docs/research/cross-platform-controller/README.md](../research/cross-platform-controller/README.md)

## Objetivo

Convertir LifeOS en el cerebro central que gobierna todos los dispositivos del usuario.
Un solo asistente (Axi) que te sigue a todas partes: desktop, laptop, telefono, tablet.

## Sub-fases

### AW.1: Infraestructura Base (2 semanas)

- [ ] Integrar Tailscale en daemon para NAT traversal
- [ ] Client registry: registro de dispositivos, heartbeat, capabilities
- [ ] Extender protocolo WebSocket con device_id, platform, capabilities
- [ ] Push notifications: Firebase (Android) + APNS (iOS)

### AW.2: Android Client (4-6 semanas)

- [ ] App Kotlin nativa con Rust FFI (uniffi)
- [ ] Texto y voz a Axi
- [ ] Leer notificaciones (NotificationListenerService)
- [ ] Clipboard sync
- [ ] Foreground service para background persistente
- [ ] Distribuir via F-Droid + APK directo
- **Nota:** complementa/extiende Fase AT

### AW.3: Windows Client (2-3 semanas)

- [ ] App Tauri 2.0 (Rust + WebView2)
- [ ] System tray con acceso rapido a Axi
- [ ] Clipboard sync
- [ ] Notificaciones nativas
- [ ] Screen reading via UI Automation API
- [ ] Autostart con Task Scheduler

### AW.4: macOS Client (1-2 semanas)

- [ ] Adaptar app Tauri de Windows
- [ ] Menu bar app
- [ ] Permisos de Accessibility
- [ ] Firmar con Apple Developer ID o distribuir sin firma con instrucciones

### AW.5: iOS Client (6-8 semanas)

- [ ] App Swift nativa con Rust C FFI
- [ ] Voz y camera como inputs principales
- [ ] Siri Shortcuts integration
- [ ] Widgets para Home Screen
- [ ] Background limitado via BGTaskScheduler
- [ ] Distribuir via TestFlight inicialmente, App Store despues

## Orden Recomendado

1. AW.1 (infra) -> AW.2 (Android) -> AW.3 (Windows) -> AW.4 (macOS) -> AW.5 (iOS)
2. Total estimado: 15-21 semanas

## Dependencias

- Fase AQ (personalizacion): User Model se sincroniza entre dispositivos
- Fase AT (Android nativa): AW.2 extiende o reemplaza AT
- Tailscale o Headscale para NAT traversal

## Metricas de Exito

- Axi responde desde al menos 2 plataformas distintas
- Clipboard sync funciona entre Linux y Android
- Latencia mensaje-respuesta < 2 segundos via Tailscale
