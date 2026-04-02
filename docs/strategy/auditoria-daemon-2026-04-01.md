# Auditoria Profunda: Daemon (`lifeosd`)

**Fecha de corte:** `2026-04-01`  
**Entrada principal:** [daemon/src/main.rs](../../daemon/src/main.rs)

## Resumen

El daemon de LifeOS ya es una plataforma amplia, no un servicio pequeño.

En esta pasada se observaron:

- `96` modulos declarados en [main.rs](../../daemon/src/main.rs)
- `45` marcas `#[allow(dead_code)]` en el mismo entrypoint
- multiples managers persistentes
- loops periodicos para salud, updates, telemetria, meetings, seguridad, privacidad y tuning
- API local amplia y dashboard integrado

## Lo mas fuerte del daemon

### 1. Orquestacion real de managers

Hay inicializacion visible de managers como:

- `MemoryPlaneManager`
- `NotificationManager`
- `AiManager`
- `OverlayManager`
- `SensoryPipelineManager`
- `ExperienceManager`
- `FollowAlongManager`
- `ContextPoliciesManager`
- `TelemetryManager`
- `AgentRuntimeManager`
- `VisualComfortManager`
- `AccessibilityManager`
- `LabManager`
- `ScheduledTaskManager`
- `CalendarManager`

Esto confirma que el daemon ya sirve como `runtime kernel` del producto.

### 2. Background loops reales

Se observaron `tokio::spawn(...)` para tareas como:

- API server
- D-Bus broker / portal
- tray icon
- sensory memory listener
- health checks
- update checks
- metrics collection
- sensory runtime
- proactive loop
- health tracking
- calendar reminders
- autonomous agent loop
- meeting assistant loop
- eye health
- security AI
- privacy hygiene
- system tuner
- backup monitor
- housekeeping
- self-improving
- supervisor principal

Eso muestra una arquitectura de daemon vivo y no solo request/response.

### 3. API local extremadamente rica

El daemon expone:

- REST `/api/v1`
- `WebSocket` en `/ws`
- `SSE`
- `Swagger UI`
- dashboard bootstrap
- `metrics`

Y cubre muchas areas de producto: memoria, overlay, tasks, updates, battery, game guard, translate, skills, user profile, etc.

## Lo que todavia se ve delicado

### 1. Mucha superficie aun en transicion

La cantidad alta de `#[allow(dead_code)]` no invalida el trabajo, pero si marca una realidad:

- hay modulos listos o casi listos que todavia no deben contarse como totalmente consumidos
- parte de la plataforma aun vive en wiring parcial o consumo indirecto

### 2. Fallbacks a `/tmp`

En varias inicializaciones del daemon se observaron patrones tipo:

- intentar data dir real
- si falla, caer a `/tmp/lifeos` o `std::env::temp_dir()`

Eso es bueno para resiliencia de arranque, pero tambien implica que:

- algunos problemas de permisos o entorno pueden quedar parcialmente maquillados
- conviene auditar que esos fallback no oculten errores serios en producción

### 3. Crecimiento de loops y responsabilidades

El daemon centraliza muchas responsabilidades.  
Eso da potencia, pero aumenta riesgo de:

- acoplamiento
- dificultad para depurar
- regresiones silenciosas
- sobrecarga narrativa sobre lo que realmente esta estabilizado

## Lo que yo diria hoy del daemon

- **Repo:** muy fuerte
- **Imagen:** fuerte, porque la build default compila `dbus,http-api,ui-overlay,wake-word,speaker-id,telegram,tray`
- **Host:** heterogeneo; necesita seguir validandose por subsistema

## Recomendaciones

### P0

- auditar `meetings`, `operator loop`, `MCP/dashboard`, `security AI` y `Game Guard` con casos host reales

### P1

- distinguir en docs que modulos son:
  - core runtime
  - wiring parcial
  - feature-gated
  - experimentales

### P2

- considerar una tabla interna de ownership del daemon:
  - manager
  - storage
  - loop
  - surface API
  - host validation status

## Conclusión

`lifeosd` ya es uno de los activos mas fuertes del proyecto.  
El reto ya no es “hacer que exista”, sino evitar que su amplitud siga creciendo mas rapido que su cierre operativo.
