# Fase BI — Bienestar Integral & Coach Personal ("Vida Plena")

> **Estado:** Visión consecutiva con sub-fases incrementales (BI.1 → BI.14).
> No es vision futura — cada sub-fase se puede empezar cuando termine la
> anterior, sin investigación profunda adicional.
> **Investigación detallada:** [`docs/research/wellness-pillar/README.md`](../research/wellness-pillar/README.md)
> **Heredando de:** El canal "Vida Plena - Héctor" en Telegram que el
> usuario llevaba con OpenClaw, donde registraba enfermedades, ejercicios,
> y reflexiones diarias. Esta fase es la versión local-first, cifrada y
> mucho más amplia de esa idea.
> **Fecha:** 2026-04-06

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
| "Me dio gripa, le doy mis síntomas, le paso foto de la receta, Axi me agenda recordatorios de medicamento, le voy contando cómo me siento, hasta que me recupero" | Side-tables `health_events` + `health_medications` + `health_attachments` + integración con `calendar` para reminders |
| "Tengo diabetes/hipertensión, las dosis cambian con el tiempo, hago ejercicio y eventualmente me las quitan" | `health_medications` como history table (cada cambio = row nuevo) + `health_vitals` timeseries |
| "Le mando foto/voz/texto de lo que comí" | `nutrition_log` con vision pipeline para fotos + STT para voz |
| "Quiero que me proponga recetas con lo que conoce de mí, ligadas a productos que sí venda mi tienda local" | `nutrition_recipes` + integración con `local_commerce` (catálogo de productos disponibles en zona) |
| "Le cuento cosas muy personales — mi infancia, cómo me siento hoy, traumas, cosas que jamás le diría a un humano" | `mental_health_journal` con cifrado reforzado + auth secundaria + crisis hotlines automáticas |
| "Quiero un plan de ejercicios desde casa, con lo que tengo a la mano" | `exercise_plans` + `exercise_log` |
| "Soy mujer, quiero llevar mi ciclo menstrual, síntomas, predicciones" | `menstrual_cycle` (opt-in, encriptación reforzada por contexto post-Roe) |
| "Quiero historial clínico que sobreviva al cambio de doctor" | `health_summary` exportable a Markdown/PDF estructurado |
| "Quiero leer más, crecer profesionalmente" | `reading_log` + `growth_goals` + reminders proactivos |
| "Soy alérgico a X — NUNCA lo olvides" | `health_facts` con `permanent=1` automático + auto-inyección en system prompt cuando hablas de comida o medicinas |

## Sub-fases (consecutivas, incrementales)

Cada sub-fase es independiente y entregable. Se pueden ordenar pero la
dependencia técnica más fuerte es BI.1 → todo lo demás (sin BI.1 no se
garantiza que los datos sobrevivan).

### BI.1 — Nunca perder nada (la base universal)

Pre-requisito de todo el resto. Ya lo discutimos con el usuario en el
turno anterior.

- [ ] `apply_decay` cambia GC delete → GC archive (afecta TODO, no solo
  bienestar). Las entradas que hoy se borrarían a `<10@90d` o `<30@180d`
  ahora se mueven a `memory_archive` en vez de eliminarse.
- [ ] Nuevo tool `recall_archived(query)` para que el LLM acceda a la
  tabla archivo cuando el usuario diga "tenía una idea pero ya no
  recuerdo qué era".
- [ ] Auto-mark `kind LIKE "health_%" OR kind LIKE "wellness_%"` como
  `permanent=1` en `add_entry`.
- [ ] Skip `kind LIKE "health_%"` en `dedup_similar` (los eventos
  médicos jamás se fusionan, incluso si el texto es casi idéntico —
  porque dos dosis del mismo medicamento son eventos distintos).
- [ ] 4-5 tests + version bump.

### BI.2 — Salud médica estructurada

Side-tables en `memory.db` (mismo archivo, mismo cifrado, mismo backup).
Cada row apunta a una entrada en `memory_plane` vía `source_entry_id`,
así narrativa y estructura quedan vinculadas.

- [ ] `health_facts` — alergias, condiciones crónicas, tipo de sangre,
  contactos de emergencia. Todas con `permanent=1`.
- [ ] `health_medications` — history table: cada cambio de dosis es un
  row nuevo (`started_at`, `ended_at` opcional, `dosage`, `frequency`,
  `condition`, `prescribed_by`, `notes`). Nunca se sobreescribe.
- [ ] `health_vitals` — timeseries de presión, glucosa, peso, FC en
  reposo, temperatura, oxígeno. Cada lectura: timestamp + valor +
  contexto opcional.
- [ ] `health_lab_results` — valores numéricos de análisis (colesterol
  total, LDL, HDL, glucosa en ayunas, A1c, etc.) con fecha y rangos de
  referencia del laboratorio.
- [ ] `health_attachments` — paths a PDFs/imágenes de recetas,
  radiografías, análisis. El archivo queda en
  `~/.local/share/lifeos/health_attachments/` cifrado con la misma
  clave que `memory.db`.
- [ ] Migrations idempotentes en `run_migrations` (mismo patrón que
  ya usamos en commits anteriores).
- [ ] API Rust: `add_health_fact`, `record_vital`, `start_medication`,
  `stop_medication`, `update_medication`, `get_active_medications`,
  `get_vitals_timeseries`, `get_health_summary`, etc.
- [ ] Tests + version bump.

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
- [ ] **Generador de listas de compras** — Axi propone una lista
  semanal basada en `nutrition_preferences` + `nutrition_recipes` +
  `nutrition_plans` activos.
- [ ] **Integración con catálogo local** (BI.3.1, opcional pero
  importante): nuevo módulo `local_commerce` que mantiene un catálogo
  de productos disponibles en la zona del usuario (configurable
  manualmente al principio, eventualmente con scrapers opt-in para
  Walmart México, Soriana, Chedraui, mercados locales). Las listas de
  compras se filtran contra este catálogo y Axi marca claramente qué
  productos hay localmente, cuáles hay solo online, y cuáles no hay.
- [ ] Tests + version bump.

### BI.4 — Salud mental + diario emocional

**Esta es la sub-fase más sensible.** Por eso tiene salvaguardas
adicionales que no aplican al resto.

- [ ] Side-table `mental_health_journal` — entradas narrativas con
  timestamp, etiquetas emocionales (ansioso, triste, enojado, feliz,
  abrumado, tranquilo, etc.), nivel del 1-10, contexto.
- [ ] **Cifrado reforzado**: clave derivada de una passphrase del
  usuario, separada de la clave default de `memory.db`. Si el usuario
  no ingresa la passphrase, las entradas mentales NO se descifran ni
  para search ni para recall — quedan opacas.
- [ ] **Auth secundaria (opt-in)**: para abrir el diario mental desde
  el dashboard o desde Telegram, segundo factor (PIN local). Esto
  protege contra "alguien abrió mi laptop sin permiso".
- [ ] **Detección de crisis**: patrones tipo "quiero morirme", "no
  puedo más", "no vale la pena seguir", "mejor ya no estar aquí" →
  Axi **siempre** responde con número de hotline local
  (SAPTEL 55 5259 8121, Línea de la Vida 800 290 0024 en México)
  además de la respuesta empática. Esto **no es opcional** y no se
  puede desactivar.
- [ ] **Disclaimer obligatorio**: la primera entrada de cada sesión que
  toca salud mental, Axi recuerda que NO es terapeuta, que es un
  registro/reflejo, y que ver a un profesional real es valioso. Se
  puede ocultar después de N veces si el usuario lo pide.
- [ ] **No salir nunca**: las entradas de `mental_health_journal`
  jamás se sincronizan, jamás se exportan automáticamente, jamás se
  mandan al upstream de federación de compatibilidad (Fase BH.13).
  El usuario tiene que exportarlas explícitamente él mismo si quiere
  llevarlas a un terapeuta.
- [ ] **Modo pánico**: comando explícito (`/wipe-mental` desde
  Telegram, botón rojo en el dashboard) que borra de forma segura
  TODO el `mental_health_journal` con confirmación doble. Para casos
  donde el usuario está en peligro físico (familia abusiva, disputa
  legal, etc.) y necesita borrar evidencia.
- [ ] Tests + version bump.

### BI.5 — Ejercicio + actividad física

- [ ] Side-table `exercise_log` — sesiones registradas con tipo,
  duración, intensidad percibida (RPE 1-10), notas. Cardio y fuerza.
- [ ] Side-table `exercise_inventory` — qué tiene el usuario en casa o
  en su gimnasio (mancuernas, banca, barra, kettlebell, ligas, banda,
  TRX, máquina elíptica, etc.).
- [ ] Side-table `exercise_plans` — rutinas guardadas (de Axi, de un
  entrenador, de YouTube, etc.) con ejercicios, sets, reps, descansos.
- [ ] **Generador de rutinas hardware-aware**: Axi propone rutinas
  basadas en `exercise_inventory` y los objetivos del usuario. Si solo
  tiene una banda y quiere fuerza de tren superior, no le propone
  press de banca con barra olímpica.
- [ ] **No integración con wearables en V1.** Apple Watch / Fitbit /
  Garmin viven en sus propios silos. Eso es Fase BJ o similar — por
  ahora el usuario registra manualmente, lo cual es fricción real
  pero más simple que escribir 5 importadores de cada wearable.
- [ ] Tests + version bump.

### BI.6 — Salud femenina (ciclo menstrual) — opt-in explícito

**Sensible por contexto post-Roe.** Aunque en México el aborto es legal
nacional desde 2023 (SCJN), en algunos estados sigue habiendo
criminalización efectiva, y los usuarios pueden viajar. Trato similar
al de salud mental en cuanto a cifrado y exportación.

- [ ] Side-table `menstrual_cycle` — entradas con flujo (ninguno,
  ligero, moderado, abundante), síntomas (cólicos, dolor de cabeza,
  cambios de humor, antojos, etc.), notas.
- [ ] Predicciones simples (no ML, no cloud) basadas en promedio de
  los últimos 6 ciclos del propio usuario.
- [ ] **Cifrado reforzado** igual que mental health — passphrase
  separada opcional.
- [ ] **Jamás sale del dispositivo.** Cero sync, cero export
  automático, cero federación.
- [ ] **Modo pánico** equivalente: `/wipe-cycle` para borrado
  irrecuperable bajo doble confirmación.
- [ ] Tests + version bump.

### BI.7 — Crecimiento personal (lectura, hábitos, carrera)

- [ ] Side-table `reading_log` — libros que el usuario está leyendo,
  ha leído, quiere leer; con notas, highlights, fechas.
- [ ] Side-table `habits` — hábitos que el usuario quiere construir
  (meditar, correr, leer, dormir 8h, no fumar, etc.) con tracking
  diario simple (sí/no) y rachas.
- [ ] Side-table `growth_goals` — objetivos profesionales y personales
  con plazo, sub-tareas, progreso.
- [ ] **Reminders proactivos**: Axi pregunta una vez al día (hora
  configurable, default 21:00) por los hábitos del día, sin presionar.
- [ ] Tests + version bump.

### BI.9 — Relaciones humanas (pareja, familia, hijos, amigos)

Cubre el caso del usuario: *"como esposo siento que me estoy alejando
de mi esposa, ¿cómo mejoro?"*. Axi necesita conocer las relaciones del
usuario para dar consejos contextualizados — quién es quién, en qué
etapa están, qué ha pasado, qué le importa.

- [ ] Side-table `relationships` — personas importantes en la vida del
  usuario con tipo de relación, etapa actual (amistad, noviazgo,
  matrimonio, divorcio, distanciamiento, etc.), fechas clave
  (cumpleaños, aniversarios, primer encuentro), notas.
- [ ] Side-table `relationship_events` — eventos significativos en
  cada relación: discusiones, reconciliaciones, momentos importantes,
  sentimientos del usuario sobre esa persona en esa fecha. **Cifrado
  reforzado** porque es categoría sensible (puede haber abuso, infidelidad,
  conflictos legales).
- [ ] Side-table `family_members` — específica para familiares con
  parentesco, fechas relevantes (nacimiento, fallecimiento, eventos),
  condiciones de salud heredables relevantes (cruza con `health_facts`
  del usuario para alertas tipo "tu papá tuvo diabetes a los 50, vale
  la pena que te chequees").
- [ ] Side-table `children_milestones` — para padres: hitos de
  desarrollo, vacunas, primer diente, primera palabra, escuela,
  problemas de conducta, logros. Permanente por diseño.
- [ ] **Coaching de relaciones** — Axi puede:
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
- [ ] **Disclaimers de relaciones**: Axi NO es consejero matrimonial,
  NO es terapeuta de pareja, NO sustituye terapia familiar
  profesional. Las recomendaciones son generales — para problemas
  serios (abuso, infidelidad, divorcio en curso, custodia), recomendar
  profesional certificado.
- [ ] Tools nuevos: `relationship_add`, `relationship_event_log`,
  `relationship_advice` (que combina contexto + literatura + recursos),
  `family_member_add`, `child_milestone_log`.

### BI.10 — Espiritualidad (con o sin religión)

El usuario lo dijo perfecto: *"la espiritualidad va más allá de una
religión"*. Esta sub-fase reconoce que el bienestar espiritual es
transversal — algunas personas lo viven como fe religiosa, otras como
meditación, otras como contacto con la naturaleza, otras como sentido
de propósito secular.

- [ ] Side-table `spiritual_practices` — prácticas que el usuario
  realiza (meditación, oración, lectura espiritual, naturaleza,
  yoga, journaling reflexivo, etc.) con frecuencia, duración,
  experiencia subjetiva. Tipo de práctica es texto libre — Axi no
  juzga si es religiosa, agnóstica, atea, secular.
- [ ] Side-table `spiritual_reflections` — entradas narrativas sobre
  preguntas existenciales, sentido de vida, valores, propósito, dudas
  espirituales. Cifrado reforzado opcional (mismo modelo que mental).
- [ ] Side-table `values_compass` — los 5-10 valores fundamentales
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
- [ ] Tools: `spiritual_practice_log`, `reflection_add`,
  `values_define`, `meaning_check_in`.

### BI.11 — Salud financiera

La salud financiera es **fuente número 1 de estrés** según múltiples
estudios — y afecta directamente todas las demás dimensiones (física
por estrés, mental por ansiedad, relacional por conflictos de pareja,
etc.). LifeOS la trata como wellness, no como contabilidad.

- [ ] Side-table `financial_accounts` — cuentas del usuario (banco,
  efectivo, inversiones, deudas) sin saldos automáticos — el usuario
  los registra cuando quiere. **No nos conectamos a bancos vía API en
  V1** (eso es un proyecto separado, requiere certificación PCI-DSS,
  no nos vamos por ahí).
- [ ] Side-table `expenses` — registro libre de gastos: monto,
  categoría, fecha, notas. Puede ser foto del ticket → vision LLM
  extrae texto → confirmación del usuario.
- [ ] Side-table `income_log` — fuentes de ingreso recurrente o
  ocasional.
- [ ] Side-table `financial_goals` — metas (ahorrar X para Y,
  pagar deuda Z para fecha W).
- [ ] **Coaching financiero general**: Axi puede explicar conceptos
  básicos (qué es una tasa de interés, cómo funciona el interés
  compuesto, qué es un fondo de emergencia, cómo priorizar deudas),
  recomendar lecturas (Ramit Sethi, Bogleheads para inversión pasiva,
  literatura básica de finanzas personales en español).
- [ ] **NO es asesor financiero**. NO recomienda inversiones
  específicas. NO predice mercados. NO maneja dinero del usuario.
  Es un compañero de reflexión y registro.
- [ ] **Alertas suaves**: si el usuario registra gastos que parecen
  desproporcionados a su ingreso, o si lleva 3 meses sin ahorrar
  cuando dijo que quería, Axi pregunta — sin juzgar.
- [ ] Tools: `expense_log`, `income_log`, `financial_goal_add`,
  `financial_summary` (gastos por categoría, neto del mes, progreso
  hacia metas).

### BI.12 — Salud sexual e íntima

Categoría sensible que combina salud física, salud mental y salud
relacional. Trato similar a mental health en cuanto a salvaguardas.

- [ ] Side-table `sexual_health` — chequeos médicos relacionados,
  ITS (negativo/positivo + tratamiento si aplica), métodos
  anticonceptivos actuales, alergias a látex/lubricantes, etc.
  **Cifrado reforzado** con la misma passphrase que mental.
- [ ] Side-table `intimacy_log` — opcional, opt-in: el usuario puede
  registrar frecuencia, calidad subjetiva, satisfacción en pareja,
  cambios en libido, dudas. Útil para detectar patrones (ej. caída
  de libido correlacionada con depresión, medicamentos, estrés).
  Cifrado reforzado.
- [ ] **Educación sin tabú**: Axi responde preguntas de salud sexual
  con información médicamente correcta, sin juzgar, sin moralizar.
- [ ] **Detección de violencia sexual**: si el usuario describe algo
  que parece abuso, Axi responde con empatía + recursos (Línea
  Mujeres en CDMX 800 1084, locatel.cdmx.gob.mx). Sin diagnosticar
  ni presionar.
- [ ] **Jamás sale del dispositivo. Modo pánico activo. NO sync.**
- [ ] Tools: `sexual_health_log`, `intimacy_log_add`,
  `contraception_track`.

### BI.13 — Salud social y comunitaria

Más allá del círculo íntimo — sentido de pertenencia, contribución,
ciudadanía, voluntariado. Hay literatura robusta (Putnam "Bowling
Alone", Robert Waldinger del Harvard Study of Adult Development) que
muestra que las relaciones de comunidad amplia son tan importantes
para la longevidad como el ejercicio.

- [ ] Side-table `community_activities` — pertenencia a grupos
  (deportivos, religiosos, voluntariado, hobbies, profesionales),
  participación, frecuencia.
- [ ] Side-table `civic_engagement` — votaciones, voluntariado,
  donaciones, participación cívica.
- [ ] Side-table `contribution_log` — momentos donde el usuario
  ayudó a alguien o a una causa. La gratitud por contribuir está
  ligada al bienestar de larga vida.
- [ ] **Sugerencias proactivas**: si Axi nota que el usuario no ha
  participado en ninguna actividad comunitaria en N meses, puede
  preguntar gentilmente "¿extrañas estar en [grupo]?".
- [ ] Tools: `community_log`, `contribution_add`.

### BI.14 — Sueño profundo

El sueño aparece tangencialmente en `health_vitals` (sleep_hours),
pero merece su propia sub-fase porque es una de las palancas más
poderosas para todas las demás dimensiones.

- [ ] Side-table `sleep_log` — entradas con: hora de dormir, hora de
  despertar, calidad subjetiva (1-10), interrupciones, sueños
  relevantes, cómo te sientes al despertar.
- [ ] Side-table `sleep_environment` — temperatura del cuarto,
  oscuridad, ruido, dispositivos, café/alcohol previo, ejercicio,
  cena pesada o ligera.
- [ ] **Detección de patrones cruzados**: Axi puede notar
  correlaciones entre sueño y otras dimensiones (ánimo, glucosa,
  ejercicio, productividad reportada, etc.).
- [ ] **Coaching de higiene del sueño**: prácticas básicas
  (oscuridad, frescura, no pantallas antes de dormir, horario
  consistente) — bien establecidas en literatura, no controversiales.
- [ ] **NO diagnostica trastornos del sueño**. Si el usuario reporta
  insomnio crónico, ronquidos severos, apneas presenciales,
  somnolencia diurna excesiva — Axi recomienda ver a un especialista
  en medicina del sueño.
- [ ] Tools: `sleep_log_add`, `sleep_pattern_check`.

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
| Recordatorios programados | `calendar` + `scheduled_tasks` |
| Procesamiento de fotos | Vision pipeline existente (Qwen3.5-VL multimodal) |
| Procesamiento de voz | Wake word + STT + TTS pipeline |
| Conversación natural en español | Telegram bridge + agentic chat loop |
| Privacidad end-to-end | Encrypted at rest, never sent to cloud |
| Tools system para capacidades nuevas | 84 tools actuales + extensible |
| Dashboard UI | Web dashboard ya existe, fácil agregar tabs |

Lo único que falta agregar es:
1. Side-tables nuevas en `memory.db` (BI.2-BI.7).
2. Tools nuevos en `telegram_tools.rs` (10-15 herramientas adicionales).
3. Pipeline de ingest foto/voz para nutrición (reusa lo que ya tenemos).
4. Lógica de coaching unificada (BI.8 — la cereza del pastel).

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
- Sprint 1 (BI.1) listo para empezar cuando el usuario diga.
- Posición en `unified-strategy.md`: **Fases Consecutivas Próximas**
  (no es visión futura — es trabajo concreto).
