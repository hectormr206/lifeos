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
| G | Repo integrado | Fix en repo + tests para falsos positivos (gamemoded, llama-server), pendiente deploy host |
| H | Repo integrado | No se hallo ruptura puntual en esta pasada, pero queda pendiente validacion host |
| I | Repo integrado | Flujo git/autonomia presente; pendiente auditoria fina de claims mas ambiciosos |
| J | Repo integrado | Browser/CDP existe; pendiente validacion profunda por casos reales |
| K | Repo integrado | Hay skill registries y hot-reload; revisar claims de UX/herramientas concretas |
| L | Repo integrado | Voz/widget/notificaciones existen; pendiente auditoria host dedicada |
| M | Repo integrado | Claim amplio; necesita una pasada especifica por deploy/review/paralelismo |
| N | Repo integrado | Desktop operator va fuerte; `battery/history` ya existe con contrato honesto de snapshot actual |
| O | Parcial | Desktop operator funciona; skill learning desde uso real no esta wired |
| P | Repo integrado | Gaming assist y captura existen en repo; falta una validacion host dedicada |
| Q | Parcial | MCP client/server base funciona; dashboard integration es basica |
| R | Repo integrado | Pipeline wired end-to-end (transcribe → diarize → summarize → memory → notify → compress), pendiente validacion host |
| S | Parcial | Health checks existen y dashboard muestra estado; reportes diarios/semanales por Telegram no wired |
| T | Parcial | Voz funciona (wake word, STT, TTS), pero no es un pipeline Alexa-style completo end-to-end |
| U | Parcial | Prompt evolution y workflow learner existen; full self-improvement loop sigue parcial |
| V | Parcial | Knowledge graph existe y se consulta; export/import no implementados |
| W | Parcial | ReliabilityTracker existe; checkpoint/resume y audit trail son basicos |
| X | Parcial | Translation module existe en repo, pero no aparecio integrado al producto real end-to-end |
| Y | Repo integrado | Security AI daemon existe y se arranca; queda pendiente una pasada host dedicada |
| Z-AA | Pendiente AX | No eran el foco principal de esta pasada |
| AB | Repo integrado | SessionStore conectado a Telegram bridge, persiste across restarts; protocolo WS aun basico |
| AC | Repo integrado | Registry/manifest existen y `life skills doctor` ya esta implementado como baseline diagnostics |
| AD | Parcial | Hay guardrails, `/metrics` y `life audit`, pero no un query fino de ledger tipo `llm_call` como estaba redactado |
| AE | Repo integrado | ISO y first-boot avanzaron; el incidente de doble `lifeosd` obliga a seguir vigilando ownership/runtime |
| AF | Repo integrado | Slack/Discord wired a startup en main.rs, feature-gated; pendiente compilar en imagen |
| AG | Parcial | Dedupe, pairing basico y export de conversacion si; cron validation sigue siendo baseline |
| AK | Repo integrado | `life doctor` + `life safe-mode` CLI commands implementados; sentinel y watchdog funcionales |
| AL | Parcial | Seguridad mejoro, pero `life doctor`, ciertos eventos WS y parte del troubleshooting estaban inflados |
| AM | Repo integrado | `time_context()` y `current_time` estan cableados; falta pasada integral de storage/cron |
| AN | Repo integrado | Hot reload y herramientas de providers tienen evidencia fuerte en repo |
| AO | Parcial | Telegram UX mejorada (inline keyboards, typing, etc.); webhook es polling-only, no webhook real |
| AP | Parcial | Worker pool/cancel existen; los lifecycle updates siguen saliendo como `Notification`, no como eventos `worker.*` estructurados end-to-end |
| AQ+ | Futuro | No forman parte de la auditoria de realidad actual |

## Hallazgos mas importantes de esta pasada

### 1. Repo no es lo mismo que imagen ni que host

- La imagen actual compila `lifeosd` con `dbus,http-api,ui-overlay,wake-word,speaker-id,telegram,tray`
- Eso deja fuera por defecto `whatsapp`, `matrix`, `signal`, `slack`, `discord` y `homeassistant`
- Por tanto, varios claims de canales estaban describiendo capacidad potencial del repo, no capacidad shipped real

### 2. Reuniones estaban sobredeclaradas, luego avanzaron fuerte en repo

- El runtime detectaba reuniones y grababa `.wav`
- En la pasada anterior el flujo real terminaba en `TODO: trigger transcription + summarization`
- El repo actual ya cablea transcripcion, diarizacion, resumen, memoria, notificacion y compresion
- Aun falta revalidar en host real el flujo completo tras esos cambios

### 3. Game Guard no estaba cerrado

- El host mostro falsos positivos por `gamemoded`
- Tambien detectaba al propio `llama-server` como “juego” por VRAM
- El fix ya existe en repo, pero hasta desplegarlo no debemos volver a marcar el hito como completo

### 4. AB estaba muy inflada

- `/ws` existe
- Pero el `connect` real solo pide token; no `protocolVersion`, `role`, `scopes[]`, `capabilities[]`
- `SessionStore` ya quedo conectado al bridge de Telegram y persiste across restarts

### 5. AK, AL y AP tambien tenian huecos concretos

- `life doctor` y `life safe-mode` ya existen como comandos CLI
- El sentinel real consulta `/api/v1/health`, no `/alive`
- El API real expone un `health` agregado, no el trio `alive/ready/deep` como estaba documentado
- `task.progress`, `task.step_completed` y `worker.*` no aparecieron cableados como eventos WebSocket reales
- El worker pool si existe, pero la capa de sub-workers y steering consumido seguia sobreprometida
- La compaction en uso real sigue ocurriendo sobre todo en `telegram_tools.rs`, no en un session layer transversal ya adoptado por todos los canales

### 6. N-Q y S-Y tambien necesitaban bajar varios claims

- `battery/status`, `battery/threshold` y `battery/history` ya existen; `battery/history` es un snapshot honesto, no historico muestreado
- Fase O tenia buena base de operador autonomo, pero el loop de aprender skills a partir de interacciones reales no quedo cableado de forma demostrable
- MCP client/server existe con base solida, pero la historia de dashboard e “integraciones MCP” seguia inflada
- El dashboard si muestra salud del sistema, pero los reportes integrales diarios/semanales por Telegram no quedaron demostrados como estaban escritos
- `RealtimeTranslator`, `translate_file()` e `interpret_voice()` existen en `translation.rs`; ademas ahora hay `POST /api/v1/translate`, pero la experiencia de producto completa sigue parcial
- Knowledge graph y reliability tienen base real, pero export/import, checkpoint/resume general y audit trail explicable seguian por debajo de la narrativa

### 7. AG, AO y AA tambien necesitaban aterrizaje final

- AG ya tiene evidencia de `export_conversation`, pero sigue siendo una solucion parcial y localizada a Telegram
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
