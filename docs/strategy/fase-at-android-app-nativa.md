# Fase AT — App Android Nativa: Todos los Sentidos de Axi en CUALQUIER Telefono

> Alternativa practica a la Fase AS (custom ROM). App nativa que corre en cualquier Android stock, GrapheneOS, o cualquier ROM.

**Objetivo:** Dar a Axi todos los "sentidos" posibles en Android (voz, vision, lectura de pantalla, notificaciones, ubicacion, salud, movimiento) usando APIs estandar de Android, sin requerir ROM personalizado ni dispositivo especifico.

**Investigacion (2026-03-30):** Analisis de APIs de Android para AccessibilityService, NotificationListenerService, CameraX, Health Connect, AudioRecord, SensorManager, FusedLocationProvider, SYSTEM_ALERT_WINDOW. Revision de llama.cpp/whisper.cpp en Android via JNI/NDK.

**Dispositivo minimo:** Cualquier Android 10+ (API 29) con 6+ GB RAM para inferencia local.

---

## Por que App Nativa es el Paso PRACTICO

| Criterio | App Nativa (Fase AT) | Custom ROM (Fase AS) |
|----------|---------------------|---------------------|
| **Dispositivos** | Cualquier Android 10+ | Solo Pixel |
| **Instalacion** | APK o F-Droid | Flashear ROM completo |
| **Esfuerzo** | 2-3 meses MVP | 6-9 meses |
| **Riesgo** | Bajo | Alto (mantener ROM) |
| **Cobertura de sentidos** | ~90% | 100% |
| **Actualizaciones** | Independientes del OS | Atadas al ROM |
| **Base de usuarios** | Todos con Android | Solo usuarios avanzados |

**Conclusion:** La app nativa cubre el 90% de las capacidades con 30% del esfuerzo. El 10% restante (wake word system-wide, audio pipeline custom, boot daemon) solo es posible con ROM propio y no justifica el costo para MVP.

---

## Los Sentidos de Axi en Android

### 1. Oido (Voz) — AudioRecord + whisper.cpp

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| Captura de audio | `AudioRecord` API | PCM 16kHz mono |
| STT on-device | whisper.cpp via JNI/NDK | Modelo base (~142 MB), tiempo real |
| Wake word | Modelo custom ligero (~2 MB) | Deteccion "Hey Axi" siempre activa |
| Servicio persistente | `ForegroundService` tipo `microphone` | Notificacion permanente requerida |

**Restricciones Android:**
- Android 14+: Servicio foreground con tipo `microphone` requiere permiso `FOREGROUND_SERVICE_MICROPHONE`
- El usuario debe aprobar permisos explicitamente
- Hay limite de 6 horas para servicios `dataSync`, pero `microphone` no tiene timeout
- `VoiceInteractionService` permite iniciar desde background (ideal para asistente de voz)

**Implementacion whisper.cpp:**
- JNI bridge: Kotlin llama a funciones C++ nativas via NDK
- Proyectos de referencia: [WhisperKit Android](https://github.com/argmaxinc/WhisperKitAndroid), [whispercpp-android](https://github.com/mikeesto/whispercpp-android)
- Audio debe ser 16kHz; requiere resampling desde la captura nativa

### 2. Habla (TTS) — Piper / Android TTS

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| TTS neuronal | Piper via ncnn/NDK | Voces es_MX, ~15-80 MB |
| TTS fallback | Android `TextToSpeech` API | Siempre disponible, calidad basica |
| Salida audio | `AudioTrack` / `MediaPlayer` | Control total de reproduccion |

**Piper en Android:**
- Implementacion via [ncnn-android-piper](https://github.com/nihui/ncnn-android-piper)
- Modelos VITS optimizados con ONNX, 35+ idiomas
- Piper fue archivado Oct 2025; fork GPL-3.0 por [Open Home Foundation](https://github.com/OHF-Voice/piper1-gpl) — verificar licencia

### 3. Vision (Camara) — CameraX API

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| Captura | CameraX (Jetpack) | Compatible Android 5.0+, consistente en todos los dispositivos |
| Analisis tiempo real | `ImageAnalysis.Analyzer` | Frame-by-frame, CPU-accessible buffer |
| Vision AI | LLM multimodal local o servidor | SmolVLM2, LLaVA, o enviar al desktop |
| OCR | ML Kit Text Recognition | On-device, gratis |

**Capacidades:**
- "Axi, que estoy viendo?" — analizar escena en tiempo real
- "Lee este documento" — OCR + interpretacion
- Captura rapida de fotos para sync al servidor
- CameraX maneja ciclo de vida automaticamente con Jetpack

### 4. Lectura de Pantalla — AccessibilityService

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| Leer cualquier app | `AccessibilityService` | Arbol de nodos UI de TODAS las apps |
| Extraer texto | `AccessibilityNodeInfo` | Texto, descripciones, estados |
| Automatizar acciones | `performAction()` | Click, scroll, escribir texto |
| Gestos programaticos | `GestureDescription` | Simular toques y swipes |

**Esto es el sentido mas poderoso.** AccessibilityService permite:
- Leer el contenido de CUALQUIER app visible (WhatsApp, email, browser, etc.)
- Entender el contexto visual sin necesitar integracion con cada app
- Ejecutar acciones: "Responde a este mensaje con X"
- Extraer datos estructurados del arbol de accesibilidad

**Ejemplo real:** [Arc AI](https://rethink-hub.github.io/arc/) usa AccessibilityService para resumir, leer y chatear sobre contenido on-screen.

**Permisos:**
- El usuario debe habilitar manualmente en Settings > Accessibility
- Es un permiso sensible; Google Play tiene politicas estrictas (F-Droid no)
- No requiere root ni ROM custom

### 5. Notificaciones — NotificationListenerService

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| Interceptar todas | `NotificationListenerService` | Todas las notificaciones del sistema |
| Datos disponibles | `StatusBarNotification` | App, titulo, texto, timestamp, extras |
| Acciones | `cancelNotification()` | Dismissear notificaciones |
| Filtrado AI | LLM local | Clasificar urgencia, resumir |

**Implementacion:**
- Callbacks: `onNotificationPosted()` y `onNotificationRemoved()`
- `getActiveNotifications()` para obtener todas las activas
- El usuario debe otorgar acceso en Settings > Notifications > Notification access
- Referencia: [notification-listener-service-example](https://github.com/Chagall/notification-listener-service-example)

**Casos de uso Axi:**
- "Tienes 3 mensajes importantes y 12 spam — quieres que te resuma los importantes?"
- Filtrado inteligente basado en contexto (reunion, conduciendo, durmiendo)
- Respuestas rapidas sin abrir la app original

### 6. Ubicacion — FusedLocationProvider

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| GPS | `FusedLocationProviderClient` | Alta precision, bajo consumo |
| Geofencing | `GeofencingClient` | Detectar entrada/salida de zonas |
| Contexto | Location + hora + actividad | "En oficina", "En casa", "Viajando" |

**Casos de uso:**
- Context switching automatico (modo trabajo, casa, gym)
- "Recuerdame comprar leche cuando pase por el super"
- Historial de ubicacion para memoria contextual de Axi

### 7. Salud — Health Connect API

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| Pasos | `StepsRecord` | Conteo diario |
| Ritmo cardiaco | `HeartRateRecord` | BPM en tiempo real (con wearable) |
| Sueno | `SleepSessionRecord` | Duracion, etapas, calidad |
| Ejercicio | `ExerciseSessionRecord` | Tipo, duracion, calorias |
| Oxigeno | `OxygenSaturationRecord` | SpO2 (con sensor) |

**Health Connect:**
- API unificada de Google para datos de salud (reemplaza Google Fit)
- Compatible con Samsung Health, Fitbit, Garmin, Withings, etc.
- SDK 1.1.0+, permisos granulares por tipo de dato
- Referencia: [Health Connect Codelab](https://developer.android.com/codelabs/health-connect)

**Casos de uso Axi:**
- "Dormiste 5.5 horas — quieres que ajuste tu agenda de manana?"
- "Llevas 2000 pasos hoy, tu meta es 8000. Sugerencia: caminar 20 min despues de comer"
- Correlacionar sueno + productividad + animo

### 8. Movimiento — SensorManager

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| Acelerometro | `Sensor.TYPE_ACCELEROMETER` | Movimiento, caidas |
| Giroscopio | `Sensor.TYPE_GYROSCOPE` | Rotacion, orientacion |
| Actividad | Activity Recognition API | Caminando, corriendo, en vehiculo |
| Proximidad | `Sensor.TYPE_PROXIMITY` | Telefono en bolsillo/mesa |

### 9. Widget Flotante — SYSTEM_ALERT_WINDOW

| Componente | Tecnologia | Detalles |
|-----------|-----------|----------|
| Overlay | `SYSTEM_ALERT_WINDOW` permiso | Dibujar sobre otras apps |
| Widget | `WindowManager` + Compose | Burbuja flotante de Axi |
| Interaccion | Touch events | Tap para comando de voz, drag para mover |

**Implementacion:**
- Tipo de ventana: `TYPE_APPLICATION_OVERLAY` (Android 8+)
- El usuario otorga permiso en Settings > Apps > Display over other apps
- Jetpack Compose compatible via `ComposeView` en overlay service
- Referencia: [Jetpack Compose OverlayService gist](https://gist.github.com/handstandsam/6ecff2f39da72c0b38c07aa80bbb5a2f)

**UX:**
- Burbuja pequena siempre visible (como chat heads de Messenger)
- Tap: activa escucha de voz
- Long press: menu rapido (camara, nota, estado)
- Arrastrar a X para cerrar

---

## Arquitectura

```
Android App (Kotlin + Rust/NDK)          Desktop (lifeosd)
├── AccessibilityService                  ├── LLM grande (4B+)
│   └── Lee pantalla de cualquier app     ├── Memory/RAG completo
├── NotificationListenerService           ├── Task execution
│   └── Filtra/resume notificaciones      ├── Workers asincronos
├── ForegroundService (microphone)        ├── Knowledge graph
│   ├── Wake word "Hey Axi"              └── Dashboard
│   ├── whisper.cpp STT (JNI)
│   └── Piper TTS (NDK)
├── CameraX ImageAnalysis
│   └── Vision AI on-demand
├── Health Connect client
│   └── Steps, HR, sleep, exercise
├── FusedLocation + Geofencing
├── SensorManager (accel, gyro)
├── LLM local (llama.cpp JNI)
│   └── Qwen2.5-3B Q4_K_M (~2.5 GB)
├── SQLite (cola offline)
├── Overlay widget (burbuja Axi)
└── WebSocket client
         ↕ WebSocket (puerto 8081, ya existe en lifeosd)
```

### Flujo de datos

1. **Online:** Sensores/pantalla/notifs → LLM local (clasificacion rapida) → WebSocket → lifeosd (procesamiento complejo) → respuesta → TTS
2. **Offline:** Todo procesado localmente con Qwen2.5-3B. Cola de sync en SQLite para cuando haya conexion
3. **Hibrido:** LLM local decide si puede resolver solo o necesita al servidor (basado en complejidad de la query)

### Seguridad

- WebSocket encriptado (TLS) entre phone y desktop
- Datos de salud/ubicacion nunca salen del dispositivo sin consentimiento explicito
- Cola offline encriptada con AndroidKeyStore
- Sin telemetria, sin analytics, sin cloud de terceros
- F-Droid: codigo 100% auditable

---

## Inferencia Local en Android

### LLM — llama.cpp

| Componente | Modelo | RAM | Velocidad |
|-----------|--------|-----|-----------|
| LLM rapido | Qwen2.5-3B Q4_K_M | ~2.5 GB | 3-8 tok/s (CPU) |
| LLM con GPU | Qwen2.5-3B Q4_K_M + OpenCL | ~2.5 GB | 8-15 tok/s (Adreno GPU) |
| Vision (si hay) | SmolVLM2 | ~1.5 GB | 2-5 tok/s |

**Proyectos de referencia:**
- [SmolChat-Android](https://github.com/shubham0204/SmolChat-Android) — Kotlin + JNI + llama.cpp, streaming, vision
- [Llamatik](https://github.com/ferranpons/Llamatik) — KMP con llama.cpp + whisper.cpp
- [kotlinllamacpp](https://github.com/ljcamargo/kotlinllamacpp) — Bindings Kotlin directos para llama.cpp
- llama.cpp soporta [GPU Adreno via OpenCL](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md)

### STT — whisper.cpp

| Modelo | RAM | Velocidad | Calidad |
|--------|-----|-----------|---------|
| tiny | ~75 MB | 4x real-time | Basica |
| base | ~142 MB | 2x real-time | Buena |
| small | ~466 MB | 1x real-time | Muy buena |

### TTS — Piper

| Voz | RAM | Latencia | Calidad |
|-----|-----|----------|---------|
| es_MX medium | ~50 MB | <200ms | Natural |
| es_MX low | ~15 MB | <100ms | Aceptable |

### Consumo de bateria estimado

| Estado | Consumo | Componentes activos |
|--------|---------|-------------------|
| Idle + wake word | ~3%/hr | AudioRecord + modelo tiny |
| Escucha activa + STT | ~8%/hr | whisper.cpp + AudioRecord |
| Inferencia LLM | ~15%/hr | llama.cpp (CPU/GPU) |
| Vision activa | ~20%/hr | CameraX + analisis |
| Todo apagado | ~0.5%/hr | Solo WebSocket keepalive |

---

## Stack Tecnologico

| Capa | Tecnologia | Justificacion |
|------|-----------|---------------|
| UI | Kotlin + Jetpack Compose | Estandar moderno Android, declarativo |
| Logica de negocio | Kotlin Coroutines | Async nativo, lifecycle-aware |
| LLM inference | Rust + llama.cpp (JNI/NDK) | Rendimiento nativo, ya tenemos expertise Rust |
| STT | whisper.cpp (JNI/NDK) | Mejor STT offline disponible |
| TTS | Piper (ncnn/NDK) o Android TTS | Neural TTS local |
| Base de datos local | Room (SQLite) | Cola offline, cache, preferencias |
| Networking | OkHttp + WebSocket | Cliente WebSocket a lifeosd |
| DI | Hilt/Koin | Inyeccion de dependencias estandar |
| Build | Gradle + Cargo (NDK) | Kotlin + Rust cross-compilation |
| CI/CD | GitHub Actions | Build APK, lint, test |
| Distribucion | F-Droid + APK directo | Sin dependencia de Google Play |

### Estructura del proyecto

```
axi-android/
├── app/
│   ├── src/main/
│   │   ├── kotlin/com/lifeos/axi/
│   │   │   ├── MainActivity.kt
│   │   │   ├── ui/                    # Jetpack Compose screens
│   │   │   ├── services/
│   │   │   │   ├── AxiAccessibilityService.kt
│   │   │   │   ├── AxiNotificationListener.kt
│   │   │   │   ├── AxiVoiceService.kt
│   │   │   │   └── AxiOverlayService.kt
│   │   │   ├── sensors/
│   │   │   │   ├── LocationManager.kt
│   │   │   │   ├── HealthManager.kt
│   │   │   │   └── MotionManager.kt
│   │   │   ├── ai/
│   │   │   │   ├── LlamaInference.kt  # JNI bridge
│   │   │   │   ├── WhisperSTT.kt      # JNI bridge
│   │   │   │   └── PiperTTS.kt        # NDK bridge
│   │   │   ├── network/
│   │   │   │   └── LifeOSWebSocket.kt
│   │   │   └── data/
│   │   │       ├── OfflineQueue.kt
│   │   │       └── SensorStore.kt
│   │   ├── res/
│   │   └── AndroidManifest.xml
│   └── build.gradle.kts
├── rust-bridge/                        # Rust JNI crate
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── llama_jni.rs
│       └── whisper_jni.rs
├── build.gradle.kts
└── fdroid/
    └── metadata/
```

---

## Distribucion

### F-Droid (principal)

- App 100% open source — cumple requisitos F-Droid
- Sin Google Play Services requeridos
- Sin trackers, analytics, ni telemetria
- Metadata YAML en repo fdroiddata
- Build reproducible desde source
- Referencia: [F-Droid Quick Start Guide](https://f-droid.org/en/docs/Submitting_to_F-Droid_Quick_Start_Guide/)

**Nota importante (2025):** Google anuncio requisito de verificacion de identidad para TODOS los desarrolladores Android, incluyendo los que no distribuyen via Google Play. F-Droid esta trabajando en soluciones legales. Monitorear situacion.

### APK directo (secundario)

- Descarga desde sitio web de LifeOS
- Auto-update via in-app updater
- Para usuarios que no usan F-Droid
- Requiere "Install from unknown sources"

### NO Google Play (por ahora)

- Requiere cuenta de desarrollador ($25 + verificacion ID)
- Politicas restrictivas sobre AccessibilityService
- Revisiones lentas y arbitrarias
- Si el proyecto crece, considerar en el futuro

---

## Comparacion: Fase AT (App) vs Fase AS (ROM)

| Capacidad | Fase AT (App) | Fase AS (ROM) |
|-----------|--------------|--------------|
| STT/TTS on-device | Si (JNI) | Si (nativo) |
| LLM local | Si (JNI) | Si (nativo) |
| Leer pantalla | Si (AccessibilityService) | Si (system-level) |
| Notificaciones | Si (NotificationListener) | Si (system-level) |
| Camara/Vision | Si (CameraX) | Si (system camera) |
| Ubicacion | Si (FusedLocation) | Si (nativo) |
| Salud | Si (Health Connect) | Si (Health Connect) |
| Wake word system-wide | Parcial (foreground svc) | Si (siempre) |
| Audio pipeline custom | No | Si |
| Boot daemon | No | Si |
| System-wide overlay | Si (SYSTEM_ALERT_WINDOW) | Si (system UI) |
| Automatizar cualquier app | Si (Accessibility gestos) | Si (root access) |
| Funciona en cualquier Android | **Si** | Solo Pixel |
| Instalacion simple | **APK / F-Droid** | Flashear ROM |
| Sin riesgo brick | **Si** | Posible |

---

## Permisos Requeridos

```xml
<!-- Voz -->
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />

<!-- Camara -->
<uses-permission android:name="android.permission.CAMERA" />

<!-- Ubicacion -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />

<!-- Overlay -->
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />

<!-- Internet (WebSocket a lifeosd) -->
<uses-permission android:name="android.permission.INTERNET" />

<!-- Sensores -->
<uses-permission android:name="android.permission.BODY_SENSORS" />
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />

<!-- Health Connect — declarados en metadata, no en manifest -->
<!-- Notificaciones — habilitadas manualmente por usuario -->
<!-- Accesibilidad — habilitada manualmente por usuario -->
```

**Permisos que requieren habilitacion manual:**
1. AccessibilityService — Settings > Accessibility
2. NotificationListenerService — Settings > Notifications > Notification access
3. Display over other apps — Settings > Apps > Display over other apps
4. Background location — Prompt del sistema

---

## Checklist de Implementacion

### AT.1 — Skeleton y Infraestructura (Semana 1-2)

- [ ] Crear proyecto Android (Kotlin + Jetpack Compose)
- [ ] Configurar Gradle con NDK para Rust cross-compilation
- [ ] Crear crate `rust-bridge/` con JNI scaffolding
- [ ] Compilar llama.cpp para arm64-v8a via NDK
- [ ] Compilar whisper.cpp para arm64-v8a via NDK
- [ ] CI: GitHub Actions para build APK
- [ ] Estructura de permisos y onboarding flow

### AT.2 — Sentido: Voz (Semana 3-4)

- [ ] `AxiVoiceService` — ForegroundService con AudioRecord
- [ ] JNI bridge para whisper.cpp STT
- [ ] Wake word detection ("Hey Axi") con modelo tiny
- [ ] Piper TTS o Android TTS para respuestas
- [ ] UI: boton de voz + indicador de escucha
- [ ] Test en dispositivo real

### AT.3 — Cerebro Local (Semana 5-6)

- [ ] JNI bridge para llama.cpp
- [ ] Descargar/gestionar modelo Qwen2.5-3B Q4_K_M
- [ ] Streaming de tokens a UI
- [ ] Clasificador rapido: resolver local vs enviar a servidor
- [ ] Chat UI basico con Jetpack Compose
- [ ] Benchmark velocidad y RAM en 3+ dispositivos

### AT.4 — Conexion Desktop (Semana 7)

- [ ] WebSocket client a lifeosd (puerto 8081)
- [ ] Autenticacion con bootstrap-token / api-key
- [ ] Cola offline (Room/SQLite) para mensajes sin conexion
- [ ] Sync bidireccional: phone → desktop, desktop → phone
- [ ] Reconexion automatica con backoff exponencial
- [ ] Indicador de estado conexion en UI

### AT.5 — Sentido: Pantalla (Semana 8)

- [ ] `AxiAccessibilityService` con lectura de arbol UI
- [ ] Extraer texto visible de cualquier app
- [ ] Comandos: "Resume esta pagina", "Que dice este mensaje?"
- [ ] Automatizar acciones: click, scroll, escribir
- [ ] Onboarding claro para habilitar AccessibilityService

### AT.6 — Sentido: Notificaciones (Semana 8-9)

- [ ] `AxiNotificationListener` — interceptar todas las notificaciones
- [ ] Clasificacion AI de urgencia (LLM local)
- [ ] Resumen inteligente: "3 importantes, 12 ignorables"
- [ ] Quick actions desde notificacion de Axi
- [ ] Filtros configurables por app/contacto

### AT.7 — Sentido: Vision (Semana 9-10)

- [ ] Integracion CameraX con ImageAnalysis
- [ ] "Axi, que estoy viendo?" — captura + analisis
- [ ] OCR con ML Kit Text Recognition
- [ ] Enviar imagenes al desktop para analisis con modelo grande
- [ ] Quick capture: foto → sync al servidor

### AT.8 — Sentidos: Ubicacion + Salud + Movimiento (Semana 10-11)

- [ ] FusedLocationProvider + geofencing
- [ ] Health Connect: pasos, sueno, ritmo cardiaco
- [ ] SensorManager: acelerometro, actividad
- [ ] Context engine: combinar todos los sensores para "estado actual"
- [ ] Sync periodico de datos al servidor

### AT.9 — Widget Flotante (Semana 11-12)

- [ ] `AxiOverlayService` con SYSTEM_ALERT_WINDOW
- [ ] Burbuja flotante siempre visible
- [ ] Tap: activar escucha de voz
- [ ] Long press: menu rapido
- [ ] Animaciones de estado (escuchando, pensando, hablando)
- [ ] Quick Settings tile para toggle

### AT.10 — Pulido y Distribucion (Semana 12-13)

- [ ] Onboarding completo con explicacion de cada permiso
- [ ] Settings: configurar servidor, modelo, permisos
- [ ] Battery optimization: throttle inteligente por nivel de bateria
- [ ] Tema oscuro/claro + Material You
- [ ] Preparar metadata F-Droid
- [ ] Build release firmado
- [ ] Publicar en F-Droid
- [ ] Landing page con descarga APK
- [ ] Documentacion de usuario

---

## Metricas de Exito

| Metrica | Target MVP |
|---------|-----------|
| Latencia STT (on-device) | < 2 segundos |
| Latencia LLM local | < 5 segundos primera respuesta |
| Latencia via WebSocket | < 3 segundos (LAN) |
| Bateria idle + wake word | < 3% por hora |
| RAM total (todos los modelos) | < 4 GB |
| Funciona 100% offline | STT + TTS + LLM + sensores |
| Tiempo de onboarding | < 3 minutos |
| Dispositivos compatibles | Android 10+ con 6+ GB RAM |

---

## Riesgos y Mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|-----------|
| Google restringe AccessibilityService | Media | Alto | F-Droid no tiene restricciones de Play Store; sideload siempre funciona |
| Bateria excesiva | Media | Medio | Throttling adaptativo, modos de bajo consumo, wake word ultra-ligero |
| RAM insuficiente en dispositivos baratos | Media | Medio | Modelos tiny como fallback, offload al servidor |
| Latencia LLM inaceptable en CPUs lentas | Baja | Medio | GPU OpenCL en Adreno, o delegar al servidor |
| Cambios en Android APIs | Baja | Bajo | APIs usadas son estables (AccessibilityService desde API 4) |
| F-Droid rechaza la app | Baja | Bajo | Siempre queda sideload APK directo |

---

## Prerequisitos

- [x] Desktop LifeOS estable (fases A-AP completadas)
- [x] WebSocket gateway funcionando (Fase AB)
- [x] Session store (Fase AB.2)
- [x] LLM router con providers multiples
- [ ] Fase AQ (User Model) — recomendado pero no bloqueante
- [ ] Pixel u otro Android para testing fisico

---

## Estimacion de Esfuerzo

| Fase | Semanas | Descripcion |
|------|---------|-------------|
| AT.1 | 2 | Skeleton, NDK, CI |
| AT.2 | 2 | Voz (whisper + wake word + TTS) |
| AT.3 | 2 | LLM local (llama.cpp) |
| AT.4 | 1 | WebSocket a desktop |
| AT.5 | 1 | Lectura de pantalla |
| AT.6 | 1.5 | Notificaciones |
| AT.7 | 1.5 | Vision (camara) |
| AT.8 | 2 | Ubicacion + salud + movimiento |
| AT.9 | 1.5 | Widget flotante |
| AT.10 | 1.5 | Pulido + F-Droid |
| **Total** | **~16** | **~4 meses (1 dev), ~2.5 meses (enfocado)** |

---

## Referencias

- [AccessibilityService API](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService)
- [NotificationListenerService API](https://developer.android.com/reference/android/service/notification/NotificationListenerService)
- [CameraX Overview](https://developer.android.com/media/camera/camerax)
- [Health Connect](https://developer.android.com/health-and-fitness/health-connect)
- [Foreground Service Types](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [llama.cpp Android](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md)
- [SmolChat-Android](https://github.com/shubham0204/SmolChat-Android)
- [WhisperKit Android](https://github.com/argmaxinc/WhisperKitAndroid)
- [ncnn-android-piper](https://github.com/nihui/ncnn-android-piper)
- [Arc AI (AccessibilityService example)](https://rethink-hub.github.io/arc/)
- [F-Droid Submission Guide](https://f-droid.org/en/docs/Submitting_to_F-Droid_Quick_Start_Guide/)
- [Foreground Service Restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [SYSTEM_ALERT_WINDOW Overlay](https://gist.github.com/handstandsam/6ecff2f39da72c0b38c07aa80bbb5a2f)
- [Kotlin Rust JNI Integration](https://markaicode.com/rust-kotlin-integration-2025/)
- [notification-listener-service-example](https://github.com/Chagall/notification-listener-service-example)
