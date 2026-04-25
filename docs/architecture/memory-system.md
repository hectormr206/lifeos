# Sistema de Memoria de Axi — Arquitectura Completa

> Como el cerebro humano: memoria de corto plazo, largo plazo, procedural, relacional, y emocional.
> Axi NUNCA debe olvidar algo que el usuario le dijo, que ella misma envio, o que sucedio en el sistema.

---

## Las 5 capas de memoria

| Capa | Archivo | Retencion | Que guarda |
|------|---------|-----------|------------|
| **1. Historial in-memory** | `axi_tools.rs` (ConversationHistory) | 48h, ultimos 15 mensajes | Conversacion activa en RAM. Compactacion automatica a resumen despues de 20 mensajes |
| **2. SessionStore (JSONL)** | `session_store.rs` | 72h en disco, 24h al reiniciar (50 turnos) | Transcript completo por chat. Incluye mensajes automaticos (cron, notificaciones). Sobrevive reinicios del daemon. **No cifrado** — texto plano en JSONL; datos sensibles deben guardarse en el Memory Plane cifrado |
| **3. Memory Plane (SQLite)** | `memory_plane.rs` | **Permanente** (encriptado AES-GCM-SIV) | Decisiones, eventos, preferencias, resúmenes de conversaciones. Busqueda semantica por embeddings (768 dims) |
| **4. Knowledge Graph** | `knowledge_graph.rs` + tabla en memory.db | **Permanente** | Relaciones: "Hector trabaja en LifeOS", "suegro tiene dialisis los martes", "prefiere formato bullet" |
| **5. Procedural Memory** | Tabla `procedural_memory` en memory.db | **Permanente** | Workflows: "para deploy: cargo build → podman push → bootc update". Trigger patterns, veces usado |

---

## Flujo: como Axi recuerda

### Cuando el usuario escribe un mensaje

```
1. build_system_prompt()
   └── time_context() — hora/fecha actual (FRESCA, nunca cacheada)
   └── user_model.prompt_instructions() — preferencias de comunicacion
   └── emotional_prompt_hint() — estado emocional detectado

2. Cargar historial
   └── In-memory history (ultimos 15 turnos)
   └── Si vacio → SessionStore (ultimos 50 turnos de las ultimas 24h)
   └── Si hay compaction_summary → inyectar resumen

3. Memory recall automatico (si aplica)
   └── needs_memory_recall() detecta keywords: "recuerdas", "ayer", "que comimos", etc.
   └── search_entries(query, 3) — busqueda semantica en memory_plane
   └── Inyecta contenido descifrado como contexto del sistema (snippets de 300 chars)

4. Enviar a LLM
   └── system prompt + historial + memoria + mensaje del usuario

5. Persistir respuesta
   └── In-memory history: push user + assistant turns
   └── SessionStore: append_turn() para ambos
   └── Tools de memoria: si Axi decide guardar algo → memory_plane.store()
```

### Cuando Axi envia un mensaje automatico (cron, notificacion)

```
1. Cron job se ejecuta o notificacion se genera
2. Mensaje se envia al canal activo (SimpleX o dashboard)
3. Mensaje se graba en SessionStore como TranscriptTurn (role: "assistant")
   └── Prefijo: "[Cron: nombre]" o "[Notificacion automatica]"
4. Cuando el usuario responde, el historial incluye el mensaje automatico
   └── Axi sabe que envio y puede contextualizar la respuesta
```

### Cuando el usuario pregunta sobre el pasado

```
Usuario: "que comimos ayer?"

1. needs_memory_recall() detecta "que comimos" → TRUE
2. search_entries("que comimos ayer", 3) busca en memory_plane
3. Resultados descifrados se inyectan como contexto:
   "- [conversation] (2026-03-31 14:30): Hector dijo que comieron huevos con tocino..."
4. LLM responde con datos reales de memoria, no inventa
```

---

## Garantias de consistencia

| Escenario | Que pasa | Como se resuelve |
|-----------|----------|-----------------|
| Daemon reinicia | In-memory se pierde | SessionStore carga ultimos 50 turnos (24h) |
| Laptop apagada y encendida | In-memory se pierde | SessionStore carga desde disco JSONL |
| Axi manda cron y usuario responde 2h despues | Mensaje cron esta en SessionStore | Historial incluye el cron, Axi tiene contexto |
| Usuario pregunta algo de hace 1 semana | SessionStore no lo tiene (>72h) | Memory Plane busca por embeddings (permanente) |
| Usuario pregunta algo de hace 1 mes | Ni SessionStore ni historial | Memory Plane + Knowledge Graph (permanente) |
| Usuario dice "olvidalo" | Axi debe borrar | memory_plane.delete() + knowledge_graph remove |

---

## Keywords que activan memory recall

Cuando el usuario dice alguna de estas palabras, Axi automaticamente busca en su memoria antes de responder:

```
recuerdas, remember, acuerdas, dijiste, hablamos, mencionaste,
prometiste, acordamos, la vez que, yesterday, ayer,
la semana pasada, last week, antes, cuando fue, que comimos,
que hicimos, que paso, que decidimos, que me dijiste, que te dije,
la ultima vez, hace cuanto, el otro dia, que guardaste,
que sabes de, que recuerdas
```

---

## Herramientas de memoria disponibles via SimpleX y dashboard

| # | Tool | Que hace |
|---|------|---------|
| 8 | `remember` | Guarda algo en memoria permanente |
| 10 | `recall` | Busca en memoria por query (devuelve contenido real, no IDs) |
| 11 | `graph_add` | Agrega relacion al knowledge graph |
| 12 | `graph_query` | Consulta relaciones |
| 13 | `procedure_save` | Guarda un workflow |
| 14 | `procedure_find` | Busca workflows por nombre/trigger |
| 35 | `search_memories_by_date` | Busca memorias por rango de fechas |
| 34 | `current_time` | Hora actual del sistema (siempre correcta) |

---

## Encriptacion

- **Algoritmo:** AES-256-GCM-SIV (authenticated encryption)
- **Clave:** Derivada de `/etc/machine-id` (unica por instalacion)
- **Fallback:** Si machine-id no existe, genera clave aleatoria en `/var/lib/lifeos/memory.key`
- **Datos nunca salen del dispositivo** — toda busqueda y descifrado es local

---

## Archivos en disco

```
/var/lib/lifeos/
├── memory.db                    # SQLite: memory_entries, knowledge_graph, procedural_memory
├── sessions/
│   └── simplex_dm_&lt;contact_id&gt;/
│       ├── metadata.json        # Session metadata, compaction summary
│       └── transcript.jsonl     # Linea por turno (user/assistant/tool)
└── memory.key                   # Clave de encriptacion (fallback)
```

## Sprint 1 — Stop Axi from forgetting (2026-04-25)

Sprint 1 del plan de remediacion del audit cierra los caminos por
los que Axi olvidaba en silencio:

- **ConversationHistory 48h TTL → memory_plane.** Antes del drop de
  un chat caducado, `drain_stale_and_persist` resume con LLM y
  persiste la sintesis a `memory_entries`. Si el persist falla, el
  chat queda en RAM para reintentar en el proximo turno (no se pierde).
- **SessionStore 72h TTL → memory_plane.** `compact_session` y
  `prune_stale_sessions` (ahora agendado cada 6h en main.rs) escriben
  el resumen a `memory_entries` antes de borrar la sesion del disco.
- **Lexical search funcional.** El modo lexical antes hacia
  `LIKE '%query%'` contra contenido AES-encrypted+base64 (correctness
  bug, devolvia ~0 resultados). Ahora filtra por scope/tag/archived
  en SQL, descifra hasta 1000 candidatos y matchea plaintext.
- **5 herramientas nuevas para el LLM** que cubren el ciclo CRUD
  completo: `memory_delete`, `memory_update`, `memory_relate`,
  `memory_unarchive`, `knowledge_delete`. Axi puede editar, borrar
  y restaurar memorias desde chat.
- **Soft-delete por defecto + hard-delete con cleanup de huerfanos.**
  `delete_entry` ahora marca `archived = 1` (recuperable via
  `memory_unarchive`). `hard_delete_entry` (usado solo por
  `right_to_be_forgotten` y por `memory_delete` con `hard=true`)
  envuelve en una transaccion el borrado de `memory_entries`,
  `memory_embeddings`, triples del `knowledge_graph` cuyo
  `source_entry_id` apunta a la entrada, y `memory_links` en ambos
  sentidos.

**Defensa contra prompt injection** sobre las nuevas tools
destructivas: requieren `confirm: true` por defecto (gate-able via
`LIFEOS_AXI_REQUIRE_CONFIRM_DESTRUCTIVE`), rate-limit de 10 ops/hora,
y audit log append-only en
`~/.local/share/lifeos/destructive_actions.log` (mode 0600).
