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

## AQ.1 — User Model Persistente (P0)

- [ ] `UserModel` struct: communication_style, schedule_patterns, app_usage, active_projects, goals, preferred_format, language, current_context
- [ ] Almacenar en memory_plane como `kind: "user_profile"` encriptado
- [ ] `build_user_model()` agrega datos de: memory_plane, knowledge_graph, follow_along, health_tracking
- [ ] Auto-update cada 30 min (background task)
- [ ] API: `GET /api/v1/user/profile`, `PATCH /api/v1/user/preferences`
- [ ] Tests unitarios

## AQ.2 — Adaptacion de Estilo de Comunicacion (P0)

- [ ] Analizar mensajes del usuario para detectar: formalidad, longitud, formato preferido, emoji, idioma
- [ ] `CommunicationProfile`: formality_level (1-5), verbosity (brief/normal/detailed), format (bullets/paragraphs/tables), emoji_usage, vocabulary_level
- [ ] Modificar system_prompt_builder() para inyectar instrucciones de estilo
- [ ] Feedback implicito: "resumeme eso" → reducir verbosity
- [ ] Feedback explicito: "se mas breve" → actualizar perfil inmediatamente

## AQ.3 — Prediccion Proactiva Basada en Habitos (P0)

- [ ] `HabitMap`: mapa (dia_semana, hora) → actividades frecuentes con confidence
- [ ] Detectar rutinas con minimo 3 ocurrencias
- [ ] Sugerencias: morning_briefing, break_reminder, task_nudge, end_of_day_summary
- [ ] Ranking: confidence × relevancia temporal × historial accept/reject
- [ ] Rate limiting: max N sugerencias/hora, nunca en focus mode

## AQ.4 — Modos de Contexto Automaticos (P1)

- [ ] Contextos: Work, Personal, Meeting, Gaming, Creative, Rest
- [ ] Detector basado en: app activa, hora, calendario, follow_along
- [ ] Cada contexto tiene: notification_policy, axi_personality, ui_theme_hint, proactive_level
- [ ] Transicion auto con confirmacion opcional
- [ ] API: `GET/PUT /api/v1/context/current`

## AQ.5 — Personalizacion de Desktop (P1)

- [ ] Night Shift automatico (temperatura de color por hora)
- [ ] Recordar layout de ventanas por contexto
- [ ] Smart app launch (pre-cargar apps frecuentes por contexto+hora)
- [ ] Focus mode: silenciar notificaciones no-criticas automaticamente
- [ ] Theme switching por contexto (dark/light)

## AQ.6 — Automatizacion de Workflows Aprendidos (P1)

- [ ] Detectar secuencias repetitivas en follow_along (3+ veces/semana)
- [ ] Ofrecer: "Noto que cada manana ejecutas git pull, cargo build, cargo test. Automatizo?"
- [ ] Si acepta → crear procedural_memory con trigger automatico
- [ ] Si rechaza → marcar como dismissed, no volver a sugerir
- [ ] Dashboard de workflows aprendidos

## AQ.7 — Inteligencia Emocional Basica (P2)

- [ ] Detector de frustracion: errores consecutivos, mensajes bruscos, retry patterns
- [ ] Respuesta empatica: "Ese comando fallo varias veces. Investigo?"
- [ ] Celebracion de logros: PR mergeado, build exitoso tras fallos
- [ ] Mood tracking pasivo (campo `mood` en memory_plane)
- [ ] Configurable: el usuario puede desactivar completamente

## AQ.8 — Memoria Conversacional Rica (P2)

- [ ] Buscar memorias relevantes por embeddings antes de cada respuesta
- [ ] Inyectar top-K memorias como contexto: "Como me comentaste la semana pasada..."
- [ ] Decay: recientes pesan mas, pero decisiones y compromisos no decaen
- [ ] "Olvidalo" elimina una memoria especifica
- [ ] Privacy: nunca referenciar memorias privadas en contextos compartidos

## AQ.9 — API de Personalizacion + Dashboard (P2)

- [ ] Endpoints: profile, habits, suggestions, feedback, preferences, delete-all
- [ ] Dashboard: "Asi te conoce Axi" — visualizar perfil, habitos, contextos, workflows
- [ ] Toggle por feature
- [ ] Export/import de perfil (portabilidad entre instalaciones)
- [ ] Derecho al olvido: un endpoint borra todo

## AQ.10 — Onboarding Personalizado (P2)

- [ ] En Welcome Wizard preguntar: idioma, nivel tecnico, estilo de comunicacion, tipo de ayuda
- [ ] Seed del UserModel con respuestas del wizard
- [ ] Primera semana: Axi observa mas, sugiere menos (modo "aprendizaje")
- [ ] Despues de 7 dias: primer resumen de lo aprendido

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
