# Fase BE — Actividad Real: Axi Sabe Lo Que Haces (De Verdad)

> Pasar de "Llevas 22 horas activo" (basado en uptime del sistema) a
> conocimiento real de actividad del usuario mediante senales concretas:
> teclado, raton, pantalla, apps, Telegram, audio, camara.

## Vision

Hoy Axi dice "Llevas 22 horas activo" porque lee el uptime del sistema
(`/proc/uptime`). Eso es mentira: la laptop puede llevar 22 horas encendida
mientras el usuario durmio 8 horas.

**Despues de esta fase**, Axi tendra un modelo de actividad real basado en
multiples senales. Podra generar mensajes como:

- "Llevas 4 horas trabajando sin pausa (2h en VSCode, 1.5h en terminal, 30min en Firefox)"
- "Tu laptop lleva 14 horas encendida pero solo has estado activo 6.5 horas"
- "No has tocado el teclado en 45 minutos, todo bien?"
- "Hoy trabajaste 6.5 horas, descansaste 2 horas, 1.5 horas en Telegram con Axi"
- "Llevas 3 horas continuas sin pausa. Toma un descanso de 10 minutos."
- "No has usado el teclado en 30 minutos pero la pantalla sigue encendida. Quieres que bloquee la pantalla?"

Esto tambien alimenta al `ErgonomicsMonitor` (ya existente en `ergonomics.rs`)
y al `HealthTracker` (`health_tracking.rs`) con datos reales en lugar de
estimaciones basadas en uptime.

---

## Estado actual (2026-04-01)

| Componente | Estado | Detalle |
|---|---|---|
| `uptime_hours` en telemetry | **Funcional** | Basado en `/proc/uptime`, no en actividad real |
| `ErgonomicsMonitor` | **Funcional** | Usa `Instant::now()` internamente, no lee input real |
| `HealthTracker` | **Funcional** | `session_start` = inicio del daemon, no actividad real |
| `proactive.rs` | **Funcional** | Tiene logica de idle_time pero sin fuente real de datos |
| D-Bus IdleMonitor | **No implementado** | -- |
| Deteccion de screen lock | **No implementado** | -- |
| Tracking de app activa | **No implementado** | -- |
| Actividad en Telegram | **Parcial** | Timestamps existen en SessionStore pero no se usan para actividad |
| Audio/PipeWire tracking | **No implementado** | -- |
| Camara tracking | **No implementado** | -- |
| SQLite activity_log | **No implementado** | -- |
| Resumen diario | **No implementado** | -- |

---

## Senales a Rastrear

### 1. Actividad de teclado y raton

**Que datos recoger:**
- Timestamp de ultimo evento de input (teclado o raton)
- Contador de eventos por ventana de tiempo (no el contenido de las teclas)
- Clasificacion: escritura continua, clics esporadicos, scroll, sin actividad

**Como recogerlos (Linux/Wayland):**
- **Opcion A (preferida): D-Bus IdleMonitor** — `org.gnome.Mutter.IdleMonitor` (GNOME)
  o `org.freedesktop.portal.Inhibit` / idle-notify protocol de Wayland.
  En COSMIC: usar `ext-idle-notify-v1` protocol via wayland-client.
  Solo reporta "idle desde hace X segundos", no eventos individuales.
  ```
  // zbus call a org.gnome.Mutter.IdleMonitor
  // /org/gnome/Mutter/IdleMonitor/Core
  // GetIdletime() -> u64 (milisegundos desde ultimo input)
  ```
- **Opcion B: logind idle hint** — `org.freedesktop.login1.Session.IdleHint`
  y `IdleSinceHint`. Menos granular pero universal en systemd.
- **Opcion C: /dev/input (solo lectura de timestamps)** — Leer eventos de
  `/dev/input/eventN` solo para detectar "hubo actividad" sin capturar contenido.
  Requiere grupo `input` o udev rule. Evitar en favor de D-Bus.

**Privacidad:** NUNCA registrar que teclas se presionan. Solo timestamps y
contadores. La granularidad es "hubo actividad" vs "no hubo actividad".

**Almacenamiento:** En memoria (ultimo timestamp + contador rolling) + SQLite
cada 1 minuto si hubo cambio de estado.

**Granularidad:** Polling cada 30 segundos via D-Bus. Escritura a SQLite cada
1 minuto si hubo transicion de estado.

---

### 2. Bloqueo y desbloqueo de pantalla

**Que datos recoger:**
- Timestamp de Lock y Unlock
- Duracion de cada periodo bloqueado

**Como recogerlos:**
- **logind D-Bus signals:** Suscribirse a `org.freedesktop.login1.Session.Lock`
  y `org.freedesktop.login1.Session.Unlock`. Funciona en todos los DEs con
  systemd (GNOME, COSMIC, KDE, Sway).
  ```
  // zbus: monitor signal Lock/Unlock en
  // /org/freedesktop/login1/session/auto
  // interface org.freedesktop.login1.Session
  ```
- **Alternativa COSMIC/GNOME:** `org.freedesktop.ScreenSaver.ActiveChanged(bool)`
  signal. `true` = bloqueada, `false` = desbloqueada.

**Privacidad:** Solo timestamps de lock/unlock. Sin datos sensibles.

**Almacenamiento:** SQLite — un registro por cada transicion lock/unlock.

**Granularidad:** Event-driven (D-Bus signal), no requiere polling.

---

### 3. Ventana/aplicacion activa

**Que datos recoger:**
- Nombre de la aplicacion en foco (app_id)
- Titulo de la ventana (opcional, puede contener info sensible)
- Timestamp de cambio de foco

**Como recogerlos:**
- **COSMIC:** Protocolo `zcosmic-toplevel-info-v1` via wayland-client.
  Reporta lista de toplevels con `app_id`, `title`, estado `activated`.
  Suscribirse a eventos de cambio de foco.
- **GNOME:** `org.gnome.Shell.Extensions` o extension personalizada.
  Tambien: `org.gnome.Shell.Introspect.GetWindows()` (disponible sin extension).
- **Sway/wlroots:** `swaymsg -t get_tree` o protocolo `zwlr-foreign-toplevel-management-v1`.
- **Fallback generico:** `xdg-desktop-portal` no tiene protocol de focus tracking
  todavia, asi que necesitamos compositor-specific.

**Privacidad:**
- Guardar solo `app_id` por defecto (ej: "org.mozilla.firefox", "code", "alacritty").
- Titulo de ventana es **opt-in** y se puede desactivar (`LIFEOS_TRACK_WINDOW_TITLES=0`).
- Si se guarda titulo, sanitizar URLs y datos sensibles (quitar query params, tokens).
- Categorias predefinidas: "desarrollo", "navegacion", "comunicacion", "entretenimiento", "sistema".

**Almacenamiento:** SQLite — registro por cada cambio de app activa.

**Granularidad:** Event-driven cuando hay cambio de foco. Si no hay protocolo
de eventos, polling cada 10 segundos.

---

### 4. Interaccion con Telegram (y otros bridges)

**Que datos recoger:**
- Timestamp de cada mensaje enviado por el usuario a Axi
- Timestamp de cada respuesta de Axi al usuario
- Periodos de inactividad en conversacion (usuario no responde en N minutos)
- Duracion de sesiones de chat (desde primer mensaje hasta ultimo + timeout)

**Como recogerlos:**
- Ya existe `SessionStore` en `telegram_bridge.rs` que registra mensajes.
- Agregar campo `last_user_message_at` y `last_axi_response_at` al state.
- Calcular `telegram_active_minutes` por dia sumando ventanas donde hubo
  intercambio de mensajes con gaps < 5 minutos.

**Privacidad:** NO guardar contenido de mensajes para esta feature.
Solo timestamps y contadores.

**Almacenamiento:** En memoria (ya existe en SessionStore) + resumen
diario a SQLite.

**Granularidad:** Event-driven (cada mensaje).

---

### 5. Estado de reunion

**Que datos recoger:**
- Inicio y fin de reuniones detectadas
- Tipo: videollamada, llamada de audio, reunion presencial (microfono + camara activos)

**Como recogerlos:**
- Ya existe `meeting_assistant.rs` que detecta reuniones.
- Integrar su output al activity tracker: cuando `MeetingAssistant` detecta
  reunion activa, el estado cambia a "en_reunion".
- Senales auxiliares: camara activa (`/dev/video*` abierto por otro proceso) +
  audio de microfono activo (PipeWire node state).

**Privacidad:** Solo duracion y tipo. Sin grabacion ni transcripcion
(eso es responsabilidad del meeting_assistant, no de esta fase).

**Almacenamiento:** SQLite via el activity_log.

**Granularidad:** Event-driven (inicio/fin de reunion).

---

### 6. Audio de salida (PipeWire)

**Que datos recoger:**
- Si hay audio reproduciendose (musica, video, notificaciones)
- Nombre del stream/aplicacion que produce audio
- Volumen general (muted/unmuted)

**Como recogerlos:**
- **PipeWire D-Bus/protocol:** Usar `libpipewire` via bindings de Rust
  (`pipewire-rs`) o conectarse al PipeWire socket directamente.
- **Alternativa simple:** Leer `/proc/asound/` o usar `pactl list sink-inputs`
  (PulseAudio compat layer de PipeWire). Parsear output.
- **Alternativa minima:** Verificar si `pw-cli ls Node` muestra nodos de
  playback activos. Polling cada 30 segundos.

**Uso en el modelo de actividad:**
- Audio reproduciendose + sin teclado = "probablemente presente, escuchando musica/video"
- Sin audio + sin teclado + pantalla desbloqueada = "probablemente ausente"

**Privacidad:** Solo nombre de app que reproduce audio y estado play/pause.
Sin grabar audio.

**Almacenamiento:** En memoria (estado actual). Solo escribir a SQLite en
transiciones de estado.

**Granularidad:** Polling cada 30 segundos.

---

### 7. Uso de camara

**Que datos recoger:**
- Si `/dev/video0` (o similar) esta siendo usado por algun proceso
- Que proceso lo esta usando

**Como recogerlos:**
- Verificar si `/dev/video*` esta abierto: `lsof /dev/video0` o
  leer `/sys/class/video4linux/video*/device/` + verificar file locks.
- **Alternativa mas limpia:** Usar PipeWire camera portal y verificar
  si hay un cliente usando el nodo de camara.
- **Indicador LED:** En muchas laptops, el LED de camara se enciende
  cuando `/dev/video` esta abierto. No necesitamos leer el LED, solo
  verificar el file descriptor.

**Uso en el modelo de actividad:**
- Camara activa + microfono activo = alta probabilidad de videollamada/reunion
- Camara activa sola = posiblemente tomando foto/video o face tracking

**Privacidad:** Solo booleano (camara en uso / no en uso) + nombre del
proceso. Sin capturar video.

**Almacenamiento:** En memoria. Escribir a SQLite solo en transiciones.

**Granularidad:** Polling cada 60 segundos.

---

## Maquina de Estados de Actividad

El tracker mantiene un estado actual que se actualiza con cada senal.
Las transiciones se evaluan cada 30 segundos.

```
                    +-----------+
                    |  ACTIVO   |  <-- teclado/raton en ultimos 5 min
                    +-----+-----+
                          |
              sin input 5 min, app en foco
                          |
                    +-----v-----+
                    |  LEYENDO  |  <-- sin input 5-15 min, pantalla desbloqueada
                    +-----+-----+
                          |
              sin input 15 min
                          |
                    +-----v-----+
                    | INACTIVO  |  <-- sin input 15+ min, pantalla desbloqueada
                    +-----+-----+
                          |
              screen lock signal
                          |
                    +-----v-----+
                    |  AUSENTE  |  <-- pantalla bloqueada
                    +-----+-----+
                          |
              bloqueado 15+ min o usuario dijo "voy a descansar"
                          |
                    +-----v------+
                    | EN_DESCANSO |
                    +-------------+

        (cualquier estado) ---meeting detected---> EN_REUNION
        (EN_REUNION) ------meeting ended---------> (estado anterior)
```

### Definicion de estados

| Estado | Condicion | Duracion tipica |
|--------|-----------|-----------------|
| **Activo** (`active`) | Teclado o raton usado en los ultimos 5 minutos | Mientras haya input |
| **Leyendo** (`reading`) | Sin input 5-15 min, pantalla desbloqueada, app en foco | 5-15 min |
| **Inactivo** (`idle`) | Sin input 15+ min, pantalla desbloqueada | 15 min+ |
| **Ausente** (`away`) | Pantalla bloqueada | Variable |
| **En reunion** (`meeting`) | Meeting assistant detecta reunion activa | Duracion de la reunion |
| **En descanso** (`break`) | Pantalla bloqueada 15+ min, o usuario dijo "voy a descansar" via Telegram | Variable |

### Transiciones especiales

- **Ausente -> En descanso:** automatico despues de 15 minutos con pantalla bloqueada.
- **Cualquier estado -> En reunion:** meeting_assistant detecta reunion. Al terminar,
  se regresa al estado que corresponda segun senales actuales.
- **Desbloqueo de pantalla:** siempre regresa a Activo (asumimos que el usuario
  desbloqueo para usar la computadora).
- **Mensaje de Telegram:** si el usuario envia mensaje estando en estado Inactivo,
  transicionar a Activo (esta usando el telefono para hablar con Axi, cuenta como actividad).

### Heuristica de contexto (audio + camara)

Estas senales no definen estados por si solas, pero modifican la confianza:

| Senal adicional | Efecto |
|-----------------|--------|
| Audio reproduciendose + sin teclado | Incrementa probabilidad de "presente pero no trabajando" |
| Camara activa + mic activo | Fuerza estado "en reunion" aunque meeting_assistant no lo detecte |
| Audio + teclado activo | Estado "activo" con contexto "escuchando musica mientras trabaja" |

---

## Schema de almacenamiento (SQLite)

### Tabla principal: `activity_log`

```sql
CREATE TABLE activity_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp   TEXT NOT NULL,        -- ISO 8601, zona horaria local
    state       TEXT NOT NULL,        -- 'active', 'reading', 'idle', 'away', 'meeting', 'break'
    active_app  TEXT,                 -- app_id de la ventana en foco (ej: "code", "firefox")
    details     TEXT,                 -- JSON: {"audio": true, "camera": false, "typing_rate": "high"}
    duration_secs INTEGER DEFAULT 0  -- duracion en este estado (se actualiza al cambiar de estado)
);

CREATE INDEX idx_activity_timestamp ON activity_log(timestamp);
CREATE INDEX idx_activity_state ON activity_log(state);
```

### Tabla de sesiones de app: `app_usage`

```sql
CREATE TABLE app_usage (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    date        TEXT NOT NULL,        -- YYYY-MM-DD
    app_id      TEXT NOT NULL,        -- ej: "code", "firefox", "alacritty"
    category    TEXT,                 -- 'development', 'browsing', 'communication', 'entertainment', 'system'
    total_secs  INTEGER DEFAULT 0,   -- segundos totales en foco ese dia
    UNIQUE(date, app_id)
);

CREATE INDEX idx_app_usage_date ON app_usage(date);
```

### Tabla de resumen diario: `daily_summary`

```sql
CREATE TABLE daily_summary (
    date              TEXT PRIMARY KEY,  -- YYYY-MM-DD
    uptime_secs       INTEGER DEFAULT 0, -- tiempo total encendida
    active_secs       INTEGER DEFAULT 0, -- tiempo con teclado/raton
    reading_secs      INTEGER DEFAULT 0, -- tiempo leyendo
    idle_secs         INTEGER DEFAULT 0, -- tiempo inactivo
    away_secs         INTEGER DEFAULT 0, -- tiempo con pantalla bloqueada
    meeting_secs      INTEGER DEFAULT 0, -- tiempo en reuniones
    break_secs        INTEGER DEFAULT 0, -- tiempo en descanso
    telegram_secs     INTEGER DEFAULT 0, -- tiempo interactuando con Axi
    meeting_count     INTEGER DEFAULT 0, -- numero de reuniones
    top_apps          TEXT,              -- JSON: [{"app": "code", "secs": 10800}, ...]
    generated_at      TEXT               -- timestamp de generacion
);
```

### Ubicacion de la base de datos

```
/var/lib/lifeos/activity.db
```

Misma convencion que `calendar.db` y otros stores de lifeosd.

---

## Resumen diario

Al final del dia (configurable, default 22:00) o cuando el usuario lo pida
("Axi, como fue mi dia?"), Axi genera un resumen:

```
Resumen de actividad — 2 de abril 2026:

- Tiempo total encendida: 14 horas
- Tiempo activo (teclado/raton): 6.5 horas
- Tiempo leyendo/pensando: 1 hora
- Tiempo en descanso/bloqueada: 4 horas
- Tiempo inactivo (encendida pero sin uso): 2.5 horas
- Apps mas usadas: VSCode (3h), Firefox (2h), Terminal (1.5h)
- Reuniones: 1 reunion (45 min)
- Telegram con Axi: 45 min de interaccion
- Productividad estimada: 72% del tiempo activo en apps de desarrollo
```

El resumen se genera desde `daily_summary` + `app_usage` del dia.

### Comando via Telegram

- "Axi, como fue mi dia?" -> resumen del dia actual
- "Axi, resumen de la semana" -> resumen agregado lunes-domingo
- "Axi, cuanto tiempo llevo trabajando?" -> tiempo activo desde ultimo descanso largo

---

## Alertas mejoradas

### Reemplazo del mensaje actual

**Antes:** "Llevas 22 horas activo" (uptime del sistema)

**Despues:** El health report usa `activity_log` en lugar de `/proc/uptime`:

```rust
// En lugar de:
let uptime_hours = read_proc_uptime();

// Usar:
let active_hours = activity_tracker.active_hours_today();
let uptime_hours = read_proc_uptime();
// "Tu laptop lleva {uptime_hours}h encendida. Has estado activo {active_hours}h."
```

### Alertas proactivas

| Condicion | Mensaje |
|-----------|---------|
| 2+ horas continuas activo sin break | "Llevas {n} horas continuas de actividad. Toma un descanso de 10 minutos." |
| 4+ horas continuas | "Llevas {n} horas sin pausa. Esto afecta tu concentracion. Por favor, descansa." |
| 30+ min inactivo, pantalla encendida | "No has usado el teclado en {n} minutos pero la pantalla sigue encendida. Quieres que la bloquee?" |
| Laptop encendida 12+ horas, activo < 4 horas | "Tu laptop lleva {up}h encendida pero solo has estado activo {act}h. Todo normal?" |
| Fin de dia laboral (18:00+) | "Son las {hora}. Hoy trabajaste {n} horas. Buen trabajo." |
| Usuario dice "voy a descansar" | "Perfecto, registro tu descanso. Te aviso cuando lleves 15 minutos." |

### Integracion con ErgonomicsMonitor

El `ErgonomicsMonitor` existente usa timestamps internos. Despues de esta fase:

- `ErgonomicsMonitor.tick()` recibe el estado real del activity tracker.
- Los recordatorios de microbreak/short break usan actividad real de input.
- El `HealthTracker` usa `active_secs` reales en lugar de `total_active_minutes`
  basado en tiempo de sesion del daemon.

---

## Tareas

### BE.1 — ActivityTracker core + IdleMonitor D-Bus (Prioridad: ALTA)

Crear `daemon/src/activity_tracker.rs` con:

- Struct `ActivityTracker` con estado actual (`ActivityState` enum)
- Polling de idle time via D-Bus (`org.gnome.Mutter.IdleMonitor.GetIdletime`
  con fallback a `ext-idle-notify-v1` de Wayland para COSMIC)
- Logica de transicion de estados (activo/leyendo/inactivo) basada en idle time
- Loop de actualizacion cada 30 segundos
- **Wire:** Registrar en `supervisor.rs` como tarea de background
- **Dependencias:** `zbus` (ya usado en el proyecto para D-Bus)
- **Test:** Unit tests para transiciones de estado con idle time simulado

### BE.2 — Screen lock/unlock via logind (Prioridad: ALTA)

Agregar a `ActivityTracker`:

- Suscripcion a signals `Lock`/`Unlock` de `org.freedesktop.login1.Session`
- Al recibir Lock: transicionar a estado `Away`
- Al recibir Unlock: transicionar a estado `Active`
- Timer interno: si lleva 15+ min en `Away`, transicionar a `Break`
- **Wire:** Ejecutar listener de D-Bus signals en el mismo tokio task que BE.1
- **Test:** Mock de D-Bus signals para verificar transiciones

### BE.3 — SQLite activity_log (Prioridad: ALTA)

Crear tablas en `/var/lib/lifeos/activity.db`:

- `activity_log`, `app_usage`, `daily_summary` (schema descrito arriba)
- Funcion `log_state_change()` que inserta registro y actualiza `duration_secs`
  del registro anterior
- Funcion `update_app_usage()` que acumula segundos por app por dia
- Retencion automatica: `DELETE FROM activity_log WHERE timestamp < date('now', '-N days')`
  ejecutado una vez al dia (N configurable, default 30)
- **Wire:** Llamado desde `ActivityTracker` en cada transicion de estado
- **Dependencia:** `rusqlite` (ya usado para calendar.db)

### BE.4 — Tracking de app activa via compositor (Prioridad: MEDIA)

Agregar a `ActivityTracker`:

- **COSMIC:** Conectarse a `zcosmic-toplevel-info-v1` protocol para recibir
  eventos de cambio de foco. Extraer `app_id`.
- **GNOME fallback:** `org.gnome.Shell.Introspect.GetWindows()` via D-Bus.
- **Sway fallback:** `swaymsg -t get_tree | jq` para obtener focused window.
- Mapa de `app_id` a categoria (hardcoded inicial, despues configurable):
  ```rust
  fn categorize_app(app_id: &str) -> &str {
      match app_id {
          "code" | "code-oss" | "codium" => "development",
          "Alacritty" | "kitty" | "foot" | "gnome-terminal" => "development",
          "firefox" | "chromium" | "brave" => "browsing",
          "org.telegram.desktop" | "signal" => "communication",
          "steam" | "lutris" => "entertainment",
          _ => "other",
      }
  }
  ```
- Actualizar `app_usage` tabla cada vez que cambia la app en foco.
- **Wire:** Integrar en el loop de `ActivityTracker`

### BE.5 — Integracion de Telegram activity (Prioridad: MEDIA)

Modificar `telegram_bridge.rs`:

- Agregar timestamps `last_user_message_at` y `last_axi_response_at` a SessionStore
- Cuando el usuario envia mensaje: notificar al `ActivityTracker` (via channel)
  para que lo considere como actividad
- Calcular `telegram_active_secs` diario: sumar ventanas de mensajes con
  gaps < 5 minutos entre mensajes consecutivos
- Escribir `telegram_secs` al `daily_summary`
- **Wire:** Channel `mpsc` de telegram_bridge a activity_tracker

### BE.6 — Resumen diario automatico (Prioridad: MEDIA)

Crear funcion `generate_daily_summary()`:

- Ejecutar a las 22:00 (configurable) o cuando el usuario pregunte
- Agregar datos de `activity_log` del dia en `daily_summary`
- Consultar `app_usage` para top apps
- Formatear mensaje en espanol con el formato descrito arriba
- Enviar por Telegram si el usuario tiene notificaciones activas
- **Wire:** Registrar como cron job en el scheduler existente
- **Telegram tool:** Agregar herramienta `get_activity_summary` al set de
  tools de Axi para que pueda responder "como fue mi dia?"

### BE.7 — Reemplazo de uptime en health reports (Prioridad: ALTA)

Modificar los health reports existentes:

- En `telemetry.rs`: agregar `active_hours` junto a `uptime_hours` en `TelemetryStats`
- En `telegram_bridge.rs` (y otros bridges): usar `active_hours` del
  `ActivityTracker` en lugar de solo `uptime_hours`
- Formato nuevo del health report:
  ```
  Laptop encendida: 14h | Activo: 6.5h | Descanso: 4h | Inactivo: 3.5h
  ```
- **Wire:** Inyectar `ActivityTracker` (via Arc) a los bridges y al telemetry

### BE.8 — Audio tracking via PipeWire (Prioridad: BAJA)

Agregar deteccion de audio:

- Verificar si hay nodos de playback activos en PipeWire
- Opcion simple: ejecutar `pw-cli ls Node` y parsear output cada 30 seg
- Opcion robusta: usar `pipewire-rs` crate para suscribirse a cambios de estado
- Guardar en `details` JSON del `activity_log`: `{"audio": true, "audio_app": "firefox"}`
- Usar como heuristica: audio + sin teclado = "probablemente presente"
- **Wire:** Integrar como senal adicional en `ActivityTracker.evaluate_state()`

### BE.9 — Camara tracking (Prioridad: BAJA)

Agregar deteccion de uso de camara:

- Verificar si `/dev/video*` tiene file descriptors abiertos por procesos
  que no sean lifeosd (leer `/proc/*/fd` -> symlink a `/dev/video*`)
- Polling cada 60 segundos
- Si camara + microfono activos y meeting_assistant no detecto reunion:
  forzar estado `Meeting`
- **Wire:** Integrar como senal en `ActivityTracker`

### BE.10 — Alertas proactivas inteligentes (Prioridad: MEDIA)

Integrar con `proactive.rs`:

- Reemplazar alertas basadas en uptime con alertas basadas en actividad real
- Implementar las alertas de la tabla de "Alertas proactivas" (arriba)
- Cooldown entre alertas del mismo tipo: minimo 30 minutos
- Respetar modo "no molestar" si el usuario lo configuro
- **Wire:** `proactive.rs` consulta `ActivityTracker` en cada ciclo

### BE.11 — Bloqueo automatico de pantalla (Prioridad: BAJA)

Ofrecer bloqueo automatico:

- Si el usuario acepta ("si, bloquea la pantalla"), ejecutar
  `loginctl lock-session` via D-Bus
- Solo sugerir despues de 30+ min de inactividad con pantalla encendida
- Configurable: `LIFEOS_AUTO_LOCK_SUGGEST=1` (default activado)
- **Wire:** Agregar como tool de Telegram: `lock_screen`

---

## Privacidad

### Principios

1. **Todo local.** Los datos de actividad NUNCA salen de la maquina. No hay
   telemetria remota de actividad.
2. **Sin keylogging.** Solo se registra "hubo actividad de teclado", nunca
   que teclas se presionaron.
3. **Titulos de ventana opt-in.** Por defecto solo se guarda `app_id`.
   Para guardar titulos: `LIFEOS_TRACK_WINDOW_TITLES=1`.
4. **URLs nunca completas.** Si se guarda titulo de Firefox, sanitizar URLs
   quitando path, query params y fragmentos. Solo dominio.

### Controles del usuario

| Control | Como |
|---------|------|
| Desactivar tracking completo | `LIFEOS_ACTIVITY_TRACKING=0` en environment |
| Borrar historial | "Axi, borra mi historial de actividad" via Telegram |
| Borrar un dia especifico | "Axi, borra la actividad del 15 de marzo" |
| Configurar retencion | `LIFEOS_ACTIVITY_RETENTION_DAYS=30` (default) |
| Pausar tracking temporalmente | "Axi, pausa el tracking de actividad" (reanuda al reiniciar o al pedir) |
| Desactivar tracking de apps | `LIFEOS_TRACK_APPS=0` |
| Desactivar alertas de actividad | `LIFEOS_ACTIVITY_ALERTS=0` |

### Limpieza automatica

- Cron diario: eliminar registros de `activity_log` mas viejos que N dias
- `app_usage` y `daily_summary` se conservan mas tiempo (90 dias default)
  porque son datos agregados sin informacion sensible
- Al desinstalar lifeosd: `activity.db` se borra con el resto de datos en
  `/var/lib/lifeos/`

---

## Configuracion

Variables de entorno (todas opcionales, los defaults son sensatos):

```bash
# Activar/desactivar
LIFEOS_ACTIVITY_TRACKING=1          # default: 1 (activado)
LIFEOS_TRACK_APPS=1                 # default: 1 (rastrear app activa)
LIFEOS_TRACK_WINDOW_TITLES=0        # default: 0 (no guardar titulos)
LIFEOS_ACTIVITY_ALERTS=1            # default: 1 (alertas proactivas)
LIFEOS_AUTO_LOCK_SUGGEST=1          # default: 1 (sugerir bloqueo)

# Umbrales de estado (segundos)
LIFEOS_IDLE_READING_THRESHOLD=300   # default: 300 (5 min -> leyendo)
LIFEOS_IDLE_INACTIVE_THRESHOLD=900  # default: 900 (15 min -> inactivo)
LIFEOS_AWAY_BREAK_THRESHOLD=900     # default: 900 (15 min bloqueado -> descanso)

# Retencion
LIFEOS_ACTIVITY_RETENTION_DAYS=30   # default: 30 (activity_log)
LIFEOS_SUMMARY_RETENTION_DAYS=90    # default: 90 (daily_summary + app_usage)

# Resumen diario
LIFEOS_DAILY_SUMMARY_HOUR=22       # default: 22 (generar resumen a las 10pm)
```

---

## Dependencias

| Crate | Version | Uso | Ya en el proyecto? |
|-------|---------|-----|--------------------|
| `zbus` | 4.x | D-Bus (idle monitor, logind, screensaver) | Si |
| `rusqlite` | 0.31+ | SQLite para activity.db | Si |
| `chrono` | 0.4 | Timestamps y formateo de fechas | Si |
| `tokio` | 1.x | Async runtime, channels, timers | Si |
| `serde_json` | 1.x | Serializar details column | Si |
| `pipewire-rs` | 0.8+ | Audio tracking (BE.8) | No, agregar |
| `wayland-client` | 0.31+ | Toplevel tracking en COSMIC (BE.4) | Evaluar si necesario vs swaymsg |

**Nota:** BE.1 a BE.3 y BE.7 no requieren dependencias nuevas. Solo a partir
de BE.4 se evaluan crates adicionales.

---

## Orden de implementacion sugerido

```
Semana 1:  BE.1 (core + idle)  +  BE.2 (screen lock)  +  BE.3 (SQLite)
Semana 2:  BE.7 (reemplazo de uptime en reports)  +  BE.5 (Telegram activity)
Semana 3:  BE.4 (app tracking)  +  BE.6 (resumen diario)
Semana 4:  BE.10 (alertas)  +  BE.8 (audio)  +  BE.9 (camara)  +  BE.11 (auto-lock)
```

Las primeras 2 semanas entregan el valor principal: Axi sabe si el usuario
esta activo de verdad y los health reports son honestos.

Las semanas 3-4 agregan contexto (que apps, que patron de uso) y alertas
mas inteligentes.

---

## Riesgos y mitigaciones

| Riesgo | Mitigacion |
|--------|------------|
| D-Bus IdleMonitor no disponible en COSMIC | Implementar fallback a `ext-idle-notify-v1` Wayland protocol |
| Compositor no soporta toplevel tracking | Fallback a `swaymsg` o polling de `/proc` para detectar procesos con ventanas |
| Alto consumo de CPU por polling frecuente | Polling minimo (30s idle, 60s camera). Usar D-Bus signals siempre que sea posible |
| SQLite writes bloquean | Usar WAL mode, writes en task dedicado con channel |
| Usuario se siente vigilado | Comunicar claramente que es local, opt-out facil, no keylogger. Transparencia total |
| Datos de actividad se acumulan | Retencion automatica con limpieza diaria |

---

## BE.12 — Botones interactivos en alertas de Telegram

### Contexto

Hoy todas las alertas de Axi se envian como texto plano. El usuario tiene que
escribir una respuesta para actuar. Telegram soporta **inline keyboard buttons**
que permiten responder con un toque.

Ya tenemos el `callback_handler` en telegram_bridge.rs (usado por SDD — Safe Decision Dialogue),
pero NO se usa en alertas proactivas, recordatorios ni notificaciones.

### Botones por tipo de alerta

| Alerta | Botones |
|---|---|
| "Llevas 4h trabajando sin pausa" | **[Ya voy a descansar]** · [Recordar en 30min] · [Ignorar] |
| "Llevas 3h continuas sin pausa" | **[Tomo 10 min]** · [Estoy bien] |
| "CPU a 92°C" | **[Ver detalles]** · [Ignorar] |
| "Firewall inactivo. Sistema expuesto" | **[Activar firewall]** · [Ignorar] |
| "Reunion finalizada" | **[Ver resumen]** · [Ver action items] |
| "Tienes cita en 30 min" | **[Listo]** · [Posponer 15min] · [Cancelar cita] |
| "No has usado el teclado en 30 min" | **[Estoy bien]** · [Bloquear pantalla] |
| "Manana no tienes nada agendado" | **[Agregar evento]** · [OK] |
| "Dia ocupado — 5 eventos hoy" | **[Ver agenda]** · [OK] |
| "Disco al 92%" | **[Limpiar cache]** · [Ver detalles] · [Ignorar] |
| "Actualizacion disponible" | **[Actualizar]** · [Despues] · [Ignorar] |

### Comportamiento de cada boton

- **[Ya voy a descansar]** → Axi registra pausa, no vuelve a alertar por 30 min
- **[Recordar en 30min]** → Programa cron one-shot para re-alertar
- **[Ignorar]** → Oculta la alerta, no registra nada
- **[Activar firewall]** → Ejecuta service_manage tool #79
- **[Ver resumen]** → Envia resumen completo de reunion como mensaje
- **[Posponer 15min]** → Modifica reminder_minutes del evento
- **[Cancelar cita]** → Elimina evento del calendario
- **[Bloquear pantalla]** → Ejecuta `loginctl lock-session`
- **[Limpiar cache]** → Ejecuta housekeeping manual
- **[Agregar evento]** → Responde "Dime que evento agregar"
- **[Ver agenda]** → Ejecuta tool #84 agenda
- **[Actualizar]** → Ejecuta bootc upgrade

### Implementacion tecnica

1. Usar `InlineKeyboardMarkup` de teloxide para enviar botones con cada alerta
2. Cada boton tiene un `callback_data` con formato: `action:param` (ej: `snooze:30`, `service:nftables:start`)
3. El `handle_callback()` existente parsea el callback_data y ejecuta la accion
4. Registrar la interaccion en SessionStore para contexto
5. Despues de ejecutar la accion, editar el mensaje original para mostrar el resultado

### Tareas

- [ ] BE.12.1 — Crear funcion `send_alert_with_buttons(bot, chat_id, text, buttons)` reutilizable
- [ ] BE.12.2 — Definir mapa de callback_data → accion para cada tipo de alerta
- [ ] BE.12.3 — Integrar botones en alertas proactivas (proactive.rs → telegram_bridge.rs)
- [ ] BE.12.4 — Integrar botones en recordatorios de calendario
- [ ] BE.12.5 — Integrar botones en notificaciones de reuniones
- [ ] BE.12.6 — Integrar botones en alertas de salud/ergonomia
- [ ] BE.12.7 — Snooze: programar re-alerta temporal
- [ ] BE.12.8 — Editar mensaje original despues de accion (confirmacion visual)

### Prioridad

**Alta** — los botones mejoran drasticamente la experiencia de Telegram.
Hoy el usuario tiene que escribir para actuar. Con botones, un toque es suficiente.
Esto convierte las notificaciones de "informativas" a "accionables".
