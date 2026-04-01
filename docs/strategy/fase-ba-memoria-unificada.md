# Fase BA — Memoria Unificada: Axi Accede a Todo

> **Estado:** CONSECUTIVA — no requiere investigacion, solo wiring
> **Prioridad:** Alta — sin esto Axi responde con informacion incompleta
> **Fecha:** 2026-04-01

---

## Problema

Axi tiene 20 fuentes de datos pero solo puede acceder a 7 desde Telegram.
Las otras 13 existen, generan datos, pero Axi no puede consultarlas.
Esto causa que Axi no pueda responder preguntas sobre:
- Actividad del usuario (apps, tiempo de trabajo, gaming)
- Calendario y recordatorios
- Seguridad y amenazas detectadas
- Estado del sistema (contexto, modo, configuracion)
- Reuniones pasadas
- Patrones aprendidos

## Arquitectura del fix

El gateway es `ToolContext` en `telegram_tools.rs`. Cada fuente desconectada necesita:
1. Agregar campo al struct `ToolContext`
2. Pasar la referencia al crear el contexto en `telegram_bridge.rs`
3. Crear un tool de Telegram que lo consulte
4. Agregar a la documentacion del system prompt

## Tareas por fuente

### BA.1 — Health Tracking (salud del usuario)
- [ ] Agregar `health_tracker` a ToolContext
- [ ] Tool `health_status`: tiempo activo, breaks tomados, sesion actual
- [ ] Tool `health_history`: historial de sesiones de los ultimos 7 dias

### BA.2 — Calendar (agenda)
- [ ] Agregar `calendar` a ToolContext
- [ ] Tool `calendar_today`: eventos de hoy
- [ ] Tool `calendar_week`: eventos de la semana
- [ ] Tool `calendar_add`: agregar evento
- [ ] Tool `calendar_remind`: crear recordatorio

### BA.3 — Context & Mode (estado actual)
- [ ] Agregar `context_policies` y `experience_modes` a ToolContext
- [ ] Tool `current_context`: en que contexto esta (work/personal/gaming/etc)
- [ ] Tool `current_mode`: que modo esta activo (Simple/Pro/Builder)
- [ ] Inyectar contexto y modo automaticamente en el system prompt

### BA.4 — Self-Improving (patrones aprendidos)
- [ ] Agregar `self_improving` a ToolContext
- [ ] Tool `learned_patterns`: que patrones ha detectado
- [ ] Tool `skill_suggestions`: que skills sugiere automatizar
- [ ] Tool `prompt_effectiveness`: metricas de efectividad

### BA.5 — Game Guard (gaming)
- [ ] Tool `gaming_status`: esta jugando? que juego? cuanto tiempo? GPU status
- [ ] Tool `gaming_history`: historial de sesiones de juego (desde memory_plane tags:gaming)

### BA.6 — Meeting Assistant (reuniones)
- [ ] Agregar `meeting_assistant` a ToolContext
- [ ] Tool `meeting_recall`: buscar transcripciones/resumenes de reuniones pasadas
- [ ] Tool `meeting_status`: hay reunion activa?

### BA.7 — Security (seguridad)
- [ ] Tool `security_status`: estado actual de seguridad
- [ ] Tool `security_history`: alertas recientes (desde memory_plane tags:security)
- [ ] Tool `security_scan`: ejecutar scan bajo demanda

### BA.8 — Follow Along (actividad)
- [ ] Tool `activity_summary`: resumen de apps usadas hoy (desde memory_plane tags:context)
- [ ] Tool `app_time`: tiempo en cada app (estimado desde window changes)

### BA.9 — Screen History (capturas)
- [ ] Tool `screenshot_history`: buscar capturas recientes por descripcion (desde memory_plane tags:visual)

### BA.10 — Config Store (configuracion)
- [ ] Tool `config_history`: cambios de configuracion recientes
- [ ] Tool `config_current`: configuracion activa

---

## Nota sobre sensory_memory

Los datos de los 5 sentidos ya se guardan en memory_plane con tags como
"sensory", "visual", "auditory", "context". Esto significa que muchos
de los tools anteriores (BA.5, BA.8, BA.9) se pueden implementar como
busquedas filtradas en memory_plane sin agregar campos nuevos a ToolContext:

```rust
mem.search_entries("gaming session", 5, Some("sensory")).await
mem.search_entries("screen capture firefox", 3, Some("visual")).await
```

Pero otros (BA.1, BA.2, BA.3, BA.4, BA.6) necesitan acceso directo al
subsistema porque la informacion no esta en memory_plane.

---

## Esfuerzo estimado

| Grupo | Items | Esfuerzo |
|-------|-------|----------|
| BA.1-BA.2 (health + calendar) | 6 tools | 1 dia |
| BA.3 (context + mode) | 3 tools + prompt injection | 0.5 dia |
| BA.4 (self-improving) | 3 tools | 0.5 dia |
| BA.5-BA.9 (busquedas en memory_plane) | 7 tools | 1 dia |
| BA.10 (config) | 2 tools | 0.5 dia |
| **Total** | **21 tools nuevos** | **~3.5 dias** |

Al completar, Axi tendra acceso a **todas** las fuentes de datos del sistema.
Total de Telegram tools: 65 actuales + 21 nuevos = **86 tools**.
