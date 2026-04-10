# PRD Master: LifeOS Pending Items Roadmap

**Version:** 1.0
**Fecha:** 2026-04-10
**Autor:** Hector Martinez + AI collaboration
**Estado:** Aprobado — en ejecucion

---

## Proposito

Este documento es la **fuente unica de verdad** de todos los items criticos pendientes en LifeOS post-v0.4.0. Cada item tiene problema, solucion, archivos afectados, criterios de exito, y dependencias. El orden de ejecucion esta priorizado por impacto en la experiencia del usuario y riesgo de regresion.

**Regla de oro:** este PRD es el backlog. Cada sesion arranca con "¿por cual item del PRD vamos?". Al completar un item, se marca aca y se hace commit atomico.

---

## Clasificacion

| Nivel | Significado | Criterio |
|-------|-------------|----------|
| 🔴 P0 | Rompe la experiencia diaria del usuario | Usuario lo siente AHORA en cada sesion |
| 🟡 P1 | Bloquea una feature core o tiene riesgo de seguridad | No bloquea uso diario pero es importante |
| 🟢 P2 | Mejora o feature nuevo | Backlog — planificado pero no urgente |

---

## Tabla de items

| # | Prioridad | Item | Estado | Depende de |
|---|-----------|------|--------|------------|
| A | 🔴 P0 | llama-embeddings.service startup fix | pending | — |
| 1 | 🔴 P0 | Axi tray icon + senses enable bug | pending | A |
| 3 | 🔴 P0 | LLM model VRAM retention | pending | A (posible conflicto VRAM) |
| 5 | 🔴 P0 | Dashboard audit (data, timezone, CRUD) | pending | 1 (UI depende del daemon) |
| 4 | 🟡 P1 | SimpleX parity with Telegram | pending | — |
| 2 | 🟡 P1 | Game Guard audit | pending | — |
| S1 | 🟡 P1 | Security audit: self_improving.rs | pending | — |
| S2 | 🟡 P1 | Security audit: mcp_server.rs | pending | — |
| S3 | 🟡 P1 | Security audit: skill_generator.rs | pending | — |
| B | 🟡 P1 | COSMIC pre-upgrade snapshot | pending | — |
| I | 🟢 P2 | AMD/NVIDIA image split | pending | — |
| β | 🟢 P2 | Beta badge | pending | — |
| E | 🟢 P2 | Screenshot encryption (AES) | pending | — |
| N | 🟢 P2 | Nutrition pipeline BI.3 | pending | — |

---

# Items P0 (criticos)

## Item A — llama-embeddings.service startup fix

### Problema

`llama-embeddings.service` falla al arrancar en cada boot:

```
× llama-embeddings.service - LifeOS Semantic Embeddings Server
     Active: failed (Result: exit-code)
Process: 14257 ExecStartPre=/usr/local/bin/lifeos-embeddings-setup.sh
         (code=exited, status=1/FAILURE)
lifeos-embeddings-setup] LIFEOS_AI_AUTO_MANAGE_MODELS=false — skipping download
```

El setup script sale con **exit 1** cuando `LIFEOS_AI_AUTO_MANAGE_MODELS=false` y no hay modelo descargado, en vez de salir con 0 y dejar que el service se detenga limpio.

### Impacto

- Memoria semantica rota → Engram, cross_link_recent, tag search no funcionan
- Puede ser raiz del Item 1 (senses no persisten porque no pueden guardar events con embeddings)
- Ensucia el journal con "Failed Units: 1" en cada login

### Solucion propuesta

1. En `image/files/usr/local/bin/lifeos-embeddings-setup.sh`, cambiar el exit 1 del skip path a exit 0
2. En `image/files/usr/lib/systemd/system/llama-embeddings.service`, agregar `ExecStartPre=-` (dash) o hacer que el script devuelva un exit code especial (75 — SIGTEMPFAIL) que el service pueda interpretar como "skip, not error"
3. Opcion mas limpia: agregar `Type=notify` y que el script notifique a systemd antes de salir

### Archivos afectados

- `image/files/usr/local/bin/lifeos-embeddings-setup.sh`
- `image/files/usr/lib/systemd/system/llama-embeddings.service`

### Criterios de exito

- `systemctl status llama-embeddings.service` no muestra `failed`
- El service queda en `inactive (dead)` si no hay modelo, sin error
- O queda `active (running)` con el modelo cargado si esta disponible
- `systemctl list-units --state=failed` no lista este servicio

### Estimacion

30 minutos. Fix directo en el script.

---

## Item 1 — Axi tray icon + senses enable bug

### Problema

Dos bugs en la misma UI (tray icon de Axi en el panel superior):

**1.1 — El icono no abre el dashboard**
- Click en el icono de Axi no lanza el dashboard
- Esperado: abre `http://localhost:8081/` en el navegador predeterminado

**1.2 — Senses no pueden activarse**
- Usuario entra al menu de Axi, intenta activar sense (ej: Vision)
- Checkbox se palomea...
- ...y se despalomea inmediatamente
- Solo **Always-on** y **Habla** quedan persistentes
- Los demas (Vision, Screen, Audio capture, etc) se revierten

### Diagnostico hipotetico

El patron "check → uncheck automatico" es clasico de:
1. La UI hace optimistic update al hacer click (checkbox se palomea localmente)
2. Llama al daemon API para persistir el estado
3. El daemon API devuelve error (o el state no persiste)
4. La UI revierte el checkbox al estado real

El hecho de que Always-on y Habla **si** persistan indica que la UI y el API funcionan para *algunos* senses pero no para otros. Posibles causas:
- Los senses que fallan tienen dependencies externas (camera, llama-embeddings, etc)
- El daemon revierte el state cuando detecta que la dependency no esta disponible
- Item A (llama-embeddings broken) puede estar causando esto

### Impacto

**CRITICO.** Axi es el core de LifeOS. Si el usuario no puede habilitar los sentidos, LifeOS es una PC normal. No hay monitoreo, no hay contexto, no hay experiencia de companion.

### Plan de auditoria exhaustiva

#### Fase 1 — Diagnostico

1. Leer el codigo del tray icon (probablemente en `daemon/src/` bajo `tray.rs` o similar con feature `tray`)
2. Leer el codigo del menu de senses — ¿como llama al daemon API?
3. Leer el codigo del sensory pipeline state (`sensory_pipeline_state.json` en `~/.local/share/lifeos/`)
4. Leer el codigo del daemon que recibe el POST para activar sense
5. Identificar la ruta exacta: UI click → daemon endpoint → state persistence

#### Fase 2 — Tests reproducibles (TDD — Strict mode)

**Antes** de fixear nada, escribir tests que reproducen el bug:
- Test que intenta activar Vision sense via daemon API y espera que persista
- Test que verifica que el tray icon handler llama al endpoint correcto
- Test que verifica que el dashboard opens cuando click en icono
- Los tests deben FALLAR con el codigo actual (confirmando el bug)

#### Fase 3 — Fix

Implementar el fix hasta que los tests pasen. No tocar nada mas.

#### Fase 4 — Verify

- Tests pasan
- Manualmente en la laptop: click en icono abre dashboard
- Manualmente: activar cada sense y confirmar persistencia despues de reload

### Archivos a investigar (orden de exploracion)

1. `daemon/src/tray.rs` o similar (feature `tray` en Cargo.toml)
2. `daemon/src/sensory_pipeline.rs` o `daemon/src/senses/`
3. `daemon/src/api/` — endpoints para senses
4. `daemon/src/main.rs` — registro de rutas
5. Web dashboard (si el tray usa webview)

### Criterios de exito

- Click en tray icon abre el dashboard en el navegador
- Todos los senses se pueden activar y persisten al reload
- Al reiniciar la sesion, los senses activados antes siguen activados
- Tests automatizados cubren los dos bugs

### Estimacion

6-10 horas (incluye exploracion, tests, fix, verify).

---

## Item 3 — LLM model VRAM retention

### Problema

El modelo local (`Qwen3.5-4B` segun memory) se carga en VRAM al arrancar `llama-server`, pero:
- Se va a RAM o se descarga despues de un tiempo
- Afecta performance de todas las features que usan el modelo local

### Diagnostico hipotetico

Posibles causas:
1. **llama-embeddings compitiendo por VRAM** — si ambos servicios cargan modelos en GPU y el driver los swapea
2. **GPU layer offload config incorrecto** — `LIFEOS_LLAMA_GPU_LAYERS` no esta seteado al maximo o el auto-detect esta mal
3. **nvidia-persistenced no activo** — el driver descarga el contexto cuando no hay usuarios activos
4. **Kernel governor agresivo** — `powersave` o similar apagando la GPU
5. **Memory pressure** — algo mas en el sistema forza el swap

### Plan de auditoria

1. Leer `image/files/usr/local/bin/lifeos-llama-gpu-layers.sh` — logica de offload
2. Leer `image/files/etc/lifeos/llama-server.env` — variables de entorno
3. Leer `image/files/usr/lib/systemd/system/llama-server.service` — config del service
4. Verificar `nvidia-persistenced` status en la laptop
5. Revisar `nvidia-smi` mientras el modelo se carga y despues de X minutos para ver el comportamiento
6. Verificar si hay conflicto con `llama-embeddings.service` por VRAM

### Archivos afectados

- `image/files/usr/local/bin/lifeos-llama-gpu-layers.sh`
- `image/files/etc/lifeos/llama-server.env`
- `image/files/usr/lib/systemd/system/llama-server.service`
- `image/files/usr/lib/systemd/system/llama-embeddings.service`
- Posiblemente `image/files/etc/systemd/system/nvidia-persistenced.service.d/`

### Criterios de exito

- Modelo queda en VRAM durante sesion normal (sin actividad durante 30 min)
- `nvidia-smi` muestra VRAM occupied con los pesos del modelo
- Primer request despues de idle no tiene penalidad de carga
- Tests automatizados no aplicables (hardware-dependent) — verify manual

### Estimacion

4-6 horas.

---

## Item 5 — Dashboard audit

### Problema

El dashboard esta desactualizado y tiene varios problemas:
- **Hora incorrecta** — no usa la timezone local de la laptop
- **Datos desactualizados** — no refresca en tiempo real
- **Funcionalidades rotas** — varias vistas muestran errores o vacias
- **7 rutas CRUD recortadas** — workers, conversations, providers necesitan backend real

### Plan de auditoria

#### Fase 1 — Inventario

1. Listar todas las rutas del dashboard (`daemon/src/api/` + `lifeos-site/` o dashboard static)
2. Listar todos los endpoints del daemon que el dashboard consume
3. Para cada ruta, verificar: ¿carga? ¿muestra data valida? ¿tiene errores en consola?

#### Fase 2 — Fix timezone

1. Leer como se setea la hora en el dashboard
2. Asegurar que usa `iana-time-zone` (ya esta en Cargo.toml del daemon)
3. El dashboard debe mostrar la hora en la timezone local del sistema

#### Fase 3 — Fix data freshness

1. Verificar WebSocket connection para live updates
2. Si no hay WebSocket, agregar polling con interval configurable
3. Timestamp visible en cada widget ("Actualizado hace X segundos")

#### Fase 4 — Completar CRUD routes

Las 7 rutas recortadas necesitan backend real:
- Workers
- Conversations
- Providers
- Otras 4 (identificar en la auditoria)

### Archivos a investigar

- `daemon/src/api/` — endpoints
- `image/files/usr/share/lifeos/dashboard/` — frontend estatico (si aplica)
- `lifeos-site/` — si el dashboard usa este codigo
- `daemon/src/main.rs` — registros de rutas

### Criterios de exito

- Todas las rutas del dashboard cargan sin errores
- Hora mostrada coincide con `date` en la laptop
- WebSocket o polling actualiza los datos sin reload manual
- Las 7 rutas CRUD permiten ver/crear/editar/borrar sus entidades
- Lighthouse score > 90 (opcional, nice-to-have)

### Estimacion

8-12 horas.

---

# Items P1 (importantes)

## Item 4 — SimpleX parity con Telegram

### Problema

SimpleX fue elegido como canal privado primario. Telegram tiene 158+ tools registrados. SimpleX debe estar **al 100% de paridad** con Telegram, y agregar mas si es posible.

### Plan de auditoria

1. Listar todos los tools registrados en `daemon/src/telegram_tools.rs`
2. Listar todos los tools en `daemon/src/simplex_bridge.rs` (o equivalente)
3. Diff: que tools tiene Telegram que SimpleX no tiene
4. Para cada tool faltante: portar a SimpleX
5. Verificar: rate limiting, brute force protection, security hardening
6. Tests E2E de cada tool via SimpleX

### Archivos

- `daemon/src/telegram_tools.rs`
- `daemon/src/simplex_bridge.rs`
- `daemon/src/main.rs` — registros

### Criterios de exito

- Cada tool de Telegram tiene equivalente en SimpleX
- Security hardening identico (rate limit, whitelist, etc)
- Tests automatizados por cada tool
- Documentacion actualizada

### Estimacion

1-2 dias.

---

## Item 2 — Game Guard audit

### Problema

Game guard detecta cuando hay un juego corriendo y ajusta el comportamiento del sistema (throttle background tasks, etc). Necesita auditoria exhaustiva.

### Plan de auditoria

1. Leer codigo actual de game_guard (probablemente `daemon/src/game_guard.rs` o similar)
2. Testar deteccion con varios juegos (Steam, Lutris, Heroic)
3. Verificar que el throttle se aplica y se revierte correctamente
4. Tests automatizados

### Archivos

- Buscar `game` en daemon/src/
- `image/files/etc/sudoers.d/lifeos-axi` — si tiene rules para game mode

### Criterios de exito

- Deteccion correcta de juegos conocidos
- Throttle se aplica al entrar y se remueve al salir
- No false positives
- Tests automatizados

### Estimacion

4-6 horas.

---

## Items S1, S2, S3 — Security audits

### S1 — self_improving.rs

**Vulnerabilidades conocidas:**
- `workflow_actions.json` sin HMAC (injection si un atacante modifica el archivo)
- Auto-trigger sin aprobacion del usuario (ejecuta codigo arbitrario)
- Presence detection manipulable (puede engañar al modulo)

**Fixes requeridos:**
1. HMAC-SHA256 de `workflow_actions.json` con key en el keyring del usuario
2. Workflow aprobacion: notificacion al usuario ANTES de ejecutar
3. Endurecer presence detection (multiple sources, cross-check)

### S2 — mcp_server.rs

**Vulnerabilidades:**
- `lifeos_shell` usa `sh -c` con input sin sanitizar → **command injection**
- Sin whitelist de comandos permitidos
- Sin rate limiting
- Path traversal posible en operations de filesystem

**Fixes:**
1. Reemplazar `sh -c` con `Command::new().arg().arg()` (argv)
2. Whitelist de comandos permitidos en `/etc/lifeos/mcp-whitelist.toml`
3. Rate limiting: max N requests por minuto
4. Path normalization + chroot logico a directorios permitidos

### S3 — skill_generator.rs

**Vulnerabilidades:**
- LLM output se ejecuta raw en bash → **code injection**
- Skills se persisten sin consentimiento del usuario
- Sin sandbox al ejecutar

**Fixes:**
1. Approval workflow: usuario ve el codigo generado ANTES de ejecutar
2. Ejecucion en sandbox (bubblewrap o similar)
3. Validar que el output del LLM no contiene comandos peligrosos (basic filter)
4. Permanent storage solo despues de aprobacion explicita

### Archivos

- `daemon/src/self_improving.rs`
- `daemon/src/mcp_server.rs`
- `daemon/src/skill_generator.rs`

### Criterios de exito

- Tests de seguridad cubren cada vulnerabilidad listada
- No hay `sh -c` con user input en ninguno de los 3 modulos
- Audit log de todas las acciones sensibles
- Ningun fallo en `cargo audit`

### Estimacion

1 dia cada uno (3 dias total).

---

## Item B — COSMIC pre-upgrade snapshot

### Problema

Durante `bootc upgrade`, los paquetes COSMIC pueden resetear la config del usuario. Esto paso el 2026-04-10 — varios archivos de `~/.config/cosmic/` fueron reescritos a defaults.

### Solucion

Sistema de snapshot + restore manual:

1. **Script de snapshot** `lifeos-cosmic-snapshot.sh`:
   - Se ejecuta ANTES de `bootc upgrade --apply` (via hook del update script)
   - Copia `~/.config/cosmic/` → `~/.local/share/lifeos/cosmic-snapshots/pre-upgrade-{timestamp}/`
   - Guarda `rpm -qa | grep cosmic` en `.cosmic-rpm-versions`

2. **Script de restore** `lifeos-cosmic-restore.sh`:
   - Lee snapshot especifico
   - Copia de vuelta a `~/.config/cosmic/`
   - Sugiere cerrar sesion y reentrar

3. **Service post-upgrade** `lifeos-cosmic-post-upgrade.service` (user unit):
   - Corre al primer login post-reboot
   - Compara `rpm -qa | grep cosmic` actual vs snapshot
   - Si difiere: notificacion al usuario
     > "LifeOS detecto que COSMIC se actualizo. Tu config puede haber cambiado. Para restaurar: `life cosmic restore-snapshot`"

4. **Subcomando CLI** `life cosmic`:
   - `life cosmic list-snapshots` — lista snapshots disponibles
   - `life cosmic restore-snapshot <timestamp>` — restaura uno
   - `life cosmic snapshot` — crea uno manual

### Archivos a crear

- `image/files/usr/local/bin/lifeos-cosmic-snapshot.sh`
- `image/files/usr/local/bin/lifeos-cosmic-restore.sh`
- `image/files/usr/lib/systemd/user/lifeos-cosmic-post-upgrade.service`
- `cli/src/commands/cosmic.rs` — nuevo subcomando
- Integracion con `scripts/update-lifeos.sh` para llamar snapshot antes de upgrade

### Criterios de exito

- Despues de `bootc upgrade`, si COSMIC se reseto, el usuario recibe notificacion
- `life cosmic list-snapshots` muestra los snapshots con timestamps legibles
- `life cosmic restore-snapshot <ts>` restaura correctamente
- Tests unitarios del CLI subcomando

### Estimacion

6-8 horas.

---

# Items P2 (backlog)

## Item I — AMD/NVIDIA image split

### Problema

El Containerfile instala NVIDIA drivers siempre, aunque el usuario tenga hardware AMD. Imagen inflada innecesariamente.

### Solucion

- `lifeos:latest` = base AMD/Intel, sin NVIDIA (mas liviana)
- `lifeos:nvidia` = base + NVIDIA driver + akmods + signing

### Archivos

- `image/Containerfile` — refactor con build args
- `.github/workflows/release-channels.yml` — matrix para ambas variantes
- Canales: `lifeos:stable`, `lifeos:stable-nvidia`, etc

### Estimacion

1-2 dias.

---

## Item β — Beta badge

Indicador visible de que LifeOS esta en beta:
- README.md header
- Dashboard top-right
- lifeos-site landing

### Archivos

- `README.md`
- Dashboard (donde este el header)
- `lifeos-site/src/...`

### Estimacion

1-2 horas.

---

## Item E — Screenshot encryption (AES)

Refactor de todos los read/write sites de screenshots para usar AES-GCM. Key en keyring.

### Archivos

- `daemon/src/screenshots.rs` o similar
- Todos los sites que leen screenshots
- Nuevo `daemon/src/encryption.rs` si no existe

### Estimacion

1-2 dias (grande por el refactor).

---

## Item N — Nutrition pipeline BI.3

Pipeline foto/voz → nutrition_log incompleta.

### Archivos

- `daemon/src/nutrition/` o similar
- Dashboard view para review/edit

### Estimacion

1 dia.

---

# Orden de ejecucion recomendado

## Fase 1 — Untangle the knot (esta semana)

1. **Item A** (30 min) — Quick win, destapa posible raiz
2. **Item 1** (6-10h) — Core UX, depende de A
3. **Item 3** (4-6h) — Performance AI, puede estar conectado con A y 1

**Gate:** Despues de Fase 1, el usuario debe poder usar Axi normalmente en su laptop.

## Fase 2 — Dashboard (siguiente)

4. **Item 5** (8-12h) — UX visible, aprovecha el contexto del Item 1

**Gate:** Dashboard funcional con datos correctos y hora local.

## Fase 3 — Privacidad y seguridad

5. **Item 4** (1-2 dias) — SimpleX parity
6. **Items S1, S2, S3** (3 dias) — Security audits

**Gate:** LifeOS listo para distribucion publica sin riesgos de seguridad criticos.

## Fase 4 — Estabilidad y features

7. **Item B** (6-8h) — COSMIC snapshot
8. **Item 2** (4-6h) — Game guard

## Fase 5 — Optimizacion y polish

9. **Item I** (1-2 dias) — AMD/NVIDIA split
10. **Item β** (1-2h) — Beta badge
11. **Item E** (1-2 dias) — Screenshot encryption
12. **Item N** (1 dia) — Nutrition pipeline

---

# Reglas de ejecucion

1. **Un item por commit** — atomicos, faciles de revertir
2. **TDD estricto** — tests primero, fix despues, verify al final
3. **`scripts/local-ci.sh` antes de cada push** — sin excepciones
4. **Verify manual en la laptop** — despues de cada fix, probar antes de seguir
5. **Update del PRD** — marcar items completados con fecha y commit SHA
6. **Commit message format:** `fix(module): descripcion corta` o `feat(module): descripcion corta`

---

# Tracking

| # | Item | Estado | Commit | Fecha |
|---|------|--------|--------|-------|
| A | llama-embeddings fix | ✅ done | d1b013d | 2026-04-10 |
| 1 | Axi tray + senses | ✅ done | 7625d94 | 2026-04-10 |
| 3 | VRAM retention | ✅ done | 7db18fe | 2026-04-10 |
| 5 | Dashboard timezone | 🟡 partial | a957ff4 | 2026-04-10 |
| 4 | SimpleX parity | ✅ done | ebd72e4 | 2026-04-10 |
| 2 | Game guard | ✅ audit-only | 6cc7509 | 2026-04-10 |
| S1 | self_improving audit | ✅ audit-only | — | 2026-04-10 |
| S2 | mcp_server audit | ✅ done | 099646e | 2026-04-10 |
| S3 | skill_generator audit | ✅ done | 099646e | 2026-04-10 |
| B | COSMIC snapshot | ✅ done | 49bcd3d | 2026-04-10 |
| I | AMD/NVIDIA split | 🟡 scaffolded | ba6235c | 2026-04-10 |
| β | Beta badge | ✅ done | ec2b30c | 2026-04-10 |
| E | Screenshot encryption | ⬜ pending | — | — |
| N | Nutrition pipeline | ⬜ pending | — | — |

## Legend

- ✅ **done** — committed and ready to verify on hardware
- ✅ **audit-only** — audited, no code change needed (S1) or only doc-level (#2)
- 🟡 **partial** — core fix landed, follow-ups deferred to a dedicated sprint
- 🟡 **scaffolded** — anchor point in place, full refactor pending
- ⬜ **pending** — not yet started

## Deferred follow-ups (next sprints)

- **#5 dashboard CRUD routes:** GET /conversations, GET /workers, POST /llm/providers, POST /llm/providers/:name/toggle, POST /system/mode, POST /workers/:id/cancel, GET /sessions. Require cross-bridge state merging and API layer expansion.
- **#I AMD/NVIDIA split:** wire the `LIFEOS_IMAGE_VARIANT` arg through the Containerfile conditionals, skip nvidia stage inputs on AMD, update CI matrix.
- **#S2 mcp_server full sandbox:** replace blocklist with allowlist + argv exec + bubblewrap. Current state is "disabled by default, opt-in accepts the risk".
- **#S3 skill_generator approval UI:** human-in-the-loop first-run approval, HMAC on manifests, sandbox via systemd transient units with DynamicUser.
- **#S1 workflow_actions HMAC:** defense-in-depth even though self_improving.rs has no exec path today.
- **COSMIC post-upgrade notification service** (#B extension): user-facing prompt when a COSMIC package version change is detected post-upgrade.
- **Unified `life cosmic {list, restore}` CLI subcommand** (#B extension): thin wrapper over the existing shell utility.

---

# Notas finales

Este PRD es un documento vivo. Cuando se complete un item:
1. Marcar en la tabla de tracking con commit SHA y fecha
2. Si se descubren sub-items durante la ejecucion, agregarlos a la seccion del item correspondiente
3. Si aparecen items nuevos, agregarlos con prioridad clasificada

**Mantra:** Pequeno, probado, verificado. Sin atajos.
