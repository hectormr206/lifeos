# Fase BI — Bienestar Integral & Coach Personal ("Vida Plena")

> **Estado actual (auditado contra implementación):** Vida Plena está
> **funcionalmente cerrado en backend**. Las sub-fases BI.1–BI.14 ya
> tienen soporte en storage, lógica, tools de Telegram y/o HTTP API en
> el repo.
>
> **Importante:** este documento sigue siendo útil como estrategia,
> pero varias casillas históricas quedaron desfasadas respecto del
> estado real del código.
>
> **No bloquea el cierre del pillar:** dashboard frontend wiring,
> importadores/scripts externos y pillars posteriores del roadmap.
> **Investigación detallada:** [`docs/research/wellness-pillar/README.md`](../research/wellness-pillar/README.md)
> **Heredando de:** El canal "Vida Plena - Héctor" en Telegram que el
> usuario llevaba con OpenClaw, donde registraba enfermedades, ejercicios,
> y reflexiones diarias. Esta fase es la versión local-first, cifrada y
> mucho más amplia de esa idea.
> **Fecha de auditoría:** 2026-04-07
>
> **Leyenda rápida:**
> - `[x]` = entregado y auditado en repo
> - `[ ]` = refinement futuro, integración adicional o idea de producto
> - un pendiente local NO reabre el pillar salvo que se marque como bloqueante

## Premisa en una línea

Axi se convierte en el **coach personal del usuario para todas las
dimensiones de Vida Plena** — física, mental, emocional, espiritual,
relacional, financiera, sexual, social — siempre local-first, siempre
privado, siempre con consentimiento, nunca sustituyendo a profesionales
reales.

## Las 8 dimensiones de Vida Plena

LifeOS adopta un modelo holístico de bienestar inspirado en los marcos
clásicos de salud integral (OMS, SAMHSA Wellness Wheel) pero adaptado
a una sola persona, local-first, sin ataduras institucionales. Las 8
dimensiones que cubre Fase BI:

| # | Dimensión | Qué cubre |
|---|---|---|
| 1 | **Física** | Salud médica, medicamentos, vitales, análisis, alergias, condiciones, sueño, ejercicio, nutrición |
| 2 | **Mental** | Pensamientos, emociones, estado de ánimo, ansiedad, depresión, journal, autoconocimiento, terapia personal |
| 3 | **Emocional** | Cómo te sientes hoy, qué te alegra, qué te frustra, gratitud, regulación emocional |
| 4 | **Espiritual** | Sentido de vida, propósito, conexión con algo más grande (con o sin religión), prácticas contemplativas, valores |
| 5 | **Relacional** | Pareja, familia, hijos, amigos — calidad y cuidado de los vínculos importantes |
| 6 | **Sexual** | Salud sexual, intimidad, ciclo menstrual, fertilidad, anticoncepción — categoría sensible con cifrado reforzado |
| 7 | **Financiera** | Ingresos, gastos, deudas, ahorro, metas financieras, estrés económico — porque la salud financiera afecta TODAS las demás |
| 8 | **Social/Comunitaria** | Relaciones de comunidad, voluntariado, contribución, sentido de pertenencia más allá del círculo íntimo |

Las dimensiones **no son silos** — la fortaleza de LifeOS es que están
en la misma memoria unificada y Axi puede correlacionarlas. "Tu estado
de ánimo bajó la semana que tuviste discusiones con tu pareja Y te
saltaste 3 sesiones de ejercicio Y dormiste 5h promedio. ¿Notas el
patrón?".

## Por qué esto cambia el juego para LifeOS

Hasta ahora LifeOS es un asistente productivo: maneja tareas, calendario,
reuniones, código, sistema operativo. Esta fase lo convierte en un
**compañero de vida**: la persona que mejor te conoce porque lleva un
registro completo de lo que comes, cómo te sientes, qué te duele, qué te
hace feliz, qué leíste, cuánto ejercicio hiciste, cuándo dormiste mal y
por qué.

Y a diferencia de Apple Health, MyFitnessPal, Strava, Headspace, Flo o
cualquier app comercial: **todo vive cifrado en tu propia máquina**.
Nunca llega a un servidor. Nunca se vende a una aseguradora. Nunca se
indexa para anuncios. Si te roban la laptop, los datos siguen cifrados.
Si LifeOS desaparece mañana, tus datos siguen siendo tuyos en tu disco.

## Los casos de uso reales del usuario

Estos no son hipotéticos — son los ejemplos exactos que motivaron esta
fase, traducidos a capacidades técnicas:

| Caso real del usuario | Capacidad técnica |
|---|---|
| "Me dio gripa, le doy mis síntomas, le paso foto de la receta, le voy contando cómo me siento, hasta que me recupero" | `health_facts` + `health_medications` (history table) + `health_vitals` + `health_lab_results` + `health_attachments` (storage cifrado). **Recordatorios de medicamento/calendario: pendiente de integración explícita en BI** |
| "Tengo diabetes/hipertensión, las dosis cambian con el tiempo, hago ejercicio y eventualmente me las quitan" | `health_medications` como history table (cada cambio = row nuevo) + `health_vitals` timeseries |
| "Le mando foto/voz/texto de lo que comí" | `nutrition_log` con vision pipeline para fotos + STT para voz |
| "Quiero que me proponga recetas con lo que conoce de mí, ligadas a productos que sí venda mi tienda local" | `nutrition_recipes` + integración con `local_commerce` (catálogo de productos disponibles en zona) |
| "Le cuento cosas muy personales — mi infancia, cómo me siento hoy, traumas, cosas que jamás le diría a un humano" | `mental_health_journal` con cifrado reforzado + auth secundaria + crisis hotlines automáticas |
| "Quiero un plan de ejercicios desde casa, con lo que tengo a la mano" | `exercise_plans` + `exercise_log` |
| "Soy mujer, quiero llevar mi ciclo menstrual, síntomas, predicciones" | `menstrual_cycle` (opt-in, encriptación reforzada por contexto post-Roe) |
| "Quiero historial clínico que sobreviva al cambio de doctor" | `health_summary` exportable a Markdown/PDF estructurado |
| "Quiero leer más, crecer profesionalmente" | `reading_log` + `growth_goals` + reminders proactivos |
| "Soy alérgico a X — NUNCA lo olvides" | `health_facts` con `permanent=1` automático + auto-inyección en system prompt cuando hablas de comida o medicinas |

## Mapa rápido de estado

| Bucket | Estado |
|---|---|
| **Entregado en repo** | BI.1, BI.2, BI.3 (core + BI.3.1), BI.4, BI.5, BI.6, BI.7, BI.8, BI.9, BI.10, BI.11, BI.12, BI.13, BI.14 |
| **Follow-up no bloqueante** | refinements de UX y surfaces consumidores del API |
| **Fuera del pillar** | dashboard frontend wiring, scripts/importers externos, pillars posteriores |

## Estado actual real del pillar

A la fecha de esta auditoría, Vida Plena ya cuenta con:

- soporte de datos para BI.1–BI.14 en `daemon/src/memory_plane.rs`
- surface principal de escritura/corrección en `daemon/src/telegram_tools.rs`
- HTTP API dedicada en `daemon/src/api/vida_plena.rs` (principalmente lectura + algunos writes puntuales)
- coaching unificado (`life_summary`, `cross_domain_patterns`,
  `forgetting_check`, `medical_visit_prep`)
- vault, PIN local y wipes para áreas sensibles (mental, menstrual, sexual/consent)
- generador semanal de listas de compras
- predictor menstrual
- streaks, `habits_due_today` y `stale_relationships`

En consecuencia, Vida Plena debe leerse como **pillar cerrado a nivel
backend/capability**, no como una fase todavía vacía o en foundation.

## Sub-fases (consecutivas, incrementales)

Cada sub-fase es independiente y entregable. Se pueden ordenar pero la
dependencia técnica más fuerte es BI.1 → todo lo demás (sin BI.1 no se
garantiza que los datos sobrevivan).

### BI.1 — Nunca perder nada (la base universal)

Pre-requisito de todo el resto. Ya lo discutimos con el usuario en el
turno anterior.

- [x] `apply_decay` cambia GC delete → GC archive (afecta TODO, no solo
  bienestar). Las entradas que hoy se borrarían a `<10@90d` o `<30@180d`
  ahora se mueven a `memory_archive` en vez de eliminarse.
- [x] Nuevo tool `recall_archived(query)` para que el LLM acceda a la
  tabla archivo cuando el usuario diga "tenía una idea pero ya no
  recuerdo qué era".
- [x] Auto-mark `kind LIKE "health_%" OR kind LIKE "wellness_%"` como
  `permanent=1` en `add_entry`.
- [x] Skip `kind LIKE "health_%"` en `dedup_similar` (los eventos
  médicos jamás se fusionan, incluso si el texto es casi idéntico —
  porque dos dosis del mismo medicamento son eventos distintos).
- [x] Tests + version bump.

### BI.2 — Salud médica estructurada

Side-tables en `memory.db` (mismo archivo, mismo cifrado, mismo backup).
Cada row apunta a una entrada en `memory_plane` vía `source_entry_id`,
así narrativa y estructura quedan vinculadas.

- [x] `health_facts` — alergias, condiciones crónicas, tipo de sangre,
  contactos de emergencia. Todas con `permanent=1`.
- [x] `health_medications` — history table: cada cambio de dosis es un
  row nuevo (`started_at`, `ended_at` opcional, `dosage`, `frequency`,
  `condition`, `prescribed_by`, `notes`). Nunca se sobreescribe.
- [x] `health_vitals` — timeseries de presión, glucosa, peso, FC en
  reposo, temperatura, oxígeno. Cada lectura: timestamp + valor +
  contexto opcional.
- [x] `health_lab_results` — valores numéricos de análisis (colesterol
  total, LDL, HDL, glucosa en ayunas, A1c, etc.) con fecha y rangos de
  referencia del laboratorio.
- [x] `health_attachments` — paths a PDFs/imágenes de recetas,
  radiografías, análisis. El archivo queda en
  `~/.local/share/lifeos/health_attachments/` cifrado con la misma
  clave que `memory.db`.
- [x] Migrations idempotentes en `run_migrations` (mismo patrón que
  ya usamos en commits anteriores).
- [x] API Rust: `add_health_fact`, `delete_health_fact`, `record_vital`,
  `start_medication`, `stop_medication`, `get_active_medications`,
  `get_vitals_timeseries`, `get_health_summary`, etc. **No existe
  `update_medication` como mutación in-place: el modelo real es
  `stop_medication` + `start_medication` para preservar historial.**
- [x] Tests + version bump.

### BI.3 — Nutrición + recetas + listas de compras

- [ ] Side-table `nutrition_log` — cada comida/snack/colación con
  timestamp, descripción libre, fotos opcionales, voz opcional (path al
  audio cifrado), macros estimados (opcional, calculados por LLM cuando
  hay datos suficientes).
- [ ] Side-table `nutrition_preferences` — alergias alimentarias,
  intolerancias, dietas (vegetariano, vegano, keto, mediterráneo,
  diabético, hipertenso), gustos y disgustos del usuario.
- [ ] Side-table `nutrition_plans` — planes generados por Axi o por un
  nutriólogo (subido como atachment), con duración, objetivos, comidas
  sugeridas por día.
- [ ] Side-table `nutrition_recipes` — recetas guardadas (propuestas
  por Axi o subidas por el usuario) con ingredientes, pasos, tiempo,
  porciones, tags.
- [ ] Pipeline de **ingest desde foto**: usuario manda foto de su
  comida → vision-capable LLM (Qwen3.5-VL local o BYOK) la describe →
  Axi pregunta por confirmación/correcciones → guarda en
  `nutrition_log`.
- [ ] Pipeline de **ingest desde voz**: ya existe el STT, solo conectar
  al `nutrition_log`.
- [x] **Generador de listas de compras (BI.3.1 sprint inicial)** —
  side-table `shopping_lists` con `items_json` (cada item con name,
  quantity, unit, food_id opcional, checked, notes). API:
  `create_shopping_list`, `check_shopping_list_item`,
  `complete_shopping_list`, `archive_shopping_list`,
  `list_shopping_lists`, `get_shopping_list`. Telegram tools
  seccion 20j-20o. **Entregado**: el generador automático semanal ya
  cruza `nutrition_preferences` + recetas para proponer una lista.
- [x] **Integración con catálogo local (BI.3.1)** — tablas
  `food_db`, `commerce_stores`, `commerce_prices`. food_db con
  source = usda | openfoodfacts | smae | user, busqueda por
  substring de name + brand, lookup por barcode. commerce_prices
  cruza opcionalmente con food_db (food_id es nullable, asi se
  puede registrar precio de algo que no esta en el catalogo).
  API: `add_food`, `search_foods`, `get_food_by_id`,
  `get_food_by_barcode`, `add_commerce_store`,
  `deactivate_commerce_store`, `list_commerce_stores`,
  `record_commerce_price`, `list_prices_for_food`,
  `list_prices_at_store`. Telegram tools seccion 20a-20i.
  **Fuera del pillar:** importadores que precarguen USDA / Open Food
  Facts MX / SMAE como scripts externos. La foundation y el write path
  ya están entregados.
- [x] Tests añadidos: 6 nuevos en BI.3.1. Daemon → v0.3.26.

### BI.4 — Salud mental + diario emocional

**Esta es la sub-fase más sensible.** Por eso tiene salvaguardas
adicionales que no aplican al resto.

- [x] Side-table `mental_health_journal` — entradas narrativas con
  mood/energia/ansiedad 1-10, tags JSON, triggers JSON, narrativa
  cifrada (vault reforzado), `had_crisis_pattern` flag (visible sin
  vault).
- [x] Side-table `mental_health_mood_log` — quick check-ins (mood +
  energia + ansiedad + nota corta opcional). NO requiere vault.
- [x] **Cifrado reforzado**: la narrativa del diario va bajo el vault
  Argon2id (commit "BI vault foundation"). Sin `vault_unlock`, no se
  puede leer ni escribir la narrativa. Los campos numericos y el
  flag `had_crisis_pattern` SI son visibles sin vault, asi
  `mental_health_summary` puede decir "logueaste 3 entradas con
  patron en 30d" sin abrir nada.
- [x] **Auth secundaria (opt-in)**: backend de PIN local entregado.
  El dashboard wiring real queda como trabajo fuera del pillar.
- [x] **Detección de crisis**: `detect_crisis_in_text` corre sobre
  plaintext ANTES de cifrar. 3 niveles (severe → suicidio,
  autolesion; high → abuso, violencia; moderate → desesperanza,
  panico). En cualquier match, las respuestas de Telegram inyectan
  el bloque de hotlines (SAPTEL, Linea de la Vida, Locatel,
  Refugios, 911) ANTES de cualquier otra cosa. Las palabras gatillo
  NUNCA se persisten en claro — solo el bool del row.
- [x] **Disclaimer obligatorio**: seccion 16 del system prompt
  enforza que Axi NO es terapeuta y SIEMPRE recomienda profesional
  para temas serios.
- [x] **No salir nunca (parcial)**: la fase BH.13 (federacion) ya
  excluye todo lo de `is_wellness_kind` por diseno; el prefijo
  `mental_*` esta en esa lista. Falta validar que ningun otro path
  exporte el journal — se hace cuando se aterrice federacion.
- [x] **Modo pánico**: tool `wipe_mental_health` entregada con phrase
  de confirmación. Borra journal + mood log sin tocar el vault.
- [x] Tests añadidos: 10 nuevos en `memory_plane::tests`. Daemon
  → v0.3.23.

### BI.5 — Ejercicio + actividad física

- [x] Side-table `exercise_log` — sesiones registradas con tipo,
  duración, intensidad percibida (RPE 1-10), notas. Cardio y fuerza.
- [x] Side-table `exercise_inventory` — qué tiene el usuario en casa o
  en su gimnasio (mancuernas, banca, barra, kettlebell, ligas, banda,
  TRX, máquina elíptica, etc.).
- [x] Side-table `exercise_plans` — rutinas guardadas (de Axi, de un
  entrenador, de YouTube, etc.) con ejercicios, sets, reps, descansos.
- [ ] **Generador de rutinas hardware-aware**: Axi propone rutinas
  basadas en `exercise_inventory` y los objetivos del usuario. Si solo
  tiene una banda y quiere fuerza de tren superior, no le propone
  press de banca con barra olímpica.
- [ ] **No integración con wearables en V1.** Apple Watch / Fitbit /
  Garmin viven en sus propios silos. Eso es Fase BJ o similar — por
  ahora el usuario registra manualmente, lo cual es fricción real
  pero más simple que escribir 5 importadores de cada wearable.
- [x] Tools y summary entregados (`exercise_inventory_add`,
  `exercise_plan_add`, `exercise_log_session`, `exercise_summary`).

### BI.6 — Salud femenina (ciclo menstrual) — opt-in explícito

**Sensible por contexto post-Roe.** Aunque en México el aborto es legal
nacional desde 2023 (SCJN), en algunos estados sigue habiendo
criminalización efectiva, y los usuarios pueden viajar. Trato similar
al de salud mental en cuanto a cifrado y exportación.

- [x] Side-table `menstrual_cycle_log` — entradas con
  cycle_day, flow_intensity (none/spotting/light/medium/heavy),
  symptoms (JSON array), mood/energia/dolor 1-10, narrativa
  OPCIONAL cifrada bajo vault. API: `log_menstrual_entry`,
  `list_menstrual_entries_meta` (sin vault),
  `list_menstrual_entries` (require vault),
  `get_menstrual_cycle_summary` (cualquier estado del vault, computa
  `days_since_last_period` como la entrada mas reciente con flow != none).
- [x] Predicciones simples (no ML, no cloud) basadas en promedio de
  los últimos 6 ciclos del propio usuario. El predictor ya existe.
- [x] **Cifrado reforzado** via vault Argon2id (foundation). La
  narrativa va bajo vault solo si existe. Crisis detection corre sobre
  la narrativa en plaintext antes de cifrar.
- [x] **Jamás sale del dispositivo.** Prefijo `health_*` ya esta en
  `is_wellness_kind`, asi que la federacion BH.13 lo excluye por
  diseno (mismo path que BI.4).
- [x] **Modo pánico** equivalente: `wipe_menstrual` entregada.
- [x] Tests añadidos (5 nuevos en BI.6) + Telegram tools seccion 18.
  Daemon → v0.3.25.

### BI.7 — Crecimiento personal (lectura, hábitos, carrera)

- [x] Side-table `reading_log` — libros que el usuario está leyendo,
  ha leído, quiere leer; con notas, highlights, fechas.
- [x] Side-table `habits` — hábitos que el usuario quiere construir
  (meditar, correr, leer, dormir 8h, no fumar, etc.) con tracking
  diario simple (sí/no) y rachas.
- [x] Side-table `growth_goals` — objetivos profesionales y personales
  con plazo, sub-tareas, progreso.
- [ ] **Reminders proactivos**: Axi pregunta una vez al día (hora
  configurable, default 21:00) por los hábitos del día, sin presionar.
- [x] Tools y surfaces entregados (`book_add`, `book_status_set`,
  `habit_add`, `habit_checkin`, `goal_add`, `goal_progress`,
  `growth_summary`, `habit_current_streak`, `habits_due_today`).

### BI.9 — Relaciones humanas (pareja, familia, hijos, amigos)

Cubre el caso del usuario: *"como esposo siento que me estoy alejando
de mi esposa, ¿cómo mejoro?"*. Axi necesita conocer las relaciones del
usuario para dar consejos contextualizados — quién es quién, en qué
etapa están, qué ha pasado, qué le importa.

- [x] **(sprint 1)** Side-table `relationships` — personas importantes en la vida del
  usuario con tipo de relación, etapa actual (amistad, noviazgo,
  matrimonio, divorcio, distanciamiento, etc.), fechas clave
  (cumpleaños, aniversarios, primer encuentro), notas. Implementado
  con `add_relationship`, `update_relationship_stage`,
  `mark_relationship_contact`, `deactivate_relationship`,
  `list_relationships`. Notas cifradas. importance_1_10 con clamp.
- [x] **(BI.9.2 entregado)** Side-table `relationship_events` —
  eventos significativos en cada relación: discusiones,
  reconciliaciones, momentos importantes, sentimientos del usuario
  sobre esa persona en esa fecha. La narrativa va SIEMPRE cifrada
  bajo el vault Argon2id (commit "vault foundation"). Crisis
  detection (BI.4) corre en plaintext antes de cifrar y solo el bool
  persiste. Metadata (event_type, intensity, sentiment, fecha,
  had_crisis_pattern) visible sin vault. API:
  `add_relationship_event`, `list_relationship_events` (vault
  required), `list_relationship_event_meta` (sin vault),
  `get_relationship_timeline` (cualquier estado del vault). Tools
  Telegram seccion 17.
- [x] **(sprint 1)** Side-table `family_members` — específica para familiares con
  parentesco, fechas relevantes (nacimiento, fallecimiento, eventos),
  condiciones de salud heredables relevantes que cruza con
  `medical_visit_prep` (BI.8) — los familiares con
  `health_conditions_known` aparecen en el paquete del doctor como
  contexto hereditario.
- [x] **(sprint 1)** Side-table `children_milestones` — para padres: hitos de
  desarrollo, vacunas, primer diente, primera palabra, escuela,
  problemas de conducta, logros. Permanente por diseño. Validación
  estricta de fecha YYYY-MM-DD. Notas cifradas.
- [x] **Coaching de relaciones** — Axi puede:
  - Dar consejos generales basados en literatura de relaciones (Gottman,
    Esther Perel, Gary Chapman) — sin ser terapeuta de pareja.
  - Sugerir lecturas, videos, podcasts específicos cuando el usuario
    pide ayuda con una relación concreta.
  - Recordar fechas importantes ("hoy es el cumpleaños de tu mamá").
  - Notar patrones cruzados ("noto que tu estado de ánimo correlaciona
    con cómo describes tu última interacción con [nombre]").
  - Sugerir acciones concretas ("dijiste que querías llamar más a tu
    papá — han pasado 3 semanas desde la última, ¿quieres que te lo
    recuerde mañana?").
- [x] **Disclaimers de relaciones**: Axi NO es consejero matrimonial,
  NO es terapeuta de pareja, NO sustituye terapia familiar
  profesional. Las recomendaciones son generales — para problemas
  serios (abuso, infidelidad, divorcio en curso, custodia), recomendar
  profesional certificado.
- [x] **(sprint 1)** Tools en Telegram (sección 14 del system prompt):
  `relationship_add`, `relationship_stage`, `relationship_contact`,
  `relationship_list`, `family_member_add`, `family_list`,
  `child_milestone_log`, `child_milestones_list`,
  `relationships_summary`, `relationship_advice`.
  `relationship_event_log` ya entregado
  en BI.9.2.
- [x] **(sprint 3)** `stale_relationships(min_importance, days_threshold)`
  — generaliza el detector de forgetting_check con thresholds
  configurables. Telegram tool 23d, HTTP endpoint
  `/relationships/stale`.
- [x] **(sprint 1)** BI.8 wired: `LifeSummary.relationships`
  agregado, patrón cruzado `relationships_stale_contacts` (contactos
  >=7 sin movimiento en 30d), `forgetting_check` surface
  `relationship_stale` (importancia >=7 con >=45d sin contacto), y
  `medical_visit_prep` incluye `family_health_history`.

### BI.10 — Espiritualidad (con o sin religión)

El usuario lo dijo perfecto: *"la espiritualidad va más allá de una
religión"*. Esta sub-fase reconoce que el bienestar espiritual es
transversal — algunas personas lo viven como fe religiosa, otras como
meditación, otras como contacto con la naturaleza, otras como sentido
de propósito secular.

- [x] Side-table `spiritual_practices` — prácticas que el usuario
  realiza (meditación, oración, lectura espiritual, naturaleza,
  yoga, journaling reflexivo, etc.) con frecuencia, duración,
  experiencia subjetiva. Tipo de práctica es texto libre — Axi no
  juzga si es religiosa, agnóstica, atea, secular.
- [x] Side-table `spiritual_reflections` — entradas narrativas sobre
  preguntas existenciales, sentido de vida, valores, propósito, dudas
  espirituales. Cifrado reforzado opcional (mismo modelo que mental).
- [x] Side-table `values_compass` — los 5-10 valores fundamentales
  que el usuario identifica como suyos (familia, honestidad, libertad,
  creatividad, servicio, justicia, etc.) con notas sobre por qué.
- [ ] **Acompañamiento sin proselitismo**: Axi NUNCA promueve una
  religión específica, NUNCA descalifica creencias del usuario, NUNCA
  empuja hacia o lejos de prácticas espirituales. Solo acompaña la
  reflexión.
- [ ] **Sugerencias de recursos generales**: lecturas (filosofía,
  espiritualidad comparada, psicología existencial), prácticas
  (mindfulness sin tradición específica, ejercicios de gratitud,
  ejercicios de valores), basados en lo que el usuario explora.
- [ ] **Conexión con propósito**: Axi puede ayudar al usuario a
  identificar cuándo sus acciones diarias se alinean (o no) con sus
  valores declarados. Sin sermonear.
- [x] Tools/surfaces: `spiritual_practice_add`,
  `spiritual_reflection_add`, `core_value_add`, `core_value_list`,
  `spiritual_summary`.

### BI.11 — Salud financiera

La salud financiera es **fuente número 1 de estrés** según múltiples
estudios — y afecta directamente todas las demás dimensiones (física
por estrés, mental por ansiedad, relacional por conflictos de pareja,
etc.). LifeOS la trata como wellness, no como contabilidad.

- [x] Side-table `financial_accounts` — cuentas del usuario (banco,
  efectivo, inversiones, deudas) sin saldos automáticos — el usuario
  los registra cuando quiere. **No nos conectamos a bancos vía API en
  V1** (eso es un proyecto separado, requiere certificación PCI-DSS,
  no nos vamos por ahí).
- [x] Side-table `financial_expenses` — registro libre de gastos: monto,
  categoría, fecha, notas. Puede ser foto del ticket → vision LLM
  extrae texto → confirmación del usuario.
- [x] Side-table `financial_income` — fuentes de ingreso recurrente o
  ocasional.
- [x] Side-table `financial_goals` — metas (ahorrar X para Y,
  pagar deuda Z para fecha W).
- [ ] **Coaching financiero general**: Axi puede explicar conceptos
  básicos (qué es una tasa de interés, cómo funciona el interés
  compuesto, qué es un fondo de emergencia, cómo priorizar deudas),
  recomendar lecturas (Ramit Sethi, Bogleheads para inversión pasiva,
  literatura básica de finanzas personales en español).
- [x] **NO es asesor financiero**. NO recomienda inversiones
  específicas. NO predice mercados. NO maneja dinero del usuario.
  Es un compañero de reflexión y registro.
- [ ] **Alertas suaves**: si el usuario registra gastos que parecen
  desproporcionados a su ingreso, o si lleva 3 meses sin ahorrar
  cuando dijo que quería, Axi pregunta — sin juzgar.
- [x] Tools/surfaces: `financial_account_add`, `financial_account_list`,
  `expense_log`, `expense_list`, `income_log`, `income_list`,
  `financial_goal_add`, `financial_goal_progress`,
  `financial_goal_list`, `financial_summary`.

### BI.12 — Salud sexual e íntima

Categoría sensible que combina salud física, salud mental y salud
relacional. Trato similar a mental health en cuanto a salvaguardas.

- [x] Side-table `sti_tests` — pruebas de ITS (HIV, syphilis,
  hepatitis_b, gonorrhea, chlamydia, panel) con result
  (negative/positive/pending/inconclusive), tested_at, lab_name,
  notas opcionales con cifrado por defecto. NO requiere vault.
- [x] Side-table `contraception_methods` — metodo, started_at,
  ended_at (history table style), notas. NO requiere vault.
- [x] Side-table `sexual_health_log` — encounter_type
  (solo/partner/multiple/other), partner_relationship_id (FK
  textual a relationships, opcional), protection_used,
  satisfaction_1_10, **consent_clear (default true)**, narrativa
  cifrada bajo vault, had_crisis_pattern. La narrativa SIEMPRE va
  bajo vault — no es opcional.
- [x] **Detección de consent violation absoluta**: si
  `consent_clear=false`, AUTOMATICAMENTE marca had_crisis_pattern
  con severity=severe, surface hotlines + Red Nacional de Refugios
  + 911. Esto NUNCA se desactiva. Cuenta separada en summary
  (`consent_violations_count_30d`).
- [x] **Cifrado reforzado** via vault Argon2id (foundation).
- [x] **Detección de violencia sexual**: el detector de crisis
  (BI.4) corre sobre la narrativa antes de cifrar; consent=false
  ademas dispara automaticamente. Hotlines incluyen Red Nacional de
  Refugios.
- [x] **NUNCA sale del dispositivo.** El prefijo `sexual_*` esta en
  `is_wellness_kind` para excluirlo de federacion BH.13.
- [x] **Modo pánico** equivalente: `wipe_sexual_health` entregada.
- [x] Tools: `sexual_health_log`, `sexual_health_history_meta`,
  `sexual_health_history`, `sti_test_log`, `sti_tests_list`,
  `contraception_add`, `contraception_end`, `contraception_list`,
  `sexual_health_summary`. Telegram seccion 19. Daemon → v0.3.25.

### BI.13 — Salud social y comunitaria

Más allá del círculo íntimo — sentido de pertenencia, contribución,
ciudadanía, voluntariado. Hay literatura robusta (Putnam "Bowling
Alone", Robert Waldinger del Harvard Study of Adult Development) que
muestra que las relaciones de comunidad amplia son tan importantes
para la longevidad como el ejercicio.

- [x] Side-table `community_activities` — pertenencia a grupos
  (deportivos, religiosos, voluntariado, hobbies, profesionales),
  participación, frecuencia.
- [x] Side-table `civic_engagement` — votaciones, voluntariado,
  donaciones, participación cívica.
- [x] Side-table `contribution_log` — momentos donde el usuario
  ayudó a alguien o a una causa. La gratitud por contribuir está
  ligada al bienestar de larga vida.
- [x] **Sugerencias proactivas**: si Axi nota que el usuario no ha
  participado en ninguna actividad comunitaria en N meses, puede
  preguntar gentilmente "¿extrañas estar en [grupo]?".
- [x] Tools/surfaces: `community_add`, `community_attend`,
  `community_list`, `civic_log`, `contribution_log`, `social_summary`.

### BI.14 — Sueño profundo

El sueño aparece tangencialmente en `health_vitals` (sleep_hours),
pero merece su propia sub-fase porque es una de las palancas más
poderosas para todas las demás dimensiones.

- [x] Side-table `sleep_log` — entradas con: hora de dormir, hora de
  despertar, calidad subjetiva (1-10), interrupciones, sueños
  relevantes, cómo te sientes al despertar.
- [x] Side-table `sleep_environment` — temperatura del cuarto,
  oscuridad, ruido, dispositivos, café/alcohol previo, ejercicio,
  cena pesada o ligera.
- [x] **Detección de patrones cruzados**: Axi puede notar
  correlaciones entre sueño y otras dimensiones (ánimo, glucosa,
  ejercicio, productividad reportada, etc.).
- [ ] **Coaching de higiene del sueño**: prácticas básicas
  (oscuridad, frescura, no pantallas antes de dormir, horario
  consistente) — bien establecidas en literatura, no controversiales.
- [ ] **NO diagnostica trastornos del sueño**. Si el usuario reporta
  insomnio crónico, ronquidos severos, apneas presenciales,
  somnolencia diurna excesiva — Axi recomienda ver a un especialista
  en medicina del sueño.
- [x] Tools/surfaces: `sleep_log`, `sleep_environment_add`,
  `sleep_history`, `sleep_summary`.

### BI.8 — Coaching unificado (Axi como narrador de tu vida)

Esta es la culminación. Sin BI.1-BI.14 no hay datos suficientes; con
ellos, Axi puede empezar a sintetizar.

- [x] **Resúmenes semanales/mensuales** automáticos: `get_life_summary(window, today_local)`
  agrega health + growth + exercise + nutrition + social + sleep +
  spiritual + financial en un solo struct narrativo, con cabeceras
  por pilar y los patrones cruzados detectados al final. Telegram
  tool: `life_summary`.
- [x] **Detección de patrones cruzados**: `detect_cross_domain_patterns`
  + heurística pura sobre las summaries cargadas. Hoy detecta: sueno
  bajo + ejercicio bajo, sueno < 6h, alta carga + proteina baja,
  drift espiritual (>14d), drift social (>21d), gastos > ingresos en
  30d, metas estancadas (>=3 con 0%). Cada patrón viene con
  evidencia citable. Telegram tool: `cross_domain_patterns`.
- [x] **Preparación para visitas médicas**: `prepare_medical_visit(reason, lookback_days)`
  arma un paquete con alergias, condiciones, medicamentos activos,
  vitales recientes, labs recientes, sintomas mencionados en
  `memory_entries` (kind `health_*` o keywords en español) y
  preguntas sugeridas para el doctor. Telegram tool: `medical_visit_prep`.
- [x] **Chequeo proactivo de no-olvido**: `forgetting_check(today_local)`
  saca a la luz growth_goals activas con `updated_at` >60d, growth_goals
  pausadas, libros en `Reading` sin mover en 60d, hábitos activos sin
  check-ins en 30d, comunidades sin asistencia en 90d, prácticas
  espirituales sin marca en 30d y metas financieras sin movimiento
  en 60d. Ordenadas "más olvidado primero", cap 20. Telegram tool:
  `forgetting_check`.
- [x] Tests + version bump (5 tests añadidos en `memory_plane::tests`,
  daemon → v0.3.20).

## Lo que NO va a hacer (CRÍTICO — no negociable)

Esta fase toca dominios donde el daño potencial es real. Las
restricciones siguientes son **absolutas** y deben aplicarse desde el
día 1:

- **Axi NO es médico.** No diagnostica enfermedades. No prescribe
  medicamentos. Si el usuario describe síntomas preocupantes, Axi
  recomienda ver a un médico real, jamás "podrías tener X".
- **Axi NO es terapeuta.** No hace terapia. No interpreta sueños. No
  diagnostica trastornos mentales. Acompaña, escucha, refleja, y
  recomienda ayuda profesional.
- **Axi NO es nutriólogo.** No prescribe dietas para condiciones
  médicas (diabetes severa, enfermedad renal, embarazo, trastornos
  alimentarios). Las propuestas de comida son sugerencias para
  alguien sano que quiere comer mejor — para condiciones reales,
  recomienda nutriólogo certificado.
- **Axi NO es entrenador personal.** Las rutinas son sugerencias
  generales. Para entrenamiento serio, lesiones, rehabilitación,
  recomendar profesional.
- **Axi NO es consejero matrimonial ni terapeuta de pareja/familia.**
  Las sugerencias sobre relaciones son generales — basadas en
  literatura, no en peritaje clínico. Para problemas serios (abuso,
  infidelidad, divorcio en curso, custodia, violencia familiar),
  recomendar profesional certificado o líneas de ayuda.
- **Axi NO es guía espiritual ni religioso.** No promueve ninguna
  religión, no descalifica creencias, no juzga prácticas espirituales
  del usuario. Solo acompaña la reflexión.
- **Axi NO es asesor financiero certificado.** No recomienda
  inversiones específicas, no predice mercados, no maneja dinero del
  usuario. La educación financiera básica está bien; consejos
  específicos sobre instrumentos financieros NO.
- **Axi NO es educador sexual ni médico de salud sexual.** Responde
  con información médicamente correcta general, pero para problemas
  específicos recomienda profesionales (ginecólogo, urólogo,
  sexólogo).
- **NO hace diagnóstico automatizado** de NADA. No "tienes depresión",
  no "tienes diabetes tipo 2", no "tienes síndrome premenstrual
  severo". Solo registro y reflexión.
- **NO comparte datos JAMÁS.** Ni anonimizados, ni opt-in, ni
  agregados. La federación de Fase BH.13 EXCLUYE todo lo de Fase BI
  por diseño — ni siquiera con consentimiento explícito se manda.
- **NO se conecta a aseguradoras** ni a sistemas de salud externos.
  Si en el futuro hay un import desde el IMSS o desde Apple Health,
  es **import**, nunca export.
- **NO se monetiza con los datos.** Si LifeOS algún día vende algo,
  es la herramienta, no la información del usuario.
- **NO usa LLMs remotos para mental health por defecto.** Las
  entradas de `mental_health_journal` solo pueden procesarse con el
  LLM local. Para enviarlas a Cerebras/Groq/OpenRouter el usuario
  tiene que activarlo explícitamente por entrada, con preview
  completo de qué se manda.
- **En crisis NO improvisa.** Patrones de crisis (suicidio,
  autolesión, abuso) → siempre hotline + nunca solo "aquí estoy
  para ti".

## Estado y dependencias

- Todas las sub-fases dependen del trabajo de memoria que ya está en
  `main` (commits 2940422, 30d3b30, 39aa663, d3ab5c3).
- BI.1 desbloquea todo lo demás técnicamente.
- BI.2 (salud médica estructurada) y BI.4 (salud mental) son las
  más urgentes desde la perspectiva del usuario.
- BI.3 (nutrición) y BI.5 (ejercicio) son las que más generan
  engagement diario.
- BI.6 (salud femenina) es opt-in y solo aplica a parte de los
  usuarios — no es bloqueante.
- BI.7 y BI.8 son la culminación: una vez que hay datos, el coaching
  emerge.

## Por qué esto cabe en LifeOS

LifeOS ya tiene **todas** las piezas necesarias para soportar este
pillar sin grandes refactors:

| Necesidad de Fase BI | Pieza existente |
|---|---|
| Almacenamiento cifrado local | `memory_plane` (AES-GCM-SIV) |
| Búsqueda híbrida sobre memoria | `search_entries` con embeddings nomic |
| Memoria que nunca pierde nada importante | `permanent=1` + decay Ebbinghaus + connection bonus + cluster summary (commits del 2026-04-06) |
| Recordatorios programados | `calendar` + `scheduled_tasks` (infra disponible, no integrada de forma completa en BI para medication reminders) |
| Procesamiento de fotos | Vision pipeline existente (Qwen3.5-VL multimodal) |
| Procesamiento de voz | Wake word + STT + TTS pipeline |
| Conversación natural en español | Telegram bridge + agentic chat loop |
| Privacidad end-to-end | Encrypted at rest, never sent to cloud |
| Tools system para capacidades nuevas | 84 tools actuales + extensible |
| Dashboard UI | Web dashboard ya existe, fácil agregar tabs |

Notas de realidad (post-auditoría):
1. BI ya NO está en etapa foundation; BI.1–BI.14 están implementadas en backend.
2. Lo pendiente principal es consumo (dashboard UX, integraciones puntuales), no side-tables base.
3. `health_attachments` existe en backend/storage cifrado, pero no tiene todavía una surface de producto completa (upload/download UX end-to-end) en esta fase documental.

## Riesgos a vigilar

Documentados en detalle en [`docs/research/wellness-pillar/README.md`](../research/wellness-pillar/README.md).
Resumen:

1. **Liability legal** — LifeOS es software, no es servicio médico.
   Disclaimers explícitos + nunca llamarlo "diagnóstico".
2. **Hallucinations en contexto médico** — un LLM inventando una dosis
   puede matar. Mitigación: medicamentos siempre vienen de input del
   usuario o de la receta escaneada, jamás del LLM solo.
3. **Privacidad post-Roe / contextos de abuso** — datos de salud
   mental, ciclo menstrual y embarazo son evidencia legal en algunos
   contextos. Mitigación: cifrado reforzado + modo pánico.
4. **Sobre-confianza del usuario** — si Axi se vuelve muy bueno
   acompañando, el usuario puede dejar de buscar ayuda profesional
   real. Mitigación: disclaimers periódicos + recomendación activa
   de profesionales en eventos clave.
5. **Familia / convivientes accediendo a la laptop** — cualquier
   persona con acceso físico al equipo puede leer todo lo que está
   descifrado en la sesión activa. Mitigación: auth secundaria
   opt-in para categorías sensibles.

## Estado

- Investigación profunda: [`docs/research/wellness-pillar/README.md`](../research/wellness-pillar/README.md)
- Backend del pillar BI: **cerrado funcionalmente** (auditoría 2026-04-07).
- Pendientes actuales: surfaces consumidoras (dashboard/UX), integraciones explícitas (ej. reminders), y mejoras fuera del cierre de BI.
