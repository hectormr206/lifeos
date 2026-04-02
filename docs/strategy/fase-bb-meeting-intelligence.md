# Fase BB — Meeting Intelligence

> Sistema completo de captura, transcripcion, diarizacion y archivo de reuniones.
> Todo local, sin cloud, sin bot. Privacidad por defecto.

## Contexto

LifeOS ya tiene un Meeting Assistant funcional (meeting_assistant.rs) con:
- Deteccion automatica de reuniones (PipeWire + ventanas + camara)
- Grabacion de audio (pw-record, 16kHz mono WAV)
- Transcripcion post-reunion (whisper-cli)
- Diarizacion basica (energia, "Speaker 1/2")
- Resumen LLM con action items
- Compresion OPUS, dashboard, Telegram

Esta fase mejora cada componente para alcanzar calidad profesional.

## Referencia de mercado

| Producto | Modelo | Inspiracion |
|---|---|---|
| Granola.ai | Sin bot, audio del sistema | Nuestro modelo exacto |
| Otter.ai | Screenshots de slides en transcripciones | BB.2 |
| Teams Copilot | Auto-borra audio crudo post-proceso | BB.6 |
| WhisperX | whisper + pyannote + timestamps por palabra | BB.1 |
| Plaud Desktop | Captura audio sistema directo | Confirma PipeWire |

## Tareas

### BB.1 — Diarizacion con nombres (Speaker ID conectado)
- Conectar speaker_id.rs (WeSpeaker embeddings) con diarizacion
- Integrar pyannote-audio (community-1) como subprocess para diarizacion real
- Resultado: "Hector dijo X" en vez de "Speaker 1 dijo X"
- Archivos: meeting_assistant.rs, speaker_id.rs, lifeos-diarize.py

### BB.2 — Screenshots contextuales durante reuniones
- Captura con grim cada 30 segundos durante reunion activa
- Guardar con timestamp correlacionado al audio
- Util para slides, pantalla compartida, chat visible
- Archivo: meeting_assistant.rs

### BB.3 — Audio dual-canal (mic + sistema)
- Grabar microfono y audio del sistema como archivos separados
- PipeWire pw-link para routing de audio
- Beneficio: saber que dijo el usuario vs que dijeron los demas
- Archivo: meeting_assistant.rs

### BB.4 — Archivo estructurado de reuniones (SQLite)
- Base de datos con todas las reuniones indexadas
- Campos: fecha, participantes, duracion, app, resumen, action items, tags
- Busqueda por fecha, participante, tema
- Nuevo modulo: meeting_archive.rs

### BB.5 — Dashboard de reuniones
- Seccion en dashboard para ver reuniones pasadas
- Timeline con transcripcion + screenshots + action items
- Filtros por fecha, participante
- Archivo: dashboard/index.html, dashboard/app.js

### BB.6 — Privacidad: auto-borrado de audio crudo
- Despues de transcribir + diarizar + resumir, borrar WAV/OPUS
- Configurable: por defecto borra, opcion de mantener
- Solo queda texto (transcript + resumen + action items)
- Archivo: meeting_assistant.rs

### BB.7 — Reunion presencial (mic del laptop)
- Detectar reunion presencial cuando hay multiples voces sin app de video
- Modo manual: "Axi, estoy en una reunion" via Telegram
- Graba solo del microfono
- Archivo: meeting_assistant.rs

### BB.8 — Transcripcion en tiempo real (captions)
- whisper-cli en modo streaming con modelo tiny/base (bajo CPU)
- Mostrar subtitulos en notificacion o dashboard durante reunion
- Post-reunion: re-procesar con modelo grande para transcript final
- Opcional: mayor consumo de CPU
- Archivo: meeting_assistant.rs, sensory_pipeline.rs

## Dependencias externas

| Componente | Instalacion | Tamano |
|---|---|---|
| pyannote-audio | pip install + modelos HuggingFace | ~1.5 GB |
| WhisperX | pip install whisperx | ~500 MB (usa pyannote) |
| Whisper large-v3-turbo | ggml model download | ~1.5 GB |
| WeSpeaker ONNX | Ya en el Containerfile | ~50 MB |

## Precision esperada

| Escenario | Precision diarizacion |
|---|---|
| Headset/mic individual, 2-3 personas | 90-95% |
| Laptop mic, sala tranquila, 2-3 personas | 75-85% |
| Mic USB conferencia ($50), 4-5 personas | 85-90% |
| Ambiente ruidoso | 70-80% |

## Tareas pendientes (post v0.3.2)

### BB.13 — Fix CRITICO: Deteccion de reuniones en navegador (PRIORIDAD 1)

**Problema real detectado (2026-04-02):** El usuario tuvo una reunion en Google Meet
via ungoogled-chromium (Flatpak). Axi NO la detecto porque:
1. Audio: pactl reporta "Chromium", no "Google Meet"
2. Ventanas: COSMIC DE no tiene API de titulos accesible (zcosmic_toplevel pendiente)
3. Camara: la reunion fue sin camara

**Solucion:** Cruzar audio + titulo de ventana del navegador.

Implementar:
- Detectar audio activo de navegador (Chromium, Firefox, Brave, etc.) via pactl
- Si hay audio de navegador, obtener titulo de ventana activa:
  - COSMIC: zcosmic_toplevel_info_v1 (pendiente) o cosmic-comp D-Bus
  - Fallback: leer /proc/{pid}/cmdline para URLs, o xdotool/wlrctl
  - Flatpak: inspeccionar portal de ventanas
- Si titulo contiene "Meet", "Zoom", "Teams", "Slack", "Discord", "Jitsi", "WebEx" → reunion detectada
- Apps nativas (zoom, teams como proceso) → deteccion actual ya funciona

Navegadores a cubrir:
- Chromium / ungoogled-chromium (Flatpak y nativo)
- Firefox (Flatpak y nativo, perfil LifeOS)
- Brave, Edge, Chrome, Vivaldi

Plataformas de videollamada a detectar en titulo:
- Google Meet ("Google Meet" o "meet.google.com")
- Zoom ("Zoom Meeting" o "zoom.us")
- Microsoft Teams ("Microsoft Teams" o "teams.microsoft.com")
- Discord ("Discord" + canal de voz)
- Slack ("Slack" + "Huddle")
- Jitsi ("Jitsi Meet" o "meet.jit.si")
- WebEx ("Webex" o "webex.com")
- Whereby, Around, Gather, etc.

### BB.9 — Notificacion post-reunion con resumen completo
- Al terminar de procesar la reunion, Axi envia por Telegram:
  - Resumen ejecutivo (3-5 bullets)
  - Numero de participantes detectados
  - Duracion
  - Cantidad de action items
  - Cantidad de screenshots capturados
  - Mensaje: "La reunion completa esta disponible en el dashboard"
- NO enviar transcript completo por Telegram (demasiado largo)
- NO enviar link al dashboard (solo funciona en la laptop, no desde celular)

### BB.10 — Vista detallada de reunion en dashboard
- Al hacer clic en una reunion de la lista, abrir vista completa con:
  - **Header**: titulo, fecha, duracion, app (Meet/Zoom/etc), participantes
  - **Resumen ejecutivo**: generado por el LLM
  - **Action items**: lista con quien, que, cuando, checkbox de completado
  - **Transcript diarizado**: scroll completo con colores por speaker
    - Cada speaker con color diferente
    - Timestamps visibles
    - "[Hector] 09:15 — Necesitamos revisar el presupuesto"
    - "[Maria] 09:16 — De acuerdo, lo tengo listo para el viernes"
  - **Screenshots**: galeria de screenshots capturados con timestamp
    - Clic para ampliar
    - Util para ver slides o pantalla compartida
  - **Metadata**: hora inicio/fin, tipo (remota/presencial), audio conservado si/no
- Boton "Exportar" para descargar todo como:
  - Archivo markdown (.md) con transcript + resumen + action items
  - O archivo JSON con todos los datos estructurados
- Boton "Borrar reunion" con confirmacion

### BB.11 — Historial de reuniones en dashboard
- Lista de todas las reuniones ordenadas por fecha (mas reciente primero)
- Filtros: por semana/mes, por app (Meet/Zoom/presencial), por participante
- Busqueda en transcripts: "busca donde hablamos de presupuesto"
- Estadisticas: total de reuniones del mes, horas en reuniones, participante mas frecuente
- Paginacion (no cargar todas de golpe)

### BB.12 — Archivo exportable post-reunion
- Ademas de guardar en SQLite y MemoryPlane, generar un archivo markdown por reunion:
  - Ruta: `/var/lib/lifeos/meetings/YYYY-MM-DD-titulo/reunion.md`
  - Contenido: resumen + action items + transcript diarizado
  - Los screenshots quedan en la misma carpeta
- Esto permite que el usuario pueda abrir el archivo en cualquier editor
  sin depender del dashboard
- Estructura de carpeta por reunion (no archivos sueltos):
  ```
  /var/lib/lifeos/meetings/
    2026-04-02-junta-equipo/
      reunion.md          # Resumen + transcript completo
      action-items.json   # Action items estructurados
      screenshot-001.png  # Screenshots con timestamp
      screenshot-002.png
      metadata.json       # Duracion, participantes, app, etc.
  ```

## Privacidad

- Todo local, ningun audio sale de la maquina
- Sin bot que se une a la llamada (captura via PipeWire)
- Auto-borrado de audio crudo post-proceso (configurable)
- Consentimiento: Mexico permite grabacion con una parte (el usuario)
- Indicador visible cuando se esta grabando (notificacion)
