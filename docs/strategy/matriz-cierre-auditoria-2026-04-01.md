# Matriz de Cierre de Auditoria

**Fecha de corte:** `2026-04-01`  
**Base:** [auditoria-completa-lifeos-2026-04-01.md](auditoria-completa-lifeos-2026-04-01.md)

## Objetivo

Convertir la auditoria amplia en trabajo accionable.

Esta matriz no intenta volver a describir todo el repo.  
Su trabajo es responder:

- que conviene cerrar primero
- que debe validarse en host real
- que claims debemos bajar o subir con evidencia
- que areas ya no necesitan nueva amplitud, sino consolidacion

---

## Leyenda

- **P0**: bloquea narrativa publica, beta o confiabilidad basica
- **P1**: importante para producto real, pero no bloquea hoy
- **P2**: mejora estructural o de claridad
- **Repo**: existe en codigo / wiring
- **Imagen**: shipped en build default
- **Host**: validado en laptop o equipo real

---

## Matriz

| Prioridad | Area | Estado actual | Accion recomendada | Definition of done |
|-----------|------|---------------|--------------------|--------------------|
| P0 | Roadmap publico y narrativa | Ya existe roadmap publico, pero el repo principal aun no esta empujado | Empujar `lifeos` cuando quieras abrir ese roadmap publico en GitHub | Los links desde la landing dejan de dar `404` |
| P0 | Meetings | Pipeline fuerte en repo, aun sensible a validacion host | Validar deteccion, transcripcion, resumen, memoria y limpieza en reuniones reales cortas y largas | Evidencia host + politica de retencion documentada |
| P0 | Operator loop / computer use | Base fuerte en repo, cierre host desigual | Ejecutar smoke tests reales de overlay, screenshot, automation y accessibility sobre desktop real | Checklist host verde + claims publicos ajustados |
| P0 | Game Guard / GPU policy | Fixes en repo ya existen, pero la historia depende del deploy host | Mantenerlo auditado despues de cada update del daemon | No mas falsos positivos sobre `gamemoded` o `llama-server` |
| P1 | MCP / dashboard / WS | API amplia y base MCP real, pero historia end-to-end aun parcial | Alinear dashboard, WS y MCP a eventos y contratos consumidos de verdad | Flujo observable desde API hasta dashboard sin claims inflados |
| P1 | CLI doctor / health / self-healing | CLI real pero `--repair` aun no esta implementado | Decidir si se implementa o se baja su promesa | `life doctor --repair` hace algo real o se documenta como no soportado |
| P1 | Canales secundarios | Slack/Discord/Signal/Matrix/etc. existen, pero no todos shippean default | Etiquetar por canal: repo / imagen / host | Ningun doc vuelve a tratarlos como listos si no lo estan |
| P1 | Security AI / sentinel / watchdog | Capas reales en repo + imagen | Probar fallas controladas y ver como responde sentinel/safe-mode/restart | Evidencia de recuperacion real y runbook corto |
| P1 | Follow-along y reporting | Wiring fuerte en repo | Validar si los outputs son utiles y no solo tecnicamente funcionales | Flujo host real + UX aceptable |
| P2 | CLI taxonomy | CLI muy grande y mezcla wrappers API con comandos de sistema | Clasificar comandos por tipo y madurez | Tabla interna de `wrapper / local / mixed / experimental` |
| P2 | Imagen / servicios | Base fuerte, pero la historia operativa es compleja | Auditar ownership final de servicios y defaults habilitados | Mapa claro de servicios user/system y por que existen |
| P2 | Documentacion operativa | Muy fuerte pero voluminosa | Seguir migrando claims a lenguaje `Repo / Imagen / Host` | Documentacion mas consistente y menos ambigua |
| P2 | Tests / coverage narrada | Hay muchisimos tests markers, pero la historia publica puede exagerar su cobertura real | Documentar mejor que cubren y que no cubren los tests | Se evita usar el numero bruto de tests como proxy de cierre |

---

## Secuencia sugerida

### 1. Cierre de realidad del producto

- meetings
- operator loop
- Game Guard
- roadmap publico vivo

### 2. Cierre de observabilidad y control

- MCP / dashboard / WS
- doctor / health / self-healing
- security AI / sentinel

### 3. Limpieza de narrativa y taxonomia

- canales secundarios
- CLI taxonomy
- docs operativas
- relato de tests

---

## Regla operativa sugerida

Cada vez que una feature suba de nivel, documentarla con este formato:

- **Repo:** si o no
- **Imagen:** si o no
- **Host:** fecha de ultima validacion real

Si no se puede llenar eso, la feature no deberia llamarse "cerrada".

---

## Actualizacion post-sesion (2026-04-01 noche)

### Items cerrados o avanzados de la matriz original

| Item original | Prioridad | Estado anterior | Estado actualizado |
|---|---|---|---|
| Meetings | P0 | Pipeline fuerte en repo, sensible a host | **Cerrado en repo**: diarizacion con nombres, screenshots, dual-channel, archive SQLite, dashboard, auto-delete, manual trigger, captions |
| Game Guard / GPU policy | P0 | Fixes en repo, pendiente deploy | **Cerrado**: reset-failed, validado en host |
| MCP / dashboard / WS | P1 | API amplia, e2e parcial | **Avanzado**: +3 secciones dashboard (reuniones, calendario, agenda). Meetings + Calendar ahora observables |
| CLI doctor / health | P1 | --repair no implementado | **Sin cambio** — sigue pendiente |
| Canales secundarios | P1 | Mixto / feature-gated | **Sin cambio** — solo Telegram es shipped |
| Security AI / sentinel | P1 | Capas reales | **Avanzado**: service_manage tool, sudoers para firewall |
| Follow-along y reporting | P1 | Wiring fuerte | **Avanzado**: proactive alerts corregidos (thermal, idle, composefs), alertas de calendario |

### Nuevos items agregados a la matriz

| Prioridad | Area | Estado | Accion |
|---|---|---|---|
| P0 | Calendario (BD) | Fuerte en repo: recurrentes, reminders, dashboard | Validar en host con reuniones/citas reales |
| P1 | App Factory (BC) | Research completo, marco legal documentado | Decidir timeline de implementacion |
| P1 | Storage housekeeping | Corregido: camera/audio/tts ahora gestionados | Validar que housekeeping corre correctamente en host |
| P2 | Telegram reactions | Implementado + feedback a MemoryPlane | Validar en uso real |
| P2 | Voz unificada | TTS Telegram = TTS local (misma resolucion) | Validar calidad en host |
