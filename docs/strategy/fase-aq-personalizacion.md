# Fase AQ — Experiencias Personalizadas: Axi se Adapta a Ti

> Este archivo es parte de la Estrategia Unificada de LifeOS. Ver [docs/strategy/](.) para el indice.

**Objetivo:** Que LifeOS y Axi se sientan diferentes para cada usuario. Axi aprende preferencias, habitos, horario, estilo de comunicacion, y adapta todo — desde como responde, hasta que sugiere proactivamente, hasta como se ve el escritorio.

**Investigacion (2026-03-31):** Analisis de Apple Intelligence (Personal Context), Google Gemini (Personal Intelligence, Gems, Memory), OpenClaw (SOUL.md), investigacion academica (User Profiling con LLMs, Proactive AI, Tone Adaptation, Adaptive UI).

**Diferenciador unico:** Apple, Google y OpenClaw personalizan DENTRO de su sandbox (apps propias, servicios web, terminal). LifeOS personaliza el **sistema operativo completo**. Axi ve todo lo que el usuario hace — con consentimiento — y adapta no solo sus respuestas, sino todo el entorno.

---

## Fundaciones existentes en LifeOS

| Subsistema | Que aporta |
|---|---|
| Memory Plane | Memoria encriptada + embeddings + knowledge graph + procedural memory + mood |
| Knowledge Graph | Entidades tipadas + relaciones con relevance decay |
| Sensory Pipeline | Vision, voz, awareness ambiental |
| Follow Along | Patrones de teclado/mouse, app activa, ventana |
| Health Tracking | Sesiones, breaks, postura, hidratacion |
| Experience Modes | Simple/Pro/Builder con configs distintas |
| Proactive Alerts | Disco, memoria, sesion larga, thermal, bateria |
| Time Context (AM) | Fecha/hora/timezone en todos los prompts |

---

## AQ.1 — User Model Persistente (P0) ✅ IMPLEMENTADO

- [x] `UserModel` struct en `user_model.rs`: `CommunicationProfile`, `SchedulePattern`, `active_projects`, `declared_goals`, `current_context`, `language`
- [x] Almacenar en disco como JSON en `data_dir/user_model.json` — `load_from_dir()` / `save()`
- [x] `prompt_instructions()` genera instrucciones personalizadas para el system prompt
- [ ] Auto-update cada 30 min (background task) — pendiente wiring a supervisor loop
- [x] API: endpoints de experience mode en `/api/v1/mode/*`
- [x] Tests unitarios — 9 tests en `user_model.rs`

## AQ.2 — Adaptacion de Estilo de Comunicacion (P0) ✅ IMPLEMENTADO

- [x] `CommunicationProfile`: formality_level (1-5), verbosity (brief/normal/detailed), preferred_format (bullets/paragraphs/tables/mixed), emoji_usage (none/light/heavy), vocabulary_level (simple/technical/expert)
- [x] `prompt_instructions()` inyecta estilo personalizado en TODOS los system prompts
- [x] `detect_preference_feedback()` — feedback implicito: detecta patrones como "se mas breve", "dame mas detalles", "en formato tabla"
- [x] `apply_preference()` — actualiza campos dinámicamente
- [x] Tests para deteccion de brief, detailed, format, formality

## AQ.3 — Prediccion Proactiva Basada en Habitos (P0) ✅ PARCIAL

- [x] `SchedulePattern` struct: day_of_week, hour_range, typical_activity, confidence
- [x] `WorkflowLearner` en `self_improving.rs`: `record_action()`, `detect_patterns()` (min 3 ocurrencias)
- [x] `suggest_skills()` convierte patrones en sugerencias
- [ ] Sugerencias proactivas (morning_briefing, break_reminder, task_nudge) — pendiente
- [ ] Rate limiting de sugerencias — pendiente

## AQ.4 — Modos de Contexto Automaticos (P1) ✅ IMPLEMENTADO

- [x] `ContextType` enum en `context_policies.rs`: Home, Work, Gaming, Creative, Development, Social, Learning, Travel, Custom
- [x] `detect_context()` — deteccion automatica por app activa, hora, red
- [x] Cada contexto tiene rules: `DisableNotifications`, `SetExperienceMode`, `SetAiModel`, `ScreenCapture`, `SetPrivacyLevel`
- [x] `apply_rules()` ejecuta transicion automatica
- [x] API: `GET/POST /api/v1/context/current`, `/api/v1/context/profiles`, `/api/v1/context/detect`, `/api/v1/context/rules/*`, `/api/v1/context/stats`

## AQ.5 — Personalizacion de Desktop (P1) ✅ IMPLEMENTADO

- [x] `ExperienceManager` en `experience_modes.rs`: Simple (4KB ctx), Pro (8KB), Builder (16KB)
- [x] `apply_mode()` aplica UI + AI + updates settings
- [x] `apply_overlay_settings()`, `apply_ai_settings()`, `apply_update_settings()`
- [ ] Night Shift automatico (wlsunset esta instalado, falta wiring por hora) — pendiente
- [x] Theme switching por contexto (dark/light via mode)

## AQ.6 — Automatizacion de Workflows Aprendidos (P1) ✅ IMPLEMENTADO

- [x] `WorkflowLearner.detect_patterns()` — detecta secuencias con 3+ pasos repetidas 3+ veces
- [x] `suggest_skills()` — convierte patrones en skill suggestions
- [x] `procedural_memory` en memory_plane — `save_procedure()`, `search_procedures()`, `mark_procedure_used()`
- [ ] Auto-trigger de procedimientos aprendidos — pendiente
- [ ] Dashboard de workflows aprendidos — pendiente

## AQ.7 — Inteligencia Emocional Basica (P2) ✅ PARCIAL

- [ ] Detector de frustracion (errores consecutivos, retry patterns) — pendiente
- [ ] Respuesta empatica contextual — pendiente
- [ ] Celebracion de logros — pendiente
- [x] Mood tracking pasivo — campo `mood TEXT` en memory_plane schema, `set_mood()`, `mood_history()`
- [x] Configurable via privacy/consent settings

## AQ.8 — Memoria Conversacional Rica (P2) ✅ PARCIAL

- [x] Busqueda semantica por embeddings en memory_plane (`search()` con sqlite-vec)
- [x] Knowledge graph con entities + relations + relevance_score + confidence
- [x] Decay: `last_accessed` tracking, relevance scoring
- [ ] Inyectar top-K memorias automaticamente en cada respuesta — pendiente
- [x] Privacy: encryption con AES-GCM-SIV + machine-specific key

## AQ.9 — API de Personalizacion + Dashboard (P2) ✅ PARCIAL

- [x] Endpoints: mode (6 endpoints), context (10 endpoints), followalong
- [ ] Dashboard visual "Asi te conoce Axi" — pendiente frontend
- [x] Toggle por feature (experience modes)
- [ ] Export/import de perfil — pendiente
- [ ] Derecho al olvido (endpoint delete-all) — pendiente

## AQ.10 — Onboarding Personalizado (P2) ✅ IMPLEMENTADO

- [x] `first_boot.rs`: Welcome Wizard interactivo + GUI (zenity) con idioma, hostname, timezone, tema
- [x] `ThemeChoice` (Simple/Pro) seeds UserModel
- [x] `ai_enabled`, `ai_model` en FirstBootState
- [ ] Primera semana modo "aprendizaje" — pendiente
- [ ] Resumen de lo aprendido despues de 7 dias — pendiente

---

## Principios de Diseno

1. **Privacidad por defecto** — todo local, encriptado, nunca sale del dispositivo
2. **Consentimiento granular** — cada feature se activa/desactiva independientemente
3. **Adaptacion sutil, no invasiva** — Axi nunca dice "detecto que estas frustrado", simplemente ajusta su tono
4. **Feedback loop cerrado** — accept/dismiss en cada sugerencia, mejora con el uso
5. **Derecho al olvido** — un endpoint borra todo, reset completo
6. **Incremental** — cada AQ.N es un PR independiente con valor propio

---

## Prioridades

```
P0 (sin esto no hay personalizacion):
  AQ.1 User Model → AQ.2 Comunicacion → AQ.3 Prediccion

P1 (diferenciadores):
  AQ.4 Contextos → AQ.5 Desktop
  AQ.6 Workflows

P2 (mejora la experiencia):
  AQ.7 Emocional, AQ.8 Memoria, AQ.9 API/Dashboard, AQ.10 Onboarding
```
