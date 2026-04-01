# Investigacion: Cross-Platform Controller

> LifeOS como cerebro central que gobierna todos los dispositivos del usuario.
> Fecha de validacion web: `2026-03-31`

---

## 1. Vision

LifeOS corre en una maquina Linux como servidor central. Clientes ligeros en otros sistemas se conectan al servidor y extienden los sentidos de Axi a cada dispositivo. La idea no es “copiar LifeOS entero en todos lados”, sino construir un **control plane unificado** con capacidades distintas por plataforma.

```text
                    +-------------------+
                    |   LifeOS Server   |
                    |   Linux + GPU     |
                    |  daemon + memory  |
                    +--------+----------+
                             |
                  WebSocket + secure overlay
                   (Tailscale / Headscale)
                             |
         +--------+----------+----------+--------+
         |        |          |          |        |
      Windows   macOS     Android     iOS    Linux
      (Tauri)  (Tauri)   (native)   (native) (native)
```

---

## 2. Lo que cambio al validar con datos actuales

### 2.1 Tauri ya no debe describirse como “solo desktop”

**Correccion importante:** `Tauri 2.0` ya es oficial y soporta aplicaciones cross-platform modernas, incluyendo soporte movil en el framework.

**Pero** para LifeOS sigue teniendo sentido mantener esta decision:

- **desktop:** `Tauri`
- **mobile:** `nativo` (`Kotlin` / `Swift`)

No porque Tauri “no pueda”, sino porque en mobile LifeOS necesita integracion profunda con:

- servicios en foreground
- notificaciones y listeners
- accesibilidad
- permisos sensibles
- jobs y restricciones del SO
- bridges con audio/camara/ubicacion

Para ese nivel de integracion, hoy **nativo sigue siendo la opcion mas segura**.

**Fuentes:**
- https://tauri.app/
- https://v2.tauri.app/blog/tauri-2-0-0-beta/

### 2.2 Tailscale sigue siendo muy buena opcion, pero con datos mas precisos

La version anterior estaba un poco simplificada.

**Validado hoy:**
- plan `Personal`: `3` usuarios gratis
- limite de `100` dispositivos pooled en la tailnet personal

Eso sigue siendo suficiente para un laboratorio personal o familia pequena, pero conviene documentarlo con precision.

**Alternativa self-hosted real:** `Headscale`, que se define como implementacion open-source y self-hosted del control server de Tailscale, pensada para uso personal u organizaciones pequenas.

**Decision recomendada:**
- fase temprana: `Tailscale`
- fase mas soberana o multiusuario small-scale: `Headscale`

**Fuentes:**
- https://tailscale.com/pricing/
- https://headscale.net/latest/

---

## 3. Arquitectura Actualizada

### 3.1 Servidor central

| Componente | Estado | Nota actualizada |
|-----------|--------|------------------|
| WebSocket gateway | EXISTE | `/ws` ya existe, pero el protocolo sigue basico; no venderlo como control plane cerrado |
| REST API | EXISTE | `/api/v1/*` con token |
| LLM Router | EXISTE | multiproveedor |
| Telegram bot | EXISTE | canal principal remoto actual |
| Event bus | EXISTE | util para fan-out interno |
| Device registry | PENDIENTE | sigue faltando una capa formal de dispositivos y capacidades |
| Push relay | PENDIENTE | necesario para mobile robusto |
| Tailscale / Headscale integration | PENDIENTE | alta prioridad real |

### 3.2 Protocolo recomendado

Seguir sobre WebSocket tiene sentido porque:

- ya existe en el daemon
- funciona bien para browser y desktop
- simplifica streaming y estado
- evita meter gRPC demasiado pronto

Pero ya no conviene dejar el contrato asi de suelto:

```json
{
  "type": "message|command|event|stream|sync",
  "device_id": "pixel7-abc123",
  "platform": "android",
  "capabilities": ["notifications.read", "clipboard.read", "voice.in", "camera.capture"],
  "payload": {},
  "timestamp": "2026-03-31T12:00:00Z"
}
```

### 3.3 Extensiones que faltan al protocolo

Para que esto sea realmente util cross-platform, falta documentar y luego implementar:

- `protocol_version`
- `session_id`
- `device_class` (`desktop`, `phone`, `tablet`, `watch`)
- `transport` (`lan`, `tailnet`, `relay`)
- `permission_state`
- `foreground_state`
- `battery_optimization_state`
- `push_token`
- `last_seen_at`

### 3.4 Stack de control recomendado para LifeOS

Aqui esta la distincion clave que aparecio al analizar demos tipo Claude Dispatch / Cowork:

- una cosa es **ver la pantalla y mover el mouse**
- otra muy distinta es **controlar el sistema y las apps con interfaces estructuradas**

LifeOS no deberia apostar todo a computer use visual. Deberia usar una jerarquia clara:

1. **MCP primero**
2. **Adapters nativos / APIs del sistema despues**
3. **Accesibilidad / UI automation despues**
4. **Vision + mouse + teclado como fallback final**

#### Capa 1: MCP

Esta es la forma ideal de control.

La idea no es un “MCP magico que controla todo el OS”, sino esto:

- el sistema operativo expone capacidades estructuradas via MCP
- las apps importantes exponen capacidades propias via MCP
- LifeOS unifica todo eso en un solo plano de control

**Ejemplos de tools MCP de OS:**
- `lifeos.window.list`
- `lifeos.window.focus`
- `lifeos.workspace.create`
- `lifeos.file.search`
- `lifeos.file.open`
- `lifeos.system.launch_app`
- `lifeos.notifications.list`
- `lifeos.clipboard.read`
- `lifeos.clipboard.write`

**Ejemplos de MCP por app:**
- `browser.open_tab`
- `browser.capture`
- `mail.compose`
- `slides.export_pdf`
- `editor.open_project`
- `calendar.brief_next_meeting`

**Ventajas:**
- determinista
- rapido
- menos tokens
- menos errores visuales
- mejor auditabilidad

#### Capa 2: adapters nativos / APIs del sistema

Muchas apps y sistemas no hablaran MCP de forma nativa. Ahi entra la segunda capa:

- wrappers MCP sobre APIs reales del sistema o de la app
- bridges a CLI, D-Bus, AppleScript, UI Automation, sockets, archivos de config, WebSocket, etc.

**Ejemplos:**
- Linux:
  - `swaymsg`
  - `wlrctl`
  - `AT-SPI2`
  - `D-Bus`
  - `xdg-desktop-portal`
- macOS:
  - Accessibility API
  - AppleScript / Shortcuts / App Intents
  - NSWorkspace / NSPasteboard / UserNotifications
- Windows:
  - UI Automation
  - Win32 / PowerShell
  - toast notifications
  - clipboard APIs
- Android:
  - AccessibilityService
  - NotificationListenerService
  - intents
  - foreground service + content providers
- iOS:
  - App Intents
  - Shortcuts
  - widget / notification actions
  - APIs del sandbox propio

La mejor practica para LifeOS es:

- si existe API real, construir **adapter MCP** encima
- no saltar directamente a vision si ya existe un camino estructurado

#### Capa 3: accesibilidad / UI automation

Esta capa sigue siendo estructurada, pero ya es mas fragil que MCP/API directa.

Se usa cuando:
- la app no tiene API util
- pero si expone accessibility tree o automation hooks

**Ejemplos:**
- macOS Accessibility
- Windows UI Automation
- Android AccessibilityService
- Linux AT-SPI2

**Ventajas:**
- mucho mejor que click ciego por coordenadas
- permite leer roles, botones, campos, menus

**Desventajas:**
- cada plataforma es diferente
- algunas apps exponen arboles pobres o inconsistentes
- requiere permisos sensibles y onboarding claro

#### Capa 4: vision + input

Esta es la capa de ultima milla:

- screenshot
- OCR
- grounding visual
- mouse / teclado / scroll / drag

Se usa cuando:
- no hay MCP
- no hay API
- no hay automation tree util
- o la app se comporta como canvas/video/juego/UI custom

**Regla importante:** esta capa no debe ser el plan A. Debe ser el seguro universal.

### 3.5 Politica de seleccion de capa

Para una accion dada, LifeOS deberia seguir esta politica:

1. **Existe tool MCP especifica?** Usarla.
2. **Existe adapter nativo confiable?** Usarlo.
3. **Existe automation/accesibilidad usable?** Usarla.
4. **No hay nada de lo anterior?** Usar vision + input.

Esto da una experiencia mucho mejor que depender siempre de capturas de pantalla.

### 3.6 Ejemplos concretos de mezcla correcta

#### Caso: abrir una app

- Linux: `lifeos.system.launch_app`
- macOS: adapter a `NSWorkspace`
- Windows: adapter a shell execute / Win32
- fallback: buscar icono visual y click

#### Caso: mover una ventana

- Linux: tool MCP sobre `swaymsg`
- Windows/macOS: adapter nativo si existe
- fallback: localizar barra de titulo y arrastrar visualmente

#### Caso: exportar un PDF desde una app de presentaciones

- ideal: `slides.export_pdf`
- segunda opcion: adapter nativo de la app
- tercera opcion: accessibility tree del menu Export
- ultima opcion: vision + clicks

#### Caso: obtener una captura del navegador

- ideal: `browser.capture`
- segunda opcion: CDP / WebDriver / extension
- ultima opcion: screenshot de pantalla

### 3.7 Que deberia construir LifeOS primero

#### Nivel 1: MCP de OS

Prioridad muy alta para Linux:

- ventanas
- workspaces
- apps
- archivos
- clipboard
- notificaciones
- estado del sistema
- browser bridge

#### Nivel 2: adapters ricos por plataforma

Para clientes cross-platform:

- Windows: clipboard, notifications, launch app, file handoff, UI automation basica
- macOS: menu bar, shortcuts, clipboard, notifications, accessibility control basico
- Android: notifications, intents, accessibility hooks, camera/location/voice
- iOS: App Intents, Shortcuts, voice, widgets, capture/companion

#### Nivel 3: vision fallback realmente robusto

Solo despues de lo anterior:

- grounding visual
- OCR
- action loop
- retries
- approval prompts
- trace y replay

### 3.8 Principio rector para LifeOS

La arquitectura correcta no es:

- “hacer todo con screenshots”

La arquitectura correcta es:

- **MCP cuando exista**
- **adapter cuando haya API**
- **automation cuando haya arbol de UI**
- **vision cuando no haya nada mas**

Eso permite que LifeOS sea:

- mas confiable que Claude Dispatch/Cowork en demos reales
- mas rapido
- mas barato
- mas auditable
- y mucho menos torpe al operar apps de escritorio

### 3.9 Traduccion a roadmap

Si se quiere convertir esta idea en plan de implementacion, el orden correcto seria:

1. formalizar `device registry + capabilities`
2. formalizar `MCP control plane` del OS LifeOS
3. construir `adapters MCP` para browser, archivos, ventanas y apps clave
4. agregar `automation layer` por plataforma
5. dejar `vision/input` como capa universal de respaldo

Este orden es importante porque evita gastar meses refinando computer use visual para problemas que deberian resolverse con herramientas estructuradas.

### 3.10 Oportunidad futura desacoplada: bridge para OpenCode

Hay una oportunidad interesante, pero **no deberia entrar en la ruta consecutiva
inmediata**:

- OpenCode ya se deja manipular por medios estructurados propios
  (`opencode serve`, OpenAPI, SDK, control parcial de TUI)
- OpenCode consume MCP como cliente, pero no aparecio evidencia oficial clara
  de que se exponga hoy como MCP server nativo para controlarse a si mismo

Por tanto, si LifeOS algun dia quiere integrarlo, la estrategia correcta seria:

1. crear un **bridge/adaptador** sobre la API oficial de OpenCode
2. exponerlo luego como MCP si aporta valor
3. dejarlo fuera del camino critico actual del control plane del OS

**Decision por ahora:** mantener esta idea como linea futura opcional, no como
proxima fase obligatoria.

---

## 4. Transporte Seguro

### 4.1 Recomendacion actual

**Fase 1:** Tailscale  
**Fase 2:** Headscale opcional  
**Fase 3:** relay propio solo si realmente hace falta

### 4.2 Por que Tailscale primero

- reduce brutalmente complejidad de NAT traversal
- acelera pruebas reales de cross-device
- evita abrir puertos publicos
- sirve igual para desktop y mobile

### 4.3 Por que Headscale despues

Headscale hoy se presenta explicitamente como:

- open-source
- self-hosted
- alternativa al control server de Tailscale
- orientado a personal use o small open-source orgs

Eso encaja muy bien con la filosofia de LifeOS, pero no deberia ser el primer bloqueo.

---

## 5. Capacidad Real por Plataforma

## 5.1 Linux

- **Estado:** full control plane
- **Capacidad real:** la mas completa
- **Rol:** servidor principal y tambien cliente rico

## 5.2 Windows

**Stack recomendado:** `Tauri 2 + Rust backend`

**Capacidades realistas:**
- chat con Axi
- clipboard sync
- notificaciones
- file handoff
- voice in/out
- telemetry basica
- cierta automatizacion via APIs del sistema

**Limitaciones importantes:**
- permisos/admin/UAC
- automation mas fragmentada que en Linux
- screen understanding/control menos uniforme

**Decision:** muy buen segundo cliente despues de Android.

## 5.3 macOS

**Stack recomendado:** `Tauri 2 + adaptadores nativos`

**Capacidades realistas:**
- menu bar app
- clipboard
- notificaciones
- App Shortcuts / Siri / Spotlight via integracion nativa si se quiere
- voice in/out
- accessibility con permiso explicito

**Validacion importante con fuentes actuales:**
- Apple sigue cobrando `\$99 USD/año` por el Apple Developer Program
- hay fee waiver para nonprofits/education/government, pero no es la ruta normal para un founder individual

**Decision:** excelente companion, pero con friccion de firma/distribucion.

**Fuentes:**
- https://developer.apple.com/programs/enroll/
- https://developer.apple.com/programs/

## 5.4 Android

**Stack recomendado:** `Kotlin nativo + Rust core compartido`

**Por que Android sigue siendo la prioridad movil:**
- Notification listeners reales
- AccessibilityService existe y permite una integracion mucho mas profunda
- foreground services y sensores dan espacio para un companion muy capaz

**Validado hoy:**
- Android sigue imponiendo restricciones fuertes a background services desde Oreo+
- en Android 12+ hay restricciones adicionales para iniciar foreground services desde background
- `AccessibilityService` y `NotificationListenerService` existen y permiten capacidades que iOS no ofrece

**Conclusión tecnica:**
- Android sigue siendo el mejor primer cliente mobile para LifeOS
- pero hay que diseñarlo desde el inicio con foreground service, permisos visibles y degradacion elegante

**Fuentes:**
- https://developer.android.com/about/versions/oreo/background
- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- https://developer.android.com/reference/android/accessibilityservice/AccessibilityService
- https://developer.android.com/reference/android/service/notification/NotificationListenerService

## 5.5 iOS

**Stack recomendado:** `Swift nativo + Rust core muy acotado`

**Lo que iOS si permite bien:**
- voz
- ubicacion
- camara
- contactos/calendario con permiso
- widgets
- App Intents / Shortcuts / Siri

**Lo que sigue siendo estructuralmente limitado:**
- background execution severamente limitada
- no es una plataforma adecuada para leer/controlar otras apps de forma general
- notificaciones y automatizacion profunda estan mucho mas encerradas que en Android

**Actualizacion importante:**
- no conviene vender la app iOS como “controlador profundo del telefono”
- conviene venderla como:
  - companion
  - remote console
  - capture/voice/location endpoint
  - Shortcuts/Siri surface

**Fuentes:**
- https://developer.apple.com/documentation/swiftui/backgroundtask
- https://developer.apple.com/documentation/AppIntents/app-intents
- https://developer.apple.com/shortcuts/

---

## 6. Matriz de Capacidades Actualizada

| Capacidad | Linux | Windows | macOS | Android | iOS |
|-----------|-------|---------|-------|---------|-----|
| Chat con Axi | FULL | FULL | FULL | FULL | FULL |
| Voz a Axi | FULL | FULL | FULL | FULL | FULL |
| Clipboard | FULL | FULL | FULL | FULL | PARCIAL |
| Notificaciones entrantes | FULL | PARCIAL | PARCIAL | FULL | MUY LIMITADO |
| Screen understanding | FULL | PARCIAL | PARCIAL | PARCIAL | NO GENERAL |
| Control de apps | FULL | PARCIAL | PARCIAL | PARCIAL | NO GENERAL |
| Camera capture | FULL | FULL | FULL | FULL | FULL |
| Ubicacion | N/A | N/A | N/A | FULL | FULL |
| Background reliability | FULL | FULL | FULL | PARCIAL | BAJO |
| System tray / menu bar | FULL | FULL | FULL | N/A | N/A |
| Shortcuts / intents del SO | N/A | PARCIAL | PARCIAL | PARCIAL | FULL |

---

## 7. Estrategia de Producto Correcta

La tentacion seria prometer “paridad completa” en todas las plataformas. Eso seria un error.

La estrategia correcta es:

### 7.1 Linux

Servidor + cliente premium.  
Aqui vive el control total.

### 7.2 Android

Primer companion movil serio.  
Debe ser el primer objetivo despues del transporte seguro.

### 7.3 Windows y macOS

Clientes companion de escritorio con:
- chat
- handoff
- clipboard
- files
- notificaciones
- voice
- algunas acciones del sistema

### 7.4 iOS

Companion premium pero restringido:
- voz
- Siri / Shortcuts
- widgets
- ubicacion
- camara
- consola remota de Axi

---

## 8. Orden de Implementacion Recomendado

1. **Tailscale integration**
2. **Device registry real + heartbeat + capabilities**
3. **Android MVP**
4. **Windows Tauri**
5. **macOS Tauri**
6. **Headscale opcional**
7. **iOS companion**

### Por que este orden

- Tailscale desbloquea pruebas reales rapido
- Android da el mayor salto de capacidad fuera de Linux
- Windows/macOS amplian superficie sin la brutal limitacion de iOS
- iOS debe entrar con framing correcto de companion, no de controlador profundo

---

## 9. Decision Tecnica Refinada

### Desktop

**Mantener `Tauri 2`**.

Ya no por ausencia de alternativas, sino porque:
- encaja con Rust
- permite clientes chicos
- sirve bien para Windows/macOS/Linux
- evita traer un stack mas pesado sin necesidad

### Mobile

**Mantener nativo**.

No porque Tauri mobile no exista, sino porque LifeOS necesita demasiado:
- foreground/background nuance
- permisos especiales
- accesibilidad
- listeners
- integraciones del sistema

Ese terreno sigue favoreciendo Kotlin/Swift.

---

## 10. Riesgos Reales

### Alto riesgo

- querer prometer simetria total entre Android e iOS
- querer meter too much logic in-client en lugar de usar LifeOS server como cerebro
- querer resolver NAT traversal por cuenta propia demasiado temprano

### Riesgo medio

- subestimar permisos sensibles y onboarding
- no modelar `capabilities` por dispositivo desde el protocolo
- depender de background continuo en iOS

### Riesgo bajo

- usar Tauri en desktop
- usar Tailscale primero y Headscale despues

---

## 11. Conclusion

La tesis cross-platform sigue siendo correcta, pero ahora mejor aterrizada:

- **Tailscale primero, Headscale despues**
- **Tauri 2 para desktop**
- **nativo para mobile**
- **Android primero**
- **iOS como companion fuerte, no como controlador profundo**

Eso mantiene ambicion alta sin mentirle a las restricciones reales de cada plataforma.

---

## 12. Fuentes Validadas

- Tauri 2.0: https://tauri.app/
- Tauri v2 mobile support context: https://v2.tauri.app/blog/tauri-2-0-0-beta/
- Tailscale pricing: https://tailscale.com/pricing/
- Headscale overview: https://headscale.net/latest/
- Apple Developer Program enrollment: https://developer.apple.com/programs/enroll/
- Apple Developer Program overview: https://developer.apple.com/programs/
- Apple BackgroundTask docs: https://developer.apple.com/documentation/swiftui/backgroundtask
- Apple App Intents docs: https://developer.apple.com/documentation/AppIntents/app-intents
- Apple Shortcuts for Developers: https://developer.apple.com/shortcuts/
- Android background limits: https://developer.android.com/about/versions/oreo/background
- Android foreground-service restrictions: https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- Android AccessibilityService: https://developer.android.com/reference/android/accessibilityservice/AccessibilityService
- Android NotificationListenerService: https://developer.android.com/reference/android/service/notification/NotificationListenerService
