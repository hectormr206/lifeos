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

## Privacidad

- Todo local, ningun audio sale de la maquina
- Sin bot que se une a la llamada (captura via PipeWire)
- Auto-borrado de audio crudo post-proceso (configurable)
- Consentimiento: Mexico permite grabacion con una parte (el usuario)
- Indicador visible cuando se esta grabando (notificacion)
