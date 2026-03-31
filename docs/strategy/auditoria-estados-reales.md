# Auditoria de Estados Reales de LifeOS

**Fecha de corte:** 2026-03-31

**Objetivo:** Tener una vista unica y honesta de que esta:

- validado en host real
- integrado en repo pero no validado en host
- implementado de forma parcial
- presente solo detras de feature flags o wiring opcional
- reabierto por bugs reales encontrados

## Leyenda

- **Host validado:** Codigo integrado y observado funcionando en laptop/host real
- **Repo integrado:** Cableado en runtime y con evidencia razonable en codigo, pero sin validacion host reciente
- **Parcial:** Hay modulo, helper o parte del flujo, pero no la experiencia end-to-end
- **Shipped deshabilitado:** Existe en repo, pero la imagen por defecto no lo compila o no lo arranca
- **Reabierto:** Se marco completo antes, pero la auditoria encontro ruptura real

## Matriz actual

| Fase | Estado real | Nota corta |
|------|-------------|------------|
| A | Host validado | Telegram, LLM router, supervisor y cola tuvieron evidencia de uso real |
| B | Repo integrado | Sin hallazgo fuerte de ruptura en esta pasada |
| C | Repo integrado | Dashboard/supervisor metrics existen; falta una pasada host dedicada |
| D | Repo integrado | Multimedia Telegram y web search tienen wiring claro; no fue el foco de esta pasada |
| E | Repo integrado | Calendario, scheduled tasks y approval flow estan cableados |
| F | Shipped deshabilitado | WhatsApp/Matrix/Signal/Home Assistant existen, pero la imagen default no compila esas features |
| G | Reabierto | Game Guard tuvo falsos positivos y override stale en host real |
| H | Repo integrado | No se hallo ruptura puntual en esta pasada, pero queda pendiente validacion host |
| I | Repo integrado | Flujo git/autonomia presente; pendiente auditoria fina de claims mas ambiciosos |
| J | Repo integrado | Browser/CDP existe; pendiente validacion profunda por casos reales |
| K | Repo integrado | Hay skill registries y hot-reload; revisar claims de UX/herramientas concretas |
| L | Repo integrado | Voz/widget/notificaciones existen; pendiente auditoria host dedicada |
| M | Repo integrado | Claim amplio; necesita una pasada especifica por deploy/review/paralelismo |
| N | Parcial | Desktop operator va fuerte, pero bateria estaba sobredeclarada en API (`/battery/history` no aparecio) |
| O | Parcial | Base autonoma de desktop existe; auto-aprendizaje y skill extraction/refinement siguen incompletos |
| P | Repo integrado | Gaming assist y captura existen en repo; falta una validacion host dedicada |
| Q | Parcial | MCP client/server existen, pero dashboard e historia de pre-integraciones seguian inflados |
| R | Reabierto | Detecta/graba, pero no transcribe/diariza/resume automaticamente |
| S | Parcial | Health monitor y dashboard existen; reportes/cobertura integral siguen por validar |
| T | Parcial | Voz mejoro mucho, pero no debe venderse como voice pipeline completamente cerrado estilo Alexa |
| U | Parcial | Tuner/predictor/scheduler existen, pero el loop de self-improvement total sigue parcial |
| V | Parcial | Knowledge graph real existe, pero export/import y “memoria total” seguian sobredeclarados |
| W | Parcial | ReliabilityTracker existe; checkpoint/resume general y audit trail explicable siguen incompletos |
| X | Parcial | Translation module existe en repo, pero no aparecio integrado al producto real end-to-end |
| Y | Repo integrado | Security AI daemon existe y se arranca; queda pendiente una pasada host dedicada |
| Z-AA | Pendiente AX | No eran el foco principal de esta pasada |
| AB | Parcial | WebSocket basico existe, pero protocolo y session durability estan sobredeclarados |
| AC | Parcial | Registry/manifest existen; `life skills doctor` no existe como comando real |
| AD | Parcial | Hay guardrails y `/metrics`, pero faltan claims como `life audit query` y schema/doc baseline comprobable |
| AE | Repo integrado | ISO y first-boot avanzaron; el incidente de doble `lifeosd` obliga a seguir vigilando ownership/runtime |
| AF | Parcial | Slack/Discord existen como modulos, pero no estan arrancados por `main.rs` |
| AG | Parcial | Dedupe y pairing basico si; transcript export no quedo comprobado y cron validation es limitada |
| AK | Parcial | Watchdog, safe mode, config store y sentinel existen, pero los endpoints/CLI de health y repair estaban sobredeclarados |
| AL | Parcial | Seguridad mejoro, pero `life doctor`, ciertos eventos WS y parte del troubleshooting estaban inflados |
| AM | Repo integrado | `time_context()` y `current_time` estan cableados; falta pasada integral de storage/cron |
| AN | Repo integrado | Hot reload y herramientas de providers tienen evidencia fuerte en repo |
| AO | Parcial | UX de Telegram mejoro mucho, pero webhook seguia inflado y no todo el polish esta igualmente validado |
| AP | Parcial | Worker pool/cancel existen, pero sub-workers, steering consumido y eventos `worker.*` no aparecieron cableados end-to-end |
| AQ+ | Futuro | No forman parte de la auditoria de realidad actual |

## Hallazgos mas importantes de esta pasada

### 1. Repo no es lo mismo que imagen ni que host

- La imagen actual compila `lifeosd` con `dbus,http-api,ui-overlay,wake-word,speaker-id,telegram,tray`
- Eso deja fuera por defecto `whatsapp`, `matrix`, `signal`, `slack`, `discord` y `homeassistant`
- Por tanto, varios claims de canales estaban describiendo capacidad potencial del repo, no capacidad shipped real

### 2. Reuniones estaban sobredeclaradas

- El runtime detecta reuniones y graba `.wav`
- Existen helpers para transcribir, diarizar, resumir y comprimir
- El flujo real termina en `TODO: trigger transcription + summarization`
- En host real habia solo grabaciones `.wav`, sin artefactos finales

### 3. Game Guard no estaba cerrado

- El host mostro falsos positivos por `gamemoded`
- Tambien detectaba al propio `llama-server` como “juego” por VRAM
- El fix ya existe en repo, pero hasta desplegarlo no debemos volver a marcar el hito como completo

### 4. AB estaba muy inflada

- `/ws` existe
- Pero el `connect` real solo pide token; no `protocolVersion`, `role`, `scopes[]`, `capabilities[]`
- `SessionStore` existe e inicializa, pero no aparecio conectado al flujo principal de bridges

### 5. AK, AL y AP tambien tenian huecos concretos

- `life safe-mode ...` y `life doctor --repair` aparecen en estrategia y troubleshooting, pero no existen como comandos CLI reales
- El sentinel real consulta `/api/v1/health`, no `/alive`
- El API real expone un `health` agregado, no el trio `alive/ready/deep` como estaba documentado
- `task.progress`, `task.step_completed` y `worker.*` no aparecieron cableados como eventos WebSocket reales
- El worker pool si existe, pero la capa de sub-workers y steering consumido seguia sobreprometida
- La compaction en uso real sigue ocurriendo sobre todo en `telegram_tools.rs`, no en un session layer transversal ya adoptado por todos los canales

### 6. N-Q y S-Y tambien necesitaban bajar varios claims

- `battery/status` y `battery/threshold` si existen, pero `battery/history` no aparecio en el API real
- Fase O tenia buena base de operador autonomo, pero el loop de aprender skills a partir de interacciones reales no quedo cableado de forma demostrable
- MCP client/server existe con base solida, pero la historia de dashboard e “integraciones MCP” seguia inflada
- El dashboard si muestra salud del sistema, pero los reportes integrales diarios/semanales por Telegram no quedaron demostrados como estaban escritos
- `RealtimeTranslator`, `translate_file()` e `interpret_voice()` existen en `translation.rs`, pero no aparecieron cableados al producto como experiencia realmente shippeada
- Knowledge graph y reliability tienen base real, pero export/import, checkpoint/resume general y audit trail explicable seguian por debajo de la narrativa

### 7. AG, AO y AA tambien necesitaban aterrizaje final

- AG aparecia en resumenes como si ya incluyera transcript export resuelto, pero esa evidencia no aparecio
- AO si tiene avances reales en Telegram UX, pero `LIFEOS_TELEGRAM_WEBHOOK_URL` hoy no activa un webhook completo; el bridge sigue en polling
- AA tiene una base visual fuerte en repo e imagen, pero buena parte del cierre final sigue dependiendo de validacion humana en boot real, rendering y consistencia visual completa

## Reuniones: estado real de retencion hoy

- Los audios crudos se guardan en `data_dir/meetings/`
- `storage_housekeeping.rs` ya aplica una politica parcial:
- maximo `120` archivos por directorio gestionado
- borrado por antiguedad de meetings mayores a `30` dias
- housekeeping corre cada `6` horas desde el daemon

Lo que TODAVIA no esta resuelto de forma completa:

- que artefacto final conservar ademas del audio crudo
- si el `.wav` debe borrarse al generar `.opus`/transcript/resumen
- cuanto tiempo debe vivir un resumen o transcript
- que se sube a memoria permanente y con que criterios
- como auditar una reunion larga sin dejar basura innecesaria

## Regla operativa a partir de ahora

Cuando un claim diga "completo", debe especificar implicitamente cual de estas realidades describe:

- completo en host real
- completo en repo
- completo solo si se compila con ciertas features

Si no podemos decir cual de las tres es, no debe estar en `[x]`.
