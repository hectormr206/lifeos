# Auditoria Completa de LifeOS

**Fecha de corte:** `2026-04-01`  
**Scope:** repositorio principal `lifeos/`  
**No incluye:** el repo separado `lifeos-site/`, salvo cuando se menciona como superficie publica externa

## Objetivo

Tener una vista mas completa y menos ambigua de lo que ya fue creado dentro de LifeOS:

- que existe solo como codigo o modulo
- que esta cableado a runtime real
- que se compila en la imagen por defecto
- que tiene herramientas de prueba, CI o verificacion
- donde sigue habiendo deuda de integracion o claims que deben seguir tratandose con cuidado

Esta auditoria **no reemplaza** la matriz viva en [auditoria-estados-reales.md](auditoria-estados-reales.md).  
Mas bien la complementa con un inventario amplio del repo y una lectura de madurez por capas.

---

## Metodo de auditoria

La auditoria se hizo cruzando:

- estructura del repo
- entrypoints reales de `CLI`, `daemon`, `image` y `tests`
- wiring visible en `main.rs`, `api/mod.rs`, `cli/src/main.rs` e `image/Containerfile`
- documentacion tecnica y operativa existente
- workflows de CI/CD y scripts de verificacion

Se evitaron supuestos de host no verificados en esta pasada.

---

## Resumen Ejecutivo

LifeOS ya no es un prototipo pequeno ni un repo de ideas sueltas. El repositorio principal contiene:

- una `CLI` grande en Rust
- un `daemon` muy amplio con API local, dashboard, memoria, voz, control de escritorio y bridges
- una `imagen de sistema` bootc/Fedora con servicios, branding, seguridad y runtime de IA
- `CI/CD`, pruebas, contratos y documentacion en volumen serio

La lectura honesta es esta:

- **LifeOS tiene mucho creado de verdad en repo**
- **tambien tiene una porcion importante de superficie que sigue siendo parcial, feature-gated o pendiente de validacion host**
- **la capa mas fuerte hoy es “repo integrado + imagen con bastante wiring”**
- **la capa mas debil sigue siendo “todo lo prometido ya validado end-to-end en uso real”**

---

## Metricas del repositorio

### Estructura general

- Workspace Rust con `3` miembros en [Cargo.toml](../../Cargo.toml):
  - `cli`
  - `daemon`
  - `tests`
- Directorios principales visibles:
  - [cli/](../../cli/)
  - [daemon/](../../daemon/)
  - [image/](../../image/)
  - [contracts/](../../contracts/)
  - [scripts/](../../scripts/)
  - [tests/](../../tests/)
  - [docs/](../../docs/)
  - [evidence/](../../evidence/)

### Conteos observados en esta pasada

- `102` archivos en [daemon/src/](../../daemon/src/)
- `55` archivos en [cli/src/](../../cli/src/)
- `101` archivos en [docs/](../../docs/)
- `10` archivos bajo [tests/](../../tests/)
- al menos `607` marcadores Rust de test (`#[test]` / `#[tokio::test]`) en `cli`, `daemon` y `tests`
- `11` scripts shell/python orientados a test o checks
- `96` declaraciones de modulo en [daemon/src/main.rs](../../daemon/src/main.rs)
- `45` apariciones de `#[allow(dead_code)]` en [daemon/src/main.rs](../../daemon/src/main.rs)
- `206` rutas `.route(...)` en [daemon/src/api/mod.rs](../../daemon/src/api/mod.rs)

### Lo que significan estas metricas

- La amplitud del sistema es real.
- Tambien es real que parte del repo funciona como `plataforma de capacidades` mas que como `producto completamente cerrado`.
- El numero alto de rutas y modulos muestra potencia.
- El numero alto de `dead_code` muestra que aun hay bastante superficie experimental, parcialmente integrada o mantenida por wiring indirecto.

---

## Capa 1: Sistema Operativo / Imagen / Distribucion

### Lo que existe

LifeOS ya tiene una capa de distribucion bastante robusta en:

- [image/Containerfile](../../image/Containerfile)
- [image/files/](../../image/files/)
- [scripts/build-iso.sh](../../scripts/build-iso.sh)
- [scripts/build-iso-without-model.sh](../../scripts/build-iso-without-model.sh)
- [scripts/build-iso-with-model.sh](../../scripts/build-iso-with-model.sh)
- [docs/operations/build-iso.md](../operations/build-iso.md)

### Evidencia fuerte

La imagen:

- parte de `Fedora bootc`
- construye y empaqueta `life` y `lifeosd`
- compila `llama-server`
- compila `whisper-cli`
- incluye modelos y runtime auxiliares para TTS/STT
- configura branding, wallpapers, temas, iconos, Firefox, portal, autostart y servicios systemd
- integra hardening de seguridad
- habilita timers y servicios de mantenimiento

### Features que la imagen compila por defecto para `lifeosd`

En [image/Containerfile](../../image/Containerfile), la build release del daemon usa:

`dbus,http-api,ui-overlay,wake-word,speaker-id,telegram,tray`

Eso significa que la imagen default **si shippea**:

- API HTTP local
- overlay/UI
- wake word
- speaker-id
- Telegram
- system tray

Y **no shippea por defecto** varias integraciones declaradas solo como feature flags opcionales:

- `whatsapp`
- `matrix`
- `signal`
- `slack`
- `discord`
- `homeassistant`

### Servicios y timers visibles

La imagen instala o habilita servicios/timers como:

- [llama-server.service](../../image/files/etc/systemd/system/llama-server.service)
- [whisper-stt.service](../../image/files/etc/systemd/system/whisper-stt.service)
- [lifeos-first-boot.service](../../image/files/etc/systemd/system/lifeos-first-boot.service)
- [lifeos-sentinel.service](../../image/files/etc/systemd/system/lifeos-sentinel.service)
- [lifeos-security-baseline.service](../../image/files/etc/systemd/system/lifeos-security-baseline.service)
- [lifeos-update-check.service](../../image/files/etc/systemd/system/lifeos-update-check.service)
- [lifeos-aide-check.service](../../image/files/etc/systemd/system/lifeos-aide-check.service)
- [lifeos-btrfs-snapshot.service](../../image/files/etc/systemd/system/lifeos-btrfs-snapshot.service)
- [lifeos-maintenance-cleanup.service](../../image/files/etc/systemd/system/lifeos-maintenance-cleanup.service)
- smart charge y battery services/timers

### Lectura de madurez

**Estado:** fuerte a nivel repo + imagen

LifeOS ya tiene infraestructura real de OS, no solo apps.  
La parte pendiente no es “si existe una imagen”, sino seguir validando en hardware real que la experiencia completa sea consistente.

---

## Capa 2: Daemon central (`lifeosd`)

### Lo que existe

El daemon es hoy el corazon del sistema.  
Su entrypoint es [daemon/src/main.rs](../../daemon/src/main.rs), y desde ahi se ve una plataforma muy amplia:

- accesibilidad
- agent runtime
- AI runtime y routing
- API HTTP
- workers async
- overlay y widgets
- control de escritorio
- browser/computer use
- calendar y email
- memory plane
- meeting intelligence
- sensory pipeline
- follow-along
- telemetry
- updates
- supervisor
- task queue
- Telegram tools y bridge
- reliability, safe mode, security y watchdog layers

### Lo importante

La cantidad de modulos no implica automaticamente cierre completo.  
En [daemon/src/main.rs](../../daemon/src/main.rs) hay muchas marcas `#[allow(dead_code)]`, lo que indica una mezcla de:

- wiring indirecto
- uso via otros modulos/eventos
- feature flags
- implementaciones parciales o todavia no consumidas de punta a punta

### Lectura de madurez

**Estado:** muy fuerte en amplitud; mixto en cierre final

LifeOS tiene un daemon grande y serio.  
La tension actual no es “si hay runtime”, sino:

- cuanto de ese runtime ya esta validado host
- cuanto esta totalmente conectado al flujo de usuario
- cuanto sigue siendo plataforma interna lista para evolucionar

---

## Capa 3: API local y dashboard

### Lo que existe

La API vive principalmente en [daemon/src/api/mod.rs](../../daemon/src/api/mod.rs).  
En esta pasada se observaron `206` rutas declaradas.

Tambien existe:

- `REST API` bajo `/api/v1`
- `WebSocket` en `/ws`
- `SSE` para eventos
- `Swagger UI`
- dashboard estatico en [daemon/static/dashboard/](../../daemon/static/dashboard/)

### Areas cubiertas por la API

La superficie expuesta incluye, entre otras:

- sistema, salud y recursos
- AI y LLM routing
- vision, STT, wake word, TTS
- overlay
- notificaciones
- shortcuts
- modos/contextos
- updates
- follow-along
- telemetry
- intents
- identity / workspace / orchestrator
- runtime policy
- memory / MCP context
- computer use
- visual comfort
- accessibility
- tasks y scheduled tasks
- health tracking
- proactive alerts
- email
- calendar
- file search
- clipboard
- settings y timezone
- messaging channels
- game guard
- battery
- translate
- skills
- supervisor / metrics
- knowledge graph
- reliability
- audit events
- user profile/export/forget

### Dashboard

Existe un dashboard web local en:

- [index.html](../../daemon/static/dashboard/index.html)
- [app.js](../../daemon/static/dashboard/app.js)
- [style.css](../../daemon/static/dashboard/style.css)

### Lectura de madurez

**Estado:** muy fuerte en repo

La API ya es de plataforma amplia, no minima.  
La deuda no esta en “falta API”, sino en:

- consistencia entre lo documentado y lo realmente consumido por UI/WS
- cerrar flujos end-to-end en lugar de solo exponer endpoints

---

## Capa 4: CLI `life`

### Lo que existe

La CLI tiene entrypoint en [cli/src/main.rs](../../cli/src/main.rs) y modulo de comandos en [cli/src/commands/](../../cli/src/commands/).

Hay una superficie amplia de comandos/subcomandos para:

- init / first-boot / status / update
- doctor / audit / safe-mode / rollback / recover
- config / capsule
- AI / assistant / adapters / voice / overlay
- mode / focus / meeting / followalong / context
- intents / id / workspace / onboarding
- memory / permissions / sync / skills / agents / soul / mesh
- browser / computer-use / workflow / store / telemetry / theme
- visual comfort / accessibility / portal
- beta / feedback / lab

### Hallazgos importantes

- La CLI es real y amplia.
- Parte de ella actua como wrapper de la API del daemon.
- Parte hace verificaciones locales del sistema.
- Algunas superficies aun son mas baseline que “producto final”.

Ejemplos observables:

- [doctor.rs](../../cli/src/commands/doctor.rs)
  - usa `GET /api/v1/health`
  - `--repair` aun imprime que no esta implementado
- [status.rs](../../cli/src/commands/status.rs)
  - mezcla estado local, config, bootc y checks del sistema
- [memory.rs](../../cli/src/commands/memory.rs)
  - ya ofrece operaciones reales contra endpoints del memory plane

### Lectura de madurez

**Estado:** fuerte, con mezcla de baseline + superficies maduras

La CLI ya no es decorativa.  
Pero sigue habiendo comandos cuyo valor principal es orchestration o wrapper, no necesariamente experiencia final cerrada.

---

## Capa 5: Memoria, conocimiento y contexto

### Lo que existe

Esta capa tiene evidencia fuerte en:

- [daemon/src/memory_plane.rs](../../daemon/src/memory_plane.rs)
- [daemon/src/knowledge_graph.rs](../../daemon/src/knowledge_graph.rs)
- [daemon/src/session_store.rs](../../daemon/src/session_store.rs)
- [daemon/src/user_model.rs](../../daemon/src/user_model.rs)
- [docs/architecture/memory-system.md](../architecture/memory-system.md)

### Capacidades observables

- memoria cifrada persistente
- session store
- graph / contextual recall
- export y endpoints de health del memory plane
- MCP context desde memoria
- preferencias y perfil de usuario

### Lectura de madurez

**Estado:** fuerte en repo; cierre de producto aun desigual

La base de memoria ya es parte real del sistema.  
Lo que aun necesita cuidado es:

- host validation continua
- exactitud de retencion/borrado
- integracion uniforme entre todos los canales/superficies

---

## Capa 6: Voz, sentidos, operator loop y computer use

### Lo que existe

Hay evidencia fuerte en:

- [daemon/src/sensory_pipeline.rs](../../daemon/src/sensory_pipeline.rs)
- [daemon/src/sensory_memory.rs](../../daemon/src/sensory_memory.rs)
- [daemon/src/wake_word.rs](../../daemon/src/wake_word.rs)
- [daemon/src/speaker_id.rs](../../daemon/src/speaker_id.rs)
- [daemon/src/screen_capture.rs](../../daemon/src/screen_capture.rs)
- [daemon/src/computer_use.rs](../../daemon/src/computer_use.rs)
- [daemon/src/accessibility.rs](../../daemon/src/accessibility.rs)
- [daemon/src/desktop_operator.rs](../../daemon/src/desktop_operator.rs)
- [daemon/src/browser_automation.rs](../../daemon/src/browser_automation.rs)
- [daemon/src/cdp_client.rs](../../daemon/src/cdp_client.rs)

### Indicadores de shipping

La imagen por defecto compila:

- `ui-overlay`
- `wake-word`
- `speaker-id`
- `dbus`
- `http-api`

Eso muestra que esta capa no es solo experimental de laboratorio.

### Lectura de madurez

**Estado:** repo integrado con base fuerte

Esta es una de las apuestas mas ambiciosas de LifeOS, y ya tiene wiring serio.  
La deuda sigue estando en:

- validar robustez host
- cerrar casos reales de automation/operator
- distinguir mejor entre capacidades internas y experiencia lista para beta publica

---

## Capa 7: Telegram y otros canales

### Lo que existe

Telegram tiene evidencia especialmente fuerte en:

- [daemon/src/telegram_bridge.rs](../../daemon/src/telegram_bridge.rs)
- [daemon/src/telegram_tools.rs](../../daemon/src/telegram_tools.rs)
- [docs/operations/telegram-features.md](../operations/telegram-features.md)

Ademas existen modulos para:

- Slack
- Discord
- WhatsApp
- Matrix
- Signal
- Home Assistant

### Diferencia clave

No todos esos canales estan shipped en la imagen default.

Telegram si es parte clara del camino real actual.  
Los demas canales existen como base de repo o feature flags, pero no todos forman parte del producto compilado por defecto.

### Lectura de madurez

**Estado:** Telegram fuerte; resto mixto o gated

Cuando se hable publicamente de canales, conviene seguir distinguiendo:

- canal real actual: Telegram
- canales presentes en repo pero no shipped por defecto

---

## Capa 8: Meetings, follow-along y proactividad

### Lo que existe

Hay evidencia en:

- [daemon/src/meeting_assistant.rs](../../daemon/src/meeting_assistant.rs)
- [daemon/src/meeting_archive.rs](../../daemon/src/meeting_archive.rs)
- [daemon/src/follow_along.rs](../../daemon/src/follow_along.rs)
- [daemon/src/proactive.rs](../../daemon/src/proactive.rs)
- [daemon/src/storage_housekeeping.rs](../../daemon/src/storage_housekeeping.rs)

### Lectura de estado

Segun la auditoria viva en [auditoria-estados-reales.md](auditoria-estados-reales.md):

- meetings ya tiene pipeline fuerte en repo
- follow-along y reporting tienen wiring real
- la gran deuda sigue siendo validacion host fina, retencion y experiencia end-to-end

### Lectura de madurez

**Estado:** fuerte en repo, todavia sensible a revalidacion host

---

## Capa 9: Seguridad, hardening, salud y confiabilidad

### Lo que existe

Esta es otra capa con peso real en el producto.

Codigo y archivos relevantes:

- [daemon/src/safe_mode.rs](../../daemon/src/safe_mode.rs)
- [daemon/src/reliability.rs](../../daemon/src/reliability.rs)
- [daemon/src/supervisor.rs](../../daemon/src/supervisor.rs)
- [daemon/src/game_guard.rs](../../daemon/src/game_guard.rs)
- [daemon/src/health.rs](../../daemon/src/health.rs)
- [daemon/src/health_tracking.rs](../../daemon/src/health_tracking.rs)
- [daemon/src/security_daemon.rs](../../daemon/src/security_daemon.rs)
- [daemon/src/security_ai.rs](../../daemon/src/security_ai.rs)
- [image/files/etc/systemd/system/lifeos-sentinel.service](../../image/files/etc/systemd/system/lifeos-sentinel.service)
- [docs/operations/incident-response.md](../operations/incident-response.md)
- [docs/operations/system-admin.md](../operations/system-admin.md)
- [docs/operations/nvidia-secure-boot.md](../operations/nvidia-secure-boot.md)

### Hardening visible en imagen

La imagen incorpora artefactos de seguridad para:

- `sysctl`
- `SSH hardening`
- `auditd`
- `resolved` / DNS hardening
- `faillock`
- `firewalld`
- `AIDE`
- `sudoers/polkit` para flujos controlados
- sentinel / baseline services

### Lectura de madurez

**Estado:** muy fuerte en repo + imagen

La seguridad ya no es solo aspiracional.  
Pero ciertas claims operativas siguen dependiendo de validacion host continua y de no confundir “existe la capa” con “cada flujo ya fue probado en la realidad”.

---

## Capa 10: Build, CI/CD y release engineering

### Lo que existe

Hay una base seria de automatizacion en:

- [ci.yml](../../.github/workflows/ci.yml)
- [codeql.yml](../../.github/workflows/codeql.yml)
- [docker.yml](../../.github/workflows/docker.yml)
- [e2e-tests.yml](../../.github/workflows/e2e-tests.yml)
- [release-channels.yml](../../.github/workflows/release-channels.yml)
- [release.yml](../../.github/workflows/release.yml)
- [scripts/](../../scripts/)

### Cobertura observable

CI cubre, entre otras cosas:

- build de CLI y daemon
- fmt + clippy
- tests
- CodeQL
- auditoria de dependencias
- build/push de imagen
- release channels
- release binaries
- E2E de bootc upgrade/rollback

### Scripts operativos relevantes

Hay scripts para:

- build de ISO / raw / qcow2 / vmdk
- update del host
- checks de branding
- checks de rutas huérfanas
- checks de dead code
- checks de event consumers
- wake word generation
- runner setup
- icon generation
- live tests y vm reset

### Lectura de madurez

**Estado:** fuerte

La historia de build/release/testing existe de verdad.  
La deuda no es ausencia de pipeline, sino mantenerlo alineado con la complejidad creciente del producto.

---

## Capa 11: Contratos, esquemas y evidencia

### Lo que existe

Hay contratos versionados en:

- [contracts/identity/](../../contracts/identity/)
- [contracts/intents/](../../contracts/intents/)
- [contracts/models/](../../contracts/models/)
- [contracts/onboarding/](../../contracts/onboarding/)
- [contracts/skills/](../../contracts/skills/)

Y evidencia historica en:

- [evidence/](../../evidence/)

### Lectura de madurez

**Estado:** buena señal arquitectonica

Esto ayuda a que LifeOS no dependa solo de codigo, sino tambien de:

- contratos explicitados
- closeouts/evidencia por fases

---

## Capa 12: Documentacion y conocimiento del proyecto

### Lo que existe

El repo tiene una capa documental extraordinariamente grande para su etapa:

- arquitectura
- branding
- contributor docs
- operations
- privacy analysis
- public docs
- research
- strategy
- user docs

Archivos clave:

- [docs/README.md](../../docs/README.md)
- [unified-strategy.md](unified-strategy.md)
- [auditoria-estados-reales.md](auditoria-estados-reales.md)
- [fase-ax-auditoria-de-realidad.md](fase-ax-auditoria-de-realidad.md)

### Lectura de madurez

**Estado:** muy fuerte, pero exigente de mantener

La documentacion es una ventaja real de LifeOS.  
El riesgo es que, por volumen, vuelva a desalinearse si no se sigue auditando contra codigo e imagen.

---

## Hallazgos mas importantes de esta auditoria

### 1. LifeOS ya es una plataforma amplia de verdad

No estamos frente a un solo daemon o un solo CLI pequeño:

- hay OS image
- daemon grande
- CLI grande
- API local amplia
- dashboard
- contratos
- CI/CD
- docs y evidencia

### 2. El repo tiene mas amplitud que cierre final uniforme

Esto se ve en:

- `96` modulos declarados en daemon
- `45` marcas de `dead_code`
- muchos feature flags opcionales
- bastante wiring indirecto

La conclusion no es “esta roto”, sino:

> LifeOS ya tiene mucho construido, pero una parte relevante sigue en transicion entre capacidad interna y experiencia de producto consolidada.

### 3. La imagen por defecto es clave para no sobredeclarar

La imagen default shippea bastante, pero no todo.  
Eso obliga a seguir distinguiendo:

- presente en repo
- compilado/shipped
- validado en host

### 4. Telegram, memoria, API local, updates e imagen son de las capas mas tangibles

Esas areas ya tienen suficiente evidencia para tratarlas como partes centrales del sistema actual.

### 5. Meetings, operator loop, MCP, cross-channel y algunas promesas de UX siguen necesitando cuidado

No porque no exista trabajo real, sino porque en esas zonas es mas facil caer en:

- wiring parcial
- feature-gating
- claims inflados respecto a uso real

### 6. El proyecto ya tiene bastante disciplina operacional

CI, release channels, CodeQL, security, build ISO y contratos muestran que LifeOS no es solo exploracion tecnica.

---

## Lectura de madurez por area

| Area | Lectura actual |
|------|----------------|
| Imagen / OS | Fuerte en repo + build |
| Daemon central | Muy fuerte en amplitud, madurez heterogenea |
| API local | Muy fuerte |
| CLI | Fuerte |
| Telegram | Fuerte |
| Memoria / KG / SessionStore | Fuerte en repo |
| Voz / sentidos / operator loop | Fuerte en base, pendiente cierre host uniforme |
| Meetings | Avanzado en repo, sensible a revalidacion host |
| Seguridad / hardening / watchdog | Fuerte en repo + imagen |
| Canales extra (Slack/Discord/Signal/etc.) | Mixto / feature-gated / no always shipped |
| Testing / CI / releases | Fuerte |
| Documentacion | Muy fuerte |

---

## Riesgos actuales

### Riesgo 1: confundir inventario con experiencia cerrada

Hay mucho codigo.  
Eso no significa automaticamente que todas las superficies ya esten listas para beta publica.

### Riesgo 2: confundir repo con imagen con host

Esta sigue siendo la distincion mas importante del proyecto.

### Riesgo 3: crecimiento de superficie mas rapido que la validacion

La relacion entre:

- modulos
- rutas
- canales
- workflows
- docs

ya es suficientemente grande como para exigir auditorias recurrentes.

---

## Recomendacion operativa despues de esta auditoria

### 1. Mantener tres etiquetas para todo claim importante

- `Repo integrado`
- `Shipped en imagen`
- `Host validado`

### 2. Priorizar cierres sobre nueva amplitud en ciertas capas

Especialmente en:

- meetings
- operator loop
- MCP/dashboard
- canales secundarios
- UX final de CLI/doctor/health

### 3. Tratar esta auditoria como inventario base

La matriz viva de [auditoria-estados-reales.md](auditoria-estados-reales.md) debe seguir siendo el tablero corto.  
Este documento debe servir como referencia amplia de lo que realmente ya fue creado.

---

## Conclusión

LifeOS ya tiene una base sorprendentemente grande y seria:

- sistema operativo empaquetado
- runtime local de IA
- daemon amplio
- CLI amplia
- API local muy rica
- branding, docs, CI y release engineering reales

La conclusion honesta no es “todo ya esta listo”.  
La conclusion honesta es:

> LifeOS ya tiene mucho mas que una idea. Ya es una plataforma de sistema operativo con componentes reales y densidad tecnica alta.  
> Lo que sigue no es demostrar que existe, sino seguir cerrando, validando y simplificando todo lo que ya fue creado.

---

## Actualizacion post-sesion (2026-04-01 noche)

Despues de la auditoria inicial, se realizo una sesion masiva de desarrollo que cerro
multiples items identificados. Esta seccion documenta los cambios para mantener la
auditoria alineada con la realidad.

### Metricas actualizadas

| Metrica | Antes (auditoria) | Ahora (post-sesion) |
|---|---|---|
| Tests pasando (daemon) | ~371 | **381** |
| Tests pasando (CLI) | ~193 | **193** (sin cambio) |
| Telegram tools | ~78 | **84** (+6: service_manage, meeting_list/search/start/stop, agenda) |
| Docs files | 101 | **106** (+5: telegram-features, fase-bb, fase-bc, fase-bd, branding-audit) |
| `#[allow(dead_code)]` en main.rs | 45 | **48** (+3: meeting_archive, meeting_assistant, justified by runtime dispatch) |

### Items P0 cerrados o avanzados significativamente

**Meetings (era P0 en la matriz):**
- BB.1: Speaker ID conectado a diarizacion (WeSpeaker embeddings → nombres reales)
- BB.2: Screenshots periodicos durante reuniones (grim, cada 30s)
- BB.3: Audio dual-canal (mic + sistema via PipeWire)
- BB.4: Meeting archive SQLite (MeetingArchive, 10 metodos, 5 tests)
- BB.5: Dashboard de reuniones (stats, lista, action items)
- BB.6: Auto-borrado de audio crudo post-procesamiento (privacidad)
- BB.7: Trigger manual de reuniones via Telegram
- BB.8: Framework de captions en tiempo real (whisper tiny, opt-in)
- **Estado actualizado: Repo integrado + Imagen (pendiente deploy)**

**Game Guard (era P0):**
- reset-failed antes de cada restart (ya estaba)
- Confirmado funcional en sesion anterior
- **Estado: Repo + Host validado**

### Items P1 cerrados o avanzados

**Calendario (no estaba en la auditoria original):**
- BD.1: Eventos recurrentes (daily, weekly, biweekly, monthly, weekdays, custom)
- BD.5: Vista calendario en dashboard (mini grid mensual, eventos, quick-add)
- BD.6: Historial de recordatorios (sent/failed, anti-duplicado, reintentos)
- BD.7: Recordatorios inteligentes proactivos (evento en 30min, dia vacio, dia ocupado, evento atrasado)
- BD.9: Tool #84 agenda — vista unificada calendario + cron
- Corregido: Telegram tools #67/#68 ahora usan CalendarManager real (antes usaban JSON suelto)

**Proactive alerts (mejoras):**
- CPU thermal threshold: 80°C → 90°C (muchas laptops operan a 80-85°C normalmente)
- Session duration: ahora usa idle detection real (D-Bus/xprintidle) en vez de uptime
- Disco: excluye composefs `/` (siempre 100% en bootc, falso positivo)
- Calendario: 4 alertas proactivas nuevas (evento proximo, dia vacio, dia ocupado, evento atrasado)

**Telegram (mejoras significativas):**
- Reply context: cuando el usuario responde a un mensaje, Axi recibe el texto original
- Emoji reactions: handler completo con respuestas contextuales + feedback a MemoryPlane
- Voz unificada: Telegram y local usan misma resolucion dinamica de modelo Piper
- System prompt: contexto de voz (Whisper transcribe automaticamente) + servicios (service_manage)
- LLM fix: system messages consolidados al inicio (fix para llama-server Jinja2 + imagenes)

**Storage housekeeping:**
- Agregados camera, audio, tts, sessions a directorios gestionados
- Retencion efimera: 7 dias + 120 archivos max
- Sessions: 30 dias + limpieza de directorios viejos

**Screenshots:**
- Enviados como documentos (no fotos) para preservar resolucion
- Evita compresion de Telegram

**Sudoers:**
- Agregadas entradas para nftables/firewalld (start/stop/restart/enable/disable)
- Tool #79 service_manage para control de servicios via Telegram

### Nuevas fases documentadas

- **Fase BB — Meeting Intelligence** (docs/strategy/fase-bb-meeting-intelligence.md)
- **Fase BC — App Factory** (docs/strategy/fase-bc-app-factory.md) — investigacion + marco legal
- **Fase BD — Calendario Inteligente** (docs/strategy/fase-bd-calendario-inteligente.md)

### Nueva documentacion operativa

- **docs/operations/telegram-features.md** — referencia completa de funcionalidades de Telegram

### Lectura actualizada de madurez

| Area | Auditoria original | Post-sesion |
|---|---|---|
| Meetings | Pipeline fuerte en repo, sensible a revalidacion | **Muy fuerte en repo: diarizacion con nombres, dual-channel, archive SQLite, dashboard, captions** |
| Calendario | No auditado especificamente | **Fuerte: eventos recurrentes, reminders inteligentes, historial, agenda unificada** |
| Telegram | Fuerte | **Muy fuerte: 84 tools, reactions, reply context, voz unificada, service control** |
| Proactive alerts | Funcional pero con falsos positivos | **Corregido: thermal 90°C, idle detection, composefs excluido, alertas de calendario** |
| Storage | Parcial (camera/audio sin gestion) | **Corregido: todos los directorios efimeros con limpieza automatica** |
| Seguridad | Fuerte en repo + imagen | **Mas fuerte: sudoers para servicios, service_manage tool** |
