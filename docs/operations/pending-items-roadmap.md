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
| 4 | ✅ Done | SimpleX as sole remote chat channel | done | Telegram removed 2026-04-13 |
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

## Item 4 — SimpleX como canal remoto unico (cerrado)

### Resolucion

2026-04-13: el bridge de Telegram, el bridge de Matrix y el loop de email
conversacional fueron removidos. LifeOS ahora tiene solo dos canales de chat:

- **SimpleX** — remoto, privacy-first, E2E encriptado, sin numero de telefono
- **Dashboard** — UI web local en `http://127.0.0.1:8081/dashboard`

El motor agentico compartido vive en `daemon/src/axi_tools.rs` (renombrado
desde `telegram_tools.rs`). La feature flag es `messaging` (renombrada desde
`telegram`). No hay paridad pendiente — SimpleX usa el mismo `ToolContext`
que el dashboard, todos los tools estan disponibles en ambos canales.

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
| 🦎 | Dev-mode dual-image arch | ✅ phases 1+2+4 | c4da89f, 3bf1f5c, 6c1a478 | 2026-04-11 |
| W | STT pipeline upgrade (Vulkan + large-v3-turbo + streaming) | ⬜ pending | — | — |

## Legend

- ✅ **done** — committed and ready to verify on hardware
- ✅ **audit-only** — audited, no code change needed (S1) or only doc-level (#2)
- 🟡 **partial** — core fix landed, follow-ups deferred to a dedicated sprint
- 🟡 **scaffolded** — anchor point in place, full refactor pending
- ⬜ **pending** — not yet started

## Item W — STT pipeline upgrade (Vulkan + large-v3-turbo + streaming)

### Problema

El stack de STT de LifeOS esta dejando muchisima performance y calidad sobre
la mesa. Tres observaciones concretas del build actual (`image/Containerfile`
lineas 141-173):

1. **whisper.cpp se compila 100% CPU-only**. El cmake no pasa
   `-DWHISPER_VULKAN=ON` ni `-DWHISPER_CUDA=ON` ni `-DWHISPER_OPENBLAS=ON`.
   En una laptop con NVIDIA 5070 Ti (12 GB VRAM) que YA corre llama-server
   en Vulkan, estamos desperdiciando el acelerador mas importante del
   sistema para speech-to-text.

2. **Solo shippeamos `ggml-base.bin` (74 MB) y `ggml-tiny.bin` (39 MB)** —
   los dos modelos mas chicos de la familia Whisper. Sus WERs
   aproximadas:

   | Modelo | Tamaño | WER inglés | WER español |
   |--------|--------|------------|-------------|
   | tiny (shipped) | 39 MB | ~13-15% | ~25-30% |
   | **base (default)** | 74 MB | ~9-11% | ~18-22% |
   | small | 244 MB | ~7-9% | ~12-15% |
   | medium | 769 MB | ~5-7% | ~8-10% |
   | large-v3 | 1.5 GB | ~4-5% | ~5-7% |
   | **large-v3-turbo** | 800 MB | ~4-6% | ~6-8% |

   Alexa/Google estan en ~4-6% WER con custom models, noise suppression,
   beamforming, y domain adaptation. Nosotros en ~9-11% con el modelo
   base, sin GPU, en batch mode. La brecha es grande.

3. **El daemon usa `whisper-cli` (batch mode), no `whisper-stream`**
   (streaming mode). `daemon/src/api/mod.rs:2550` tiene:
   ```rust
   const DEFAULT_STT_BINARY: &str = "whisper-cli";
   ```
   Aunque el Containerfile compila `whisper-stream` tambien, no lo
   usamos. Resultado: la latencia percibida "end of speech →
   transcription" es ~500ms+ porque el modelo ni siquiera empieza a
   procesar hasta que el usuario termina de hablar.

### Impacto

- **Calidad**: en español conversacional el WER es ~18-22% — uno de cada
  5 tokens es incorrecto. Esto hace que los comandos por voz fallen
  frecuentemente, especialmente con nombres propios, numeros, o palabras
  poco comunes.
- **Latencia**: percibida ~500-800ms desde que el usuario termina de
  hablar hasta que aparece el transcript. Alexa/Google responden en
  ~100-200ms porque son streaming.
- **Hardware desperdiciado**: la GPU esta 95% idle durante STT.

### Sub-fases

#### W.1 — Vulkan build flag (quick win, 30 min)

Agregar `-DWHISPER_VULKAN=ON` al cmake de la stage 3 del Containerfile.
whisper.cpp detecta Vulkan en runtime y hace fallback a CPU si no
esta disponible (importante para imagenes AMD del split del item #I).

```dockerfile
cmake -S /tmp/whisper.cpp -B /tmp/whisper.cpp/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_SDL2=ON \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_VULKAN=ON   # ← NUEVO
```

**Impacto esperado**: 5-10x mas rapido en GPU vs CPU.

**Archivos**: `image/Containerfile` (lineas 151-156).

#### W.2 — Shippar large-v3-turbo como modelo default (1 h)

Agregar la descarga del modelo `ggml-large-v3-turbo.bin` (~800 MB) en la
stage 3, y cambiar el default en el daemon para preferirlo sobre `base`.

```dockerfile
curl -fSL --retry 3 --connect-timeout 60 \
  -o /out/models/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

En `daemon/src/api/mod.rs` actualizar el model resolution para preferir
`ggml-large-v3-turbo.bin` cuando existe, con fallback a `base` si no.

**Impacto esperado**: WER de ~9-11% → ~4-6% en ingles, ~18-22% → ~6-8%
en español. Casi 3x mejor en español.

**Costo**: imagen ~800 MB mas grande. Aceptable — LifeOS ya es una
imagen grande por los modelos AI bundled.

**Archivos**: `image/Containerfile`, `daemon/src/api/mod.rs` (linea ~2600).

#### W.3 — Migrar daemon API a whisper-stream (4-6 h)

Reemplazar el spawn de `whisper-cli` con `whisper-stream` en modo
persistent daemon. `whisper-stream` corre como un proceso long-running
que acepta audio chunks via stdin y emite transcripts parciales via
stdout. El daemon mantiene una sola instancia con el modelo cargado
permanentemente (no re-cargar por request).

Tareas:
- Nuevo `daemon/src/whisper_stream.rs` con la struct que maneja el
  proceso
- Canal tokio para audio in, canal tokio para transcripts out
- Manejo de restart si el proceso muere
- Deprecar el path de `whisper-cli` (mantener como fallback)

**Impacto esperado**: latencia percibida ~500ms → ~100-200ms. Primera
palabra del transcript aparece mientras el usuario sigue hablando.

**Archivos**: `daemon/src/api/mod.rs` (linea ~2794), nuevo
`daemon/src/whisper_stream.rs`.

#### W.4 — VAD (voice activity detection) (6-8 h, futuro)

Agregar silero-vad o webrtc-vad antes del STT para segmentar audio en
chunks solo cuando hay voz. Evita correr el modelo sobre silencio y
mejora la segmentacion de utterances.

#### W.5 — Noise suppression con RNNoise (1-2 dias, futuro)

Pipeline de audio: mic → RNNoise → whisper-stream. RNNoise es un
modelo pequeño (100 KB) que corre en tiempo real en CPU y remueve
ruido de fondo. Mejora el WER en ambientes con ruido ~10-20%.

### Criterios de exito

- [ ] W.1: `whisper-cli --list-devices` muestra Vulkan/NVIDIA en la
      imagen dev buildeada
- [ ] W.1: transcripcion de un audio de 60 segundos usa GPU (verificable
      con `nvidia-smi` durante la ejecucion)
- [ ] W.2: `ls /usr/share/lifeos/models/whisper/` muestra
      `ggml-large-v3-turbo.bin`
- [ ] W.2: transcripcion manual de un audio de prueba en español tiene
      WER < 10% (actual ~20%)
- [ ] W.3: primer token del transcript aparece < 500ms despues del
      onset de audio
- [ ] W.3: `ps aux | grep whisper-stream` muestra un solo proceso
      persistent
- [ ] W.4, W.5: deferred to dedicated sprints

### Estimacion

- W.1 + W.2: ~1.5 h (quick wins — 70% del beneficio)
- W.3: 4-6 h (cambio de arquitectura del daemon)
- W.4 + W.5: 1-2 dias cada uno

**Prioridad recomendada**: W.1 y W.2 primero, en la siguiente sesion
despues de activar dev mode. W.3 como sprint dedicado. W.4 y W.5
futuro.

### Contexto: por que no estamos cerca de Alexa/Google

Incluso con los 5 upgrades, no vamos a igualar Alexa/Google. Ellos
tienen ventajas que ningun modelo solo puede cerrar:

1. **Beamforming con array de microfonos** (hardware dedicado en
   Echo/Nest)
2. **AEC (acoustic echo cancellation)** — eliminan el eco de sus
   propios speakers
3. **Domain adaptation** — sus modelos estan entrenados con sesgo
   hacia comandos ("reproduce X", "pon un timer", etc.)
4. **Custom acoustic models** entrenados con millones de horas en
   condiciones reales (niños, acentos, ruido)
5. **Hardware DSP dedicado** para keyword spotting sin cargar la CPU
6. **Streaming ASR de baja latencia** que ya tienen maduro
7. **Billions of queries per day** para fine-tuning continuo

Nosotros tenemos 0 de las 7. La meta realista es acercarnos a
~5-6% WER en español con audio limpio y latencia sub-300ms — eso
ya seria competitivo para un assistente local-first que NO envia
audio a la nube.

---

## Post-session addition: Developer Bootstrap (reemplaza dual-image)

La arquitectura dual-image (`localhost/lifeos:dev`) fue reemplazada por el
**developer bootstrap** — un script host-side que instala la sudo policy y
dropins sin tocar la imagen. Ver
[`docs/operations/developer-bootstrap.md`](developer-bootstrap.md).

**Estado actual (unify-image-kill-dev-mode):**
- Fase 1 ✅ — Containerfile limpio (sin ARG de build-mode)
- Fase 2 ✅ — `scripts/assert-no-dev-artifacts.sh` + CI guard + pre-commit hook
- Fase 3 ✅ — `scripts/lifeos-dev-bootstrap.sh` con `--with-sentinel`
- Fase 4 ✅ — Update stage: `lifeos-update-stage.sh` + service + timer
- Fase 5 ✅ — CLI `life update {status,check,stage,apply,rollback}` refactorizado
- Fase 6 ✅ — Docs migrados (`developer-bootstrap.md`, `update-flow.md`)

Para migrar: seguir los 9 pasos en `docs/operations/developer-bootstrap.md`.

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
