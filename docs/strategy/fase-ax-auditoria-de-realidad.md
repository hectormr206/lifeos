# Fase AX — Auditoria de Realidad y Cierre de Claims

**Objetivo:** Dejar de tratarnos el roadmap como marketing interno. Cada checkbox marcado debe corresponder a un flujo realmente cableado, ejecutable, observable y sostenible en host real. Si una capacidad existe solo como modulo suelto, helper no invocado, TODO pendiente, o depende de pasos manuales no documentados, NO cuenta como completa.

**Problema que corrige:** Ya tenemos evidencia de claims optimistas. Ejemplo concreto: Fase R (reuniones) tenia checkboxes de transcripcion, diarizacion, resumen, Telegram y archivo en memoria, pero el flujo real en runtime se corta al terminar la reunion y deja solo `.wav` en `/var/lib/lifeos/meetings/`.

**Documento de seguimiento:** Ver [auditoria-estados-reales.md](auditoria-estados-reales.md) para la matriz viva de estados reales, diferencias repo vs imagen vs host, y huecos documentados.

## Regla nueva de verdad operativa

Un item solo puede estar en `[x]` si cumple TODAS estas condiciones:

- Existe implementacion en codigo integrada al flujo principal
- Hay al menos una ruta real de ejecucion (daemon loop, API, Telegram, CLI o background worker)
- El resultado deja evidencia observable (logs, archivos, DB, evento, respuesta API o UI)
- No depende de TODOs manuales para completar el flujo
- No esta roto en host real por permisos, procesos duplicados o wiring faltante

Si falla cualquiera de esas condiciones:

- [ ] descheckear el item
- [ ] documentar exactamente que parte ya existe
- [ ] documentar exactamente que falta para poder volver a marcarlo

## AX.1 — Auditoria por areas

- [ ] Re-auditar Fase R (reuniones) end-to-end con evidencia de host real
- [ ] Re-auditar claims de sensores/always-on que dependan de permisos, audio, camera o GPU
- [ ] Re-auditar claims de Telegram/Discord/Signal que prometan automatizacion completa
- [ ] Re-auditar claims de memoria/knowledge graph que prometan persistencia y consulta futura
- [ ] Re-auditar claims de self-healing que dependan de systemd, polkit, watchdog o rollback real
- [ ] Re-auditar claims de dashboard que prometan botones/acciones y no solo estado visual

## AX.2 — Evidencia minima por checkbox

- [ ] Cada fase completada debe enlazar al modulo principal que la implementa
- [ ] Cada hito completado debe tener al menos una evidencia observable documentada
- [ ] Cada claim sensible a host real debe indicar si fue validado solo en codigo o tambien en laptop real
- [ ] Cada claim de automatizacion debe indicar si requiere consentimiento, aprobacion o setup manual

## AX.3 — Cierre de brechas antes de re-checkear

- [ ] Ningun helper suelto cuenta como feature completa si no esta invocado por runtime
- [ ] Ningun evento emitido cuenta como UX completa si no existe consumidor visible o accion posterior
- [ ] Ningun flujo “detecta y guarda” cuenta como “resume y archiva” si no existe pipeline post-procesamiento
- [ ] Ninguna politica de limpieza cuenta como activa si solo existe la funcion pero no el scheduler o trigger
- [ ] Ningun servicio root/user dual cuenta como correcto si puede correr duplicado en host real

## AX.4 — Estado inicial confirmado por esta auditoria

- [x] Fase R necesita reabrirse
- [x] `lifeosd` podia correr duplicado (user + system) en host real
- [x] Game Guard tenia falsos positivos por GameMode y por detectar a `llama-server` como juego
- [x] El default de modelo estaba desalineado entre plantilla de sistema, config de usuario y runtime
- [x] Fix R: meeting pipeline wired end-to-end (transcribe → diarize → summarize → memory → notify)
- [x] Fix AF: Slack/Discord bridges spawned in main.rs with feature gates
- [x] Fix AB: SessionStore connected to Telegram bridge (persists across restarts)
- [x] Fix AP: Worker lifecycle events emitted to WebSocket event bus
- [x] Fix G: Game Guard false positive fixes verified with tests
- [x] Fix AK: life doctor + life safe-mode CLI commands implemented
- [ ] El roadmap ya refleja todas las demas discrepancias historicas

## AX.5 — Criterio para volver a marcar Fase R como completa

- [ ] Detectar reunion sin falsos positivos en host real
- [ ] Grabar el audio correcto de la reunion sin duplicados ni loops
- [ ] Ejecutar transcripcion automaticamente al terminar
- [ ] Ejecutar diarizacion automaticamente cuando aplique
- [ ] Generar resumen y action items automaticamente
- [ ] Definir politica real de retencion: que se guarda, por cuanto tiempo y en que formato
- [ ] Limpiar basura automaticamente sin borrar evidencia util
- [ ] Guardar solo lo necesario para memoria futura y consulta posterior
- [ ] Exponer evidencia observable del pipeline completo en logs/UI/API

## Nota operativa

Esta fase no agrega features “bonitas”. Agrega honestidad tecnica. Su objetivo es que el 100% vuelva a significar “funciona de verdad”, no “hay codigo parecido en algun modulo”.
