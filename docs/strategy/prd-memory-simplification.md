# PRD — Memory Simplification (Lexical-First)

**Status:** Draft · 2026-04-26
**Author:** Hector + Claude
**Inspiration:** [Gentleman's Engram](https://github.com/) (SQLite + FTS5 only)
**Predecessor:** Memory audit (Sprint 1-4 ya shipped)

---

## 1. Motivación

LifeOS tiene actualmente 4 capas de búsqueda de memoria:

| Capa | Estado | Costo |
|------|--------|-------|
| SQLite (relacional) | OK | bajo |
| sqlite-vec (embeddings 768-dim) | OK | alto (modelo 250MB + servicio embeddings + ~80ms/query) |
| AES-256-GCM-SIV (encripción por fila) | OK | medio (CPU por cada read/write) |
| FTS5 (lexical) | **roto** desde audit | bajo |

**Hallazgo del audit:** la capa lexical (FTS5) estaba rota mientras la vectorial "funcionaba". Eso indica que **la lexical no era crítica en el flujo real** — si lo fuera, lo habríamos detectado mucho antes.

**Hipótesis a validar:** el 80-90% de las queries reales que hace Axi (y Hector) se resuelven igual o mejor con FTS5 que con embeddings semánticos. Las embeddings agregan latencia, dependencia de servicio externo (`llama-embeddings.service`), y RAM/VRAM, sin beneficio proporcional.

**Costo del status quo:**
- 250MB modelo nomic-embed-text-v1.5 en disco
- ~80ms latencia por query (embed → vec search → re-rank)
- Servicio extra que puede fallar (`llama-embeddings.service`)
- Complejidad: 2 caminos de búsqueda en código → más superficie de bug

---

## 2. Decisión propuesta

**Hacer FTS5 la búsqueda PRIMARIA. Demover sqlite-vec a fallback opcional.**

### Arquitectura objetivo

```
┌─ Query entra ─┐
│               │
▼               ▼
FTS5 lexical    (timeout 5ms)
│
├─ Si retorna >= N resultados relevantes → DONE
│
└─ Si vacío o muy pocos
   │
   ├─ ¿Embeddings disponibles? (servicio up + modelo cargado)
   │  ├─ SÍ → vector search como fallback
   │  └─ NO → retornar resultados FTS5 aunque sean pocos
   │
   └─ Combinar y deduplicar
```

### Reglas

1. **FTS5 SIEMPRE corre primero.** Sin excepciones.
2. **Vector solo si:** (a) FTS5 retorna < 3 resultados Y (b) servicio embeddings está OK
3. **Vector es OPCIONAL** a nivel imagen: feature flag `embeddings`. Imagen base no lo incluye. Usuario opt-in.
4. **Reformulación de queries:** antes de ir a vector, el LLM puede reformular la query 2-3 veces y reintenter FTS5 (más barato que embed)

---

## 3. Plan de validación (NO implementar antes de medir)

### Sprint pre-implementación: **Telemetría de uso**

1. Logear toda query a `MemoryPlane::search` con:
   - query string original
   - origin (LLM tool / UI / API)
   - resultados FTS5 (count, top relevance)
   - resultados vector (count, top similarity)
   - cuál se usó finalmente
2. Correr 2 semanas en uso real
3. Análisis:
   - **% queries donde FTS5 solo bastó** (>= 1 resultado relevante)
   - **% queries donde vector aportó algo único** (resultado que FTS5 no encontró)
   - **% queries donde ninguno encontró nada**
4. **Decisión gate:**
   - FTS5 solo basta >= 85% → ir adelante con migración
   - 70-85% → mantener híbrido, FTS5 primero (versión "soft" del cambio)
   - < 70% → no migrar, vector justifica su costo

---

## 4. Implementación (después del gate)

### Fase 1: Arreglar FTS5 (sprint memoria pendiente)
- FTS5 virtual table sobre `memory_entries.content` y `memory_entries.title`
- Tokenizer: `unicode61 remove_diacritics 2`
- Triggers para mantener FTS5 sincronizado
- Tests: queries en español con acentos, números, fechas

### Fase 2: Reordenar prioridad
- `MemoryPlane::search()` → llama FTS5 primero
- Solo si necesario, llama vector
- Métrica nueva: `search_path` ("fts5_only" | "fts5_then_vector" | "vector_fallback")

### Fase 3: Demover sqlite-vec
- Feature flag `embeddings` en `daemon/Cargo.toml`
- `llama-embeddings.service` se vuelve opt-in (no arranca por default)
- Documentar en `docs/operations/memory.md` cómo activar para usuarios con GPU

### Fase 4: Limpieza
- Eliminar tools LLM que dependen exclusivamente de embeddings
- Migrar tools que usaban embeddings → versión que primero intenta FTS5

---

## 5. Lo que NO se cambia

- **Encripción AES-256-GCM-SIV** se mantiene — Hector lo quiere por privacidad
- **Knowledge graph (entities + relations)** se mantiene — es relacional puro, no compite con búsqueda
- **Sqlite-vec NO se elimina del código** — solo deja de ser default
- **Ningún dato existente se pierde** — embeddings ya generadas siguen consultables si user activa feature

---

## 6. Riesgos

| Riesgo | Mitigación |
|--------|------------|
| FTS5 español no maneja bien acentos | Tokenizer `unicode61 remove_diacritics 2` + tests específicos |
| LLM no reformula queries bien | Prompt template + ejemplos few-shot |
| Usuario nota peor recall | Telemetría detecta antes; vector queda como fallback automático |
| Romper tools existentes que llaman vector directo | Feature flag + tests de regresión |

---

## 7. Métricas de éxito

- **Latencia p50 query:** baja de ~80ms a < 5ms
- **RAM daemon:** baja ~300MB (modelo nomic) si usuario opta out
- **Servicios systemd activos:** -1 (`llama-embeddings.service` opt-in)
- **Líneas de código memoria:** -20-30% (eliminar branches embed-first)
- **Bugs en memoria:** menos superficie → menos bugs

---

## 8. Estimación

| Fase | Esfuerzo |
|------|----------|
| Telemetría (pre-gate) | 4-6h |
| 2 semanas observación | wall-clock, 0h trabajo |
| Análisis + decisión gate | 1-2h |
| Fase 1 (arreglar FTS5) | 6-8h |
| Fase 2 (reordenar prioridad) | 4-6h |
| Fase 3 (demover sqlite-vec) | 3-4h |
| Fase 4 (cleanup) | 2-3h |

**Total: 20-30h** + 2 semanas wall-clock para validación.

---

## 9. Decisiones pendientes

- [ ] ¿Telemetría tiene que ser opt-in del usuario? (sí — privacidad)
- [ ] ¿Métricas se guardan localmente o se exportan? (local-only por default)
- [ ] ¿Cuál es el threshold "resultado relevante" en FTS5? (rank score > X)
- [ ] ¿Mantenemos sqlite-vec para nuevas instalaciones o solo legacy? (decidir post-gate)

---

## 10. Próximos pasos

1. Aprobar este PRD (Hector ✅ — 2026-04-26)
2. **NO empezar hasta** que termine el deploy actual (Life Areas v1)
3. Crear change vía `/sdd-new memory-simplification` cuando esté listo
4. Sprint telemetría primero, **datos antes que opiniones**
