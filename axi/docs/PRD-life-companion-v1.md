# PRD — LifeOS / Axi · Life Companion (v1)

> **Authored**: 2026-05-20
> **Owner**: Héctor Martínez
> **Status**: DRAFT — awaiting Héctor's review and phase greenlight
> **Supersedes**: extends [PRD-NEXT.md](./PRD-NEXT.md) (which focused on stability/tuning). This PRD is the **next big leap** in product scope.

---

## 0. TL;DR

Axi today is a competent local AI assistant: voice, vision, chat, translator, meetings. It remembers what you tell it, but only loosely, and only as flat text.

The leap this PRD describes is turning Axi into a **life companion** that:

1. **Persists structured knowledge** about Héctor's life across 6 explicit domains (health, finance, relationships, exercise, spirituality, learning) plus a generic catch-all (events/personal).
2. **Relates that knowledge in a graph**, so a question in one domain can pull context from others ("can I buy a phone?" → finance + mood + past-impulsivity pattern).
3. **Acts proactively** via scheduled tasks and **push notifications to Héctor's installed PWA** ("guarda reposo, te enfermaste en estas fechas el año pasado").
4. **Stays 100% local-first** — health, finances, and relationships never leave the laptop.

Everything still runs on the existing stack (Qwen3.6 35B-A3B brain, engram memory, FastAPI dashboard, voice daemon). No re-platforming. This is **strategic accretion**, not a rewrite.

---

## 1. Vision (the "why")

Héctor's pitch:

> *"Si te pregunto si me puedo comprar un nuevo celular en el hotsale, vos podés revisar tanto mi estado de ánimo, mis finanzas, y poder decirme si puedo o no... y dentro de 2 o 3 meses, Axi recordará esa misma conversación y mi estado de ánimo, y podrá decidir nuevamente con mis finanzas actuales... Axi nunca olvida."*

The product premise has three legs:

1. **Continuity of context.** Most AI assistants forget. Axi must remember structured facts (with timestamps, sources, and links between them) for years.
2. **Cross-domain reasoning.** A purchase decision pulls finance + mood + history. A health recommendation pulls past episodes + current symptoms + season + activity. The graph is the nervous system that makes this work.
3. **Local trust.** Health, finances, relationships — the most leverage comes from being honest with the system. Honesty requires the data never leaves the machine. This is non-negotiable.

The product is "plenitud" — a fuller life — supported by a system that knows enough about you to give advice that is **actually personalized**, not generic.

---

## 2. Concrete user scenarios (Héctor's own examples + extrapolation)

### S1 — Purchase consultation with cross-domain check
**Héctor**: *"¿Puedo comprar un celular nuevo en el hot sale?"*
**Axi** *(internal)*: pulls last 30 days of finance snapshots, last 14 days of mood notes, last 12 months of impulse-vs-planned purchase ratio, current emergency-fund target.
**Axi** *(reply)*: *"Tus gastos del mes están 22% arriba del promedio, el fondo de emergencia está abajo del piso que acordamos en marzo, y en los últimos 6 meses 4 de 6 compras grandes las marcaste como 'impulsivas' al revisarlas a la semana siguiente. Yo esperaría a junio cuando entre el bono. ¿Querés que te recuerde el 5 de junio?"*

### S2 — Recurring health pattern detection
**Héctor** *(15 nov 2026)*: *"Me duele la garganta."*
**Axi**: *"En dic 2025 y dic 2024 también te enfermaste. En 2025 fue después de la fiesta del 18; el médico te recetó X por Y días. ¿Querés que te programe recordatorios de vitamina C esta semana y agende salir temprano del trabajo viernes y sábado?"*

### S3 — Relationship coaching with longitudinal context
**Héctor**: *"Tuve un problema con mi esposa, no sé qué hacer."*
**Axi**: pulls patterns from past entries — what worked, what escalated, his emotional baseline, recurring topics.
**Axi**: *"La última vez que tuvieron una pelea por el tema-X (marzo), lo que destrabó fue Y. Pero también noté que las últimas 3 discusiones empezaron los domingos por la noche cuando vos dormiste menos de 6 horas. Esta semana dormiste un promedio de 5.4h. ¿Querés que te ayude a pensar primero antes de responder, o querés desahogarte?"*

### S4 — Proactive desk-health nudges
**Axi** *(push notification, 14:30)*: *"Llevás 2h45min sin parar de la silla. La cámara muestra que estás tenso en los hombros (lo detecté otras 3 veces esta semana). Hacé el estiramiento de 90 segundos que te funcionó en abril."*

### S5 — Spiritual/values check-in
**Héctor**: *"Me siento como en piloto automático."*
**Axi**: *"En tu última reflexión semanal (12 mayo) escribiste que querías invertir más tiempo en X. Esta semana le diste 30 minutos. ¿Querés bloquear una hora este sábado, o repensar la meta?"*

These scenarios are **non-trivial because no single LLM call can produce them**. They require: structured memory, scheduled scans, cross-domain queries, and a decision engine that knows when to act vs. answer.

---

## 3. What we already have (the foundation — do NOT rebuild)

| Capability | Status today | Reuse for this PRD |
|---|---|---|
| Local brain (Qwen3.6 35B-A3B + vision) | ✅ Running on 8 GB VRAM, --cpu-moe MoE on 12 GB laptop | All reasoning |
| Engram persistent memory | ✅ Cross-session, search, observation links | **Generic "things Axi remembers"** — keep using for free-form notes |
| ConversationMemory (SQLite + FTS) | ✅ Last-N chats, persisted | Chat history, dialog context |
| Voice daemon (Whisper + intents) | ✅ Meta+Space, Axi-prefix commands | Voice input for all domains |
| Vision (camera + screen) | ✅ Capture on demand | S4 desk-health (posture, screen-stress) |
| Meeting recorder + diarization V1 | ✅ Pyannote 4.0.4 configured | Reflection journals, family conversations (with consent) |
| Translator | ✅ EN→ES live | Out of scope for this PRD |
| Dashboard (FastAPI + Alpine + PWA) | ✅ HTTPS, mobile-installed | UI for all new features |
| PWA installed on Pixel via VPN | ✅ Standalone-app feel | **Notification target** (S2, S4) |
| `brain.py` auto-retry on reasoning-eaten budget | ✅ Just shipped | Cross-domain prompts will be long → safety net is critical |

**Implication**: we don't need new infrastructure for chat, voice, or the brain. The new pieces are: **structured domain stores, a graph layer, a scheduler, a push subsystem, and a decision-engine prompt layer**.

---

## 4. Domain model

### 4.1 The 6 + 1 domains

| Domain | What lives here | Example entries |
|---|---|---|
| **health** | Symptoms, diagnoses, medications, lab results, vitals (glucose, BP, weight), sleep, energy levels | "5/15 dolor de garganta, dr. recetó amox 500mg x7d", "glucosa ayunas 92 mg/dL" |
| **finance** | Income, expenses (categorized), savings, debt, big purchases (with "impulsive vs planned" tag), recurring commitments | "comida fuera 850 MXN", "transferencia ahorros 2000", "compra impulsiva: auriculares" |
| **relationships** | People-graph (esposa, hijos, padres, amigos, colegas), interactions, conflicts, resolutions, recurring patterns, emotional baseline | "Pelea con Y por tema-X, se destrabó hablando de Z", "llamé a mi mamá, le conté A" |
| **exercise** | Sessions (type, duration, intensity, mood pre/post), routines, injuries, goals | "Caminé 35min al sol, energía 7/10 → 8/10", "gym empuje 45min" |
| **spirituality** | Reflections, values, gratitude, meditations, weekly retrospectives, personal questions Héctor is sitting with | "Reflexión semanal: querer X sin sentirme atado", "5 cosas que agradezco hoy" |
| **learning** | Books, courses, ideas being explored, "to-think-about" list | "Empecé libro Y, capítulo 1: idea principal Z", "investigar tema W" |
| **events** *(catch-all)* | Anything that doesn't fit cleanly: travels, parties, milestones, dates that matter | "Boda de A el 12/jun", "Cumple papá 8/jun" |

### 4.2 Common entry shape

Every entry across all domains shares this shape (variations live in `data` blob):

```python
{
  "id": "ulid",
  "domain": "health" | "finance" | ...,
  "subtype": "symptom" | "expense" | "interaction" | ...,
  "timestamp": "2026-05-20T22:14:00-06:00",  # always TZ-aware
  "title": "short description",
  "body": "free-form text (optional)",
  "data": { ... domain-specific structured fields ... },
  "tags": ["impulsive", "recurring", ...],
  "source": "chat" | "voice" | "manual" | "scan" | "import",
  "confidence": 0.0–1.0,  # for AI-extracted fields
  "embedding": [...],  # for semantic search
  "links": [ {"target_id": "ulid", "rel": "caused-by"} ... ]
}
```

The **links field is the graph edge**. Relations have a controlled vocabulary (`caused-by`, `mentions-person`, `resolved-by`, `pattern-of`, `precedes`, `triggered-by`, `same-event`, `funded`, `costs`, …) so the decision engine can traverse them with semantics, not full-text guesses.

### 4.3 People graph (separate, because people are first-class)

`relationships.people` table:
- `id`, `name`, `role` ("esposa", "papá", "jefe", "amigo cercano"), `since`, `notes`.
- Linked-to from any entry via `mentions-person` edges.

This lets queries like "muéstrame todas las interacciones con mi esposa en los últimos 6 meses" be a single graph traversal.

---

## 5. Architecture

```
                        ┌─────────────────────────────┐
                        │   Héctor (chat / voice /    │
                        │   PWA notification reply)   │
                        └──────────────┬──────────────┘
                                       │
                          ┌────────────▼────────────┐
                          │      Dashboard /        │  ←─ existing
                          │     Voice Daemon        │
                          └────────────┬────────────┘
                                       │
                      ┌────────────────▼────────────────┐
                      │      Decision Engine            │  ← NEW
                      │  (prompt layer on top of brain) │
                      └────┬────────────────────────┬───┘
                           │                        │
                           ▼                        ▼
              ┌────────────────────┐    ┌──────────────────────┐
              │  Brain (Qwen 35B)  │    │   Cross-Domain Query │  ← NEW
              │   + brain.py       │    │   (graph traversal)  │
              └────────────────────┘    └──────────┬───────────┘
                                                   │
                          ┌────────────────────────┼───────────────────┐
                          ▼                        ▼                   ▼
              ┌────────────────────┐  ┌──────────────────┐  ┌──────────────────┐
              │ Domain Stores      │  │   Graph Edges    │  │  Engram (notes,  │
              │ (SQLite per dom.)  │  │  (SQLite, FK to  │  │  decisions hist.)│
              │  + embedding idx   │  │  domain entries) │  │   ← already here │
              └────────────────────┘  └──────────────────┘  └──────────────────┘
                          ▲
                          │
              ┌───────────┴─────────────────────────┐
              │ Ingestion paths:                     │
              │  • chat-parsed (auto-extracted)      │
              │  • voice-parsed (intent-classified)  │
              │  • manual entry (dashboard form)     │
              │  • scheduled scan (vision/cam pose)  │
              └──────────────────────────────────────┘

         ┌──────────────────────────────────────────┐
         │    Scheduler (cron + on-demand)          │  ← NEW
         │  - reminders ("buy phone in june")        │
         │  - scans   ("posture check every 20min")  │
         │  - digests ("weekly reflection sun 21:00")│
         └──────────────────────────┬───────────────┘
                                    │ emits
                                    ▼
                         ┌────────────────────┐
                         │   Push Service     │  ← NEW
                         │  (VAPID Web Push   │
                         │  to PWA on Pixel)  │
                         └────────────────────┘
```

### 5.1 New components

| Component | Tech | Why |
|---|---|---|
| **Domain stores** | SQLite per domain (or one DB with domain column — TBD in design phase) + `sqlite-vss` for embeddings | Keep schema strict per domain, but uniform query interface |
| **Graph edges** | SQLite table `edges(src_id, rel, dst_id, weight, created_at)` | Simple, queryable, joins to any domain |
| **Decision engine** | Python module `lifeos.decide` — composes prompts that include relevant graph slices | LLM does the reasoning; we do the retrieval |
| **Scheduler** | `apscheduler` (Python, in-process inside dashboard service) | No new daemon, no systemd timer sprawl |
| **Push service** | Web Push (RFC 8030) with VAPID, `pywebpush` lib, service worker on PWA | The PWA is already on Hector's phone via VPN; this is the natural channel |
| **Ingestion classifier** | Extension of `intents.py` — recognizes "domain-relevant" phrases and routes to the right store | Reuses the regex-first pattern already there |

### 5.2 Data flow examples

**S1 — "puedo comprar un celular?":**
1. Voice/chat → intent classifier → "decision-query, domain hint: finance"
2. Decision engine pulls: last 30d finance entries, last 14d mood entries, "purchase" history with `impulsive` tag, current savings target.
3. Graph traversal: edges of type `precedes-regret` from past purchases.
4. Composed prompt → brain (with the auto-retry safety net) → answer + optional `schedule-reminder` action.

**S2 — "me duele la garganta":**
1. Voice → intent → "symptom report, domain: health"
2. Auto-create `health/symptom` entry.
3. Scheduled scan: "does this match a historical pattern?" → finds Dec 2024, Dec 2025 entries with similar symptoms.
4. Decision engine composes: symptom + historical context + season + recent calendar (was at fiesta last weekend?).
5. Brain responds + scheduler is asked to set "vitamin C reminders this week" if Héctor agrees.

### 5.3 Security & privacy posture

- **Local-only**: all stores live in `~/.local/state/lifeos/` (chmod 700). Nothing crosses network except the existing model-download path.
- **Encryption at rest**: SQLite + `sqlcipher` for the three sensitive domains (health, finance, relationships). Passphrase derived from keyring (libsecret/kwallet) on user login.
- **No cloud sync, ever** in v1. Backup is local-disk snapshot (existing CachyOS snapshot strategy works).
- **PWA push payloads** carry titles only; full content is fetched from the dashboard *after* the user taps. Push payloads never include sensitive specifics ("Recordatorio salud" not "Tomar X mg de Y").
- **Vision/audio passive capture is OPT-IN** per scan type. The "desk-health" scenario (S4) requires Héctor explicitly enabling it. No always-on capture without consent toggles in the dashboard.
- **Right-to-forget**: every entry has a delete path; tombstones propagate to edges.

---

## 6. Phased rollout

The full vision is **6-9 months of focused work** if done correctly. The phases below are sized so each one ships a demoable, valuable slice **on its own** — none requires the next to be useful.

### **P0 — Foundation [✅ ALREADY DONE]**
Brain, memory, chat, voice, dashboard, PWA on phone, HTTPS, model selector. **This is where we are right now.**

### **P1 — Notifications + Reminders MVP (the first slice)** ← **next**
**Goal**: Héctor can tell Axi "recordame X el martes a las 9" and gets a push notification on his phone.

Scope:
- Scheduler service (apscheduler embedded in dashboard).
- Web Push subsystem (VAPID keys generated on first run, stored in keyring, service worker updated in PWA).
- New chat intent: `schedule-reminder`.
- Dashboard page `/reminders` to list, edit, delete pending reminders.
- One smoke test: chat "recordame X el martes a las 9" → entry appears → at trigger time → push arrives on Pixel.

Estimated: 1-2 focused sessions. **Does not touch any sensitive domain schema** — that's the next phase. Reminders are stored in a single generic `lifeos.reminders` table.

### **P2 — Health domain MVP**
**Goal**: Capture symptoms, meds, vitals from chat or voice. Search by date or pattern. No graph yet — flat structured store.

Scope: schema, ingestion classifier, dashboard page `/health` with timeline + manual entry form, encrypted store, daily/weekly digest hook.

### **P3 — Finance domain MVP**
**Goal**: Same as P2 for finance. Add the "impulsive vs planned" tagging UX (one-week-later prompt: "¿La compra de X fue impulsiva o planeada?" via push).

Scope: schema, classifier, dashboard page, encrypted store, **one cross-domain edge type**: `health-affected-by-finance` (e.g. "no podemos comer fuera este mes" → mood entry).

### **P4 — Graph + Decision Engine v1**
**Goal**: The first cross-domain query works. Scenario S1 ("puedo comprar un celular?") executes end-to-end.

Scope: edges schema, traversal API, the `lifeos.decide` prompt composer, two real use cases shipped (purchase consult + symptom-history check).

### **P5 — Relationships + Exercise + Spirituality + Learning + Events**
**Goal**: All remaining domains. The graph gets dense.

Scope: incremental — each domain as a sub-task. Most schemas mirror P2/P3.

### **P6 — Proactive scans + multimodal**
**Goal**: S4 (posture nudges via camera) and the seasonal pattern detector (S2's predictive side).

Scope: scheduled vision scans (opt-in), pattern matchers (Dec→Dec illness comparison, sleep-mood correlation, etc.), reflection prompts on cadence.

---

## 7. P1 — first slice, detailed scope

This is what we build **first**. Everything else stays in the PRD as "next."

### 7.1 User story

> *Héctor le dice a Axi (chat o voz): "Recordame el martes a las 9 de la mañana llamar al dentista." A las 9:00 del martes, la PWA en su Pixel hace ring/vibrar con el mensaje "Recordatorio: llamar al dentista." Si Héctor toca la notificación, abre Axi en el reminder; si la ignora, queda marcado como "pendiente" en /reminders.*

### 7.2 Components to build

| Piece | File / location | Effort |
|---|---|---|
| `lifeos.scheduler` module (apscheduler wrapper) | `lifeos/scheduler.py` (new) | M |
| `lifeos.reminders` SQLite table + DAO | `lifeos/reminders.py` (new) | S |
| Push subsystem: VAPID gen, subscription endpoint, push sender | `lifeos/push.py` (new) | M |
| Service worker push handler | `axi/static/sw.js` (extend existing) | S |
| Intent: `schedule-reminder` (parse natural-language datetime) | `axi/intents.py` (extend) | M |
| Dashboard page `/reminders` | `axi/templates/reminders.html` (new) + handlers | M |
| Smoke test | `tests/test_reminders_e2e.py` (new) | S |

S = small (under an hour), M = medium (1–3 hours).

### 7.3 Open design questions for P1

These need Héctor's input or a design decision before implementation starts:

1. **Natural-language date parsing**: use `dateparser` lib (handles Spanish well), or use the brain to extract the datetime? → *Recommendation*: dateparser first, brain as fallback when dateparser fails. Faster, more deterministic.
2. **Push channel auth**: VAPID keys per-install or per-user? → *Recommendation*: per-install (single user system). One keypair stored in keyring.
3. **What happens on missed pushes** (phone offline, laptop sleeping when trigger fires)? → *Recommendation*: store the trigger event, push when laptop wakes; if phone was offline, the FCM/APNS layer queues for ~28 days standard.
4. **Snooze / dismiss UX**: → *Recommendation*: keep it minimal in P1 — tap = mark done, swipe = snooze 30min. Power-user options come in P2.

### 7.4 Definition of done for P1

- [ ] `POST /api/reminders` accepts `{when: ISO8601 or NL string, message, channel: "push"}`
- [ ] Reminders persist across dashboard restarts (apscheduler with SQLAlchemy jobstore).
- [ ] One reminder set via chat fires within ±5 seconds of scheduled time.
- [ ] Push notification appears on installed PWA (Pixel).
- [ ] `/reminders` page shows pending + recently fired (last 30 days).
- [ ] Smoke test green: `python -m pytest tests/test_reminders_e2e.py`.
- [ ] No regression on existing chat / voice / translate.

---

## 8. Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Schema decisions in P2-P5 prove wrong after months of data | M | H | Each domain ships with versioned schema + migration helper from day 1. No "we'll add versioning later." |
| LLM hallucinates "facts" into structured stores | H | H | Ingestion classifier writes to `pending` table first; weekly review prompt asks Héctor to confirm/correct. Confidence < 0.7 → always confirm. |
| Encryption passphrase loss = data loss | M | H | Recovery key printed at first run, Héctor stores in 1Password/written note. Backup snapshot also encrypted but with a separate recovery passphrase. |
| Push payload leaks sensitive info to OS notification shade | M | M | Titles only on push; details only after auth in app. (Designed in from P1.) |
| Cross-domain prompts blow context window | M | M | Decision engine slices: top-K relevant entries per domain (configurable), summaries for older history. Already have `brain.py` retry net. |
| User burnout: too many prompts → uninstall | M | H | Notification budget per day (default 5, configurable). Reflection prompts opt-in. UI shows pending nudges, doesn't push them all. |
| Vision/audio always-on creeps in by accident | L | H | Hard "passive capture" toggle in `/config` defaulting OFF. Logged every time it fires. |

---

## 9. Open questions for Héctor — **✅ RESOLVED (2026-05-22)**

> Las 6 questions fueron auditadas y cerradas el 2026-05-22. Todas resueltas a favor de la opción que el PRD recomendaba, todas shippeadas con commits trazables. Confirmación de Héctor + memoria de decisión #189 (`lifeos/prd-v1/open-questions`). Esta sección se conserva como histórico — no abrir nuevas decisiones acá; abrir un follow-up nuevo si algo se rompe.

1. **NL parsing approach for reminders**: ¿`dateparser` (rápido, determinístico) o brain (más flexible pero más lento y menos predecible)? Yo voto dateparser primero, brain como fallback.
   - **✅ RESOLVED**: `dateparser` fast-path (~180ms) + brain fallback wireado en commit `796bc01`. Ver memoria #184 (`brain fallback into LifeOS reminder parser`).
2. **Encryption scope for v1**: ¿`sqlcipher` desde el día uno en P2 (más fricción, más seguro), o SQLite plano detrás de chmod 700 con migración a sqlcipher en P4? Yo voto **sqlcipher desde día uno** — migrar después es siempre más costoso.
   - **✅ RESOLVED**: sqlcipher en TODOS los stores. Commits: health `b1b6449`, finance `d0f2a0b`, lifeos core `791442b`, y cada dominio (relationships/exercise/spirituality/learning/events) con key independiente.
3. **Notification budget default**: ¿cuántas notificaciones por día tope antes de empezar a deduplicar / suprimir? Sugerencia: 5/día, configurable en `/config`.
   - **✅ RESOLVED**: cap diario 5 (ambient) + dedup sha256[:16] window 1h + soft coalescing. Commit `d780bac`.
4. **Voice trigger for the new domains**: ¿usamos el prefijo existente `Axi, ...` o agregamos verbos específicos (`Axi, gasté...`, `Axi, comí...`)? Yo voto: mantener `Axi, ...` y dejar que el intent classifier rute. Menos sintaxis que recordar.
   - **✅ RESOLVED**: prefijo único `Axi, ...` con ruteo por intent. Pipeline de voz validado en prod 2026-05-22 (reminder `01KS8DGA78Z9P7C959SFGHW6VJ`, latencia ~2.3s end-to-end).
5. **Confirmación de ingestión automática**: cuando Axi auto-clasifica "me duele la garganta" como `health/symptom`, ¿lo guarda silencioso y te muestra un "confirmá" al final del día, o te pregunta en el momento? Yo voto: **silencioso + daily-review push a las 21:00** para no romper el flow.
   - **✅ RESOLVED con matiz aceptado por Héctor**: silent persistence + brief ack inline (`dashboard.py:2275-2277`) + insights digest cron @ 21:00 (P6.1). Difiere del PRD original (no es una "lista plana de confirmá X, confirmá Y") — el digest entrega **patrones detectados**, cumpliendo el espíritu (silent + review diario) con más valor. Si en uso real falta capacidad de corregir clasificaciones, abrir follow-up nuevo.
6. **Repo layout**: ¿el nuevo código vive en `lifeos/lifeos/` (nuevo paquete hermano de `axi/`) o como sub-módulo dentro de `axi/`? Yo voto: **paquete hermano `lifeos/`** — la visión es que axi es el agente, y lifeos es el sistema de vida del que axi es la cara conversacional. Ya está implícito en la metáfora del repo.
   - **✅ RESOLVED**: paquete hermano en `/home/hectormr/LifeOS/lifeos/{axi,lifeos}/`. Restructura completada en memorias #148-#150. Hoy axi declara lifeos como path-dep editable en su pyproject (ver memoria #195).

---

## 10. Out of scope for v1 (explicit)

- **Multi-user**: sigue siendo single-user, no auth.
- **Cloud sync, backup remoto, sharing**: nunca en v1.
- **Mobile-only mode** (sin laptop): la PWA es cliente, el cerebro vive en la laptop.
- **Integraciones con apps externas** (Apple Health, Google Fit, banca): ingesta manual o auto-extraída por chat. Importadores opcionales en v2.
- **Multi-idioma full**: español es first-class. Inglés funciona como hoy (modelo bilingüe), pero las plantillas y UX prompts están en español.
- **Sustitución del médico, del contador, o del terapeuta**: Axi recomienda y persiste contexto. Decisiones críticas las toma Héctor con profesionales humanos. Esto debe quedar explícito en los prompts del sistema.

---

## 11. Success metrics (how we'll know v1 is working)

- **P1 specific**: Héctor programa al menos 3 reminders en la primera semana y ninguno falla. NPS subjetivo: "¿confiarías en que llegue?" — sí.
- **P4 specific (decision engine)**: la primera consulta cruzada (S1) devuelve una recomendación que Héctor reportea como "razonable" en blind review (sin haberle dicho qué pulled from cuál dominio).
- **Volumétrico**: a los 3 meses post-P5, los 6 dominios tienen ≥20 entries cada uno (señal de uso real, no demo).
- **Trust**: Héctor reporta que **no le miente al sistema** — el indicador real de que la promesa "local = honestidad" se cumple.

---

## 12. Next concrete action

Cuando Héctor lea este PRD y dé greenlight (con tachones si quiere), arrancamos:

```
/sdd-new lifeos-p1-reminders
```

Eso dispara la fase exploration → proposal → spec → design → tasks → apply para **P1 únicamente**. Una rebanada chica que se puede shipear en una o dos sesiones, sin tocar nada sensible, y que entrega valor inmediato (las notificaciones funcionando en el celular).

Las fases P2 en adelante se planifican **después de ver P1 en producción al menos 1 semana**. Ese delay es a propósito — la realidad del uso siempre cambia las prioridades del diseño.

---

*Fin del PRD. Decisiones pendientes están en §9. Cuando despiertes, leelo, marcá lo que querés cambiar, y desde ahí seguimos.*
