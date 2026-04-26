# PRD — Freelance Domain (LifeOS Life Areas v1)

**Status**: Approved 2026-04-26
**Owner**: Hector (LifeOS)
**Implementation target**: Sprint immediately following Sprint 3+4 memory remediation

---

## 1. Why this exists

LifeOS positioning: **personal AI OS where Axi is the co-pilot of YOUR life**, distinct
from autonomous-builder agents like OpenClaw/Hermes. The killer feature is **structured
domain knowledge that Axi never forgets** — combined with cross-domain reasoning.

Today, LifeOS already has structured domains for: health (vitals, medications,
mental_health), nutrition, sleep, mood, relationships, finance (basic), habits, books,
exercise, spiritual, sexual_health. These ship as `memory_plane.rs` tables with
companion `axi_tools.rs` LLM tool functions.

**The Freelance domain is missing**, and it is the single highest-value missing domain
for the primary user (Hector) — it's the one his livelihood depends on. Without
structured Freelance data, Axi cannot answer the questions that matter most:

- "¿Puedo tomar otro cliente esta semana?" (capacity)
- "¿Cuánto facturé este mes?" (revenue)
- "¿Cuánto le cobramos a este cliente la última vez?" (rate continuity)
- "¿Qué clientes me deben?" (collections)
- "¿Estoy siendo rentable este trimestre?" (profitability)
- "¿Tengo bandwidth para meter este proyecto sin sobrecargarme dado mi presión arterial reciente?" (cross-domain — depends on health domain too)

This PRD scopes the **first complete domain implementation** that establishes the
**TEMPLATE pattern** all other future domains (Travel, Projects, Privacy/Personal, etc.)
will replicate.

## 2. Out of scope (explicitly NOT in v1)

- Cross-domain reasoning engine (separate future PRD — requires this domain to exist first)
- Frontier-LLM integration for complex synthesis (that's a Privacy Mode toggle question)
- Invoice PDF generation (just track that an invoice was issued, not produce the PDF)
- Tax integration / SAT facturación (separate concern, México-specific, off-roadmap)
- Time-tracking active timer (user logs sessions after the fact; no Pomodoro UI)
- Client-facing portal
- Bank reconciliation (just track payments-received as user reports them)

## 3. Personas & primary user stories

### Persona: Hector (freelance dev, primary LifeOS user)

**US-1**: As Hector, I tell Axi "agregá un cliente nuevo, Acme Corp, $500/hora, 20
horas comprometidas/mes empezando 1 mayo" → cliente persisted, queryable, included
in future capacity calculations.

**US-2**: As Hector, after working a session I tell Axi "trabajé 3 horas hoy con
Acme Corp en revisión del backend" → session_log entry created with date, hours,
client, description.

**US-3**: As Hector at the end of the month I ask Axi "¿cuántas horas trabajé este
mes y a quién facturé?" → Axi returns structured summary by client.

**US-4**: As Hector, I ask "¿puedo meter otro cliente?" → Axi consults committed
hours, current month load, returns "tenés 12 horas libres esta semana, 35 al mes
— sí podés tomar uno chico". (Cross-domain extension: also flags health if relevant.)

**US-5**: As Hector, when I emit an invoice I tell Axi "facturé $5000 a Acme por
abril, fecha vencimiento 15 mayo" → invoice tracked, due-date watched, alerta
proactiva si está vencida.

**US-6**: As Hector, I open the LifeOS dashboard and see a Freelance tab with:
clientes activos, facturación del mes, cuentas por cobrar, horas comprometidas
vs trabajadas.

**US-7**: As Hector, Axi me alerta proactivamente cuando: (a) un cliente excede
el % comprometido del mes, (b) una factura está vencida, (c) la facturación del
mes va por debajo del threshold de rentabilidad mínima.

## 4. Data schemas (SQLite — added to `memory.db`)

All tables live in the SAME memory.db file, under the same encryption key, following
the existing pattern in `memory_plane.rs`.

### 4.1 `freelance_clientes`

```sql
CREATE TABLE IF NOT EXISTS freelance_clientes (
  cliente_id        TEXT PRIMARY KEY,           -- "cli-<uuid>"
  nombre            TEXT NOT NULL,              -- "Acme Corp"
  contacto_principal TEXT,                       -- "Juan Pérez"
  contacto_email    TEXT,
  contacto_telefono TEXT,
  rfc               TEXT,                        -- México fiscal
  tarifa_hora       REAL,                        -- pesos MXN; nullable for retainer-style
  modalidad         TEXT NOT NULL DEFAULT 'horas', -- 'horas' | 'retainer' | 'proyecto'
  retainer_mensual  REAL,                        -- if modalidad='retainer'
  horas_comprometidas_mes INTEGER,               -- target horas/mes; null if no target
  fecha_inicio      TEXT NOT NULL,               -- ISO date
  fecha_fin         TEXT,                        -- null = activo
  estado            TEXT NOT NULL DEFAULT 'activo', -- 'activo' | 'pausado' | 'terminado'
  notas             TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_freelance_clientes_estado ON freelance_clientes(estado);
CREATE INDEX IF NOT EXISTS idx_freelance_clientes_nombre ON freelance_clientes(nombre);
```

### 4.2 `freelance_sesiones`

```sql
CREATE TABLE IF NOT EXISTS freelance_sesiones (
  sesion_id      TEXT PRIMARY KEY,                -- "ses-<uuid>"
  cliente_id     TEXT NOT NULL,                   -- FK freelance_clientes
  fecha          TEXT NOT NULL,                   -- ISO date (no time)
  hora_inicio    TEXT,                            -- HH:MM optional
  hora_fin       TEXT,                            -- HH:MM optional
  horas          REAL NOT NULL,                   -- can be 0.5
  descripcion    TEXT,                            -- "revisión del backend"
  facturable     INTEGER NOT NULL DEFAULT 1,      -- 0 | 1
  factura_id     TEXT,                            -- nullable, FK if billed
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_freelance_sesiones_cliente ON freelance_sesiones(cliente_id, fecha);
CREATE INDEX IF NOT EXISTS idx_freelance_sesiones_fecha ON freelance_sesiones(fecha);
CREATE INDEX IF NOT EXISTS idx_freelance_sesiones_factura ON freelance_sesiones(factura_id);
```

### 4.3 `freelance_facturas`

```sql
CREATE TABLE IF NOT EXISTS freelance_facturas (
  factura_id        TEXT PRIMARY KEY,             -- "fac-<uuid>"
  cliente_id        TEXT NOT NULL,                -- FK
  numero_externo    TEXT,                         -- "INV-2026-001" if user has external numbering
  fecha_emision     TEXT NOT NULL,                -- ISO date
  fecha_vencimiento TEXT,                         -- when payment expected
  fecha_pago        TEXT,                         -- when actually paid (null = pending)
  monto_subtotal    REAL NOT NULL,                -- pre-tax
  monto_iva         REAL NOT NULL DEFAULT 0,
  monto_total       REAL NOT NULL,                -- subtotal + iva
  moneda            TEXT NOT NULL DEFAULT 'MXN',  -- ISO currency
  concepto          TEXT,                         -- "Trabajo abril 2026"
  estado            TEXT NOT NULL DEFAULT 'emitida', -- 'emitida' | 'pagada' | 'vencida' | 'cancelada'
  notas             TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_freelance_facturas_cliente ON freelance_facturas(cliente_id, fecha_emision);
CREATE INDEX IF NOT EXISTS idx_freelance_facturas_estado ON freelance_facturas(estado);
CREATE INDEX IF NOT EXISTS idx_freelance_facturas_vencimiento ON freelance_facturas(fecha_vencimiento);
```

### 4.4 `freelance_tarifas_history`

```sql
CREATE TABLE IF NOT EXISTS freelance_tarifas_history (
  cliente_id      TEXT NOT NULL,
  tarifa_anterior REAL,
  tarifa_nueva    REAL NOT NULL,
  fecha_cambio    TEXT NOT NULL,
  razon           TEXT,
  PRIMARY KEY (cliente_id, fecha_cambio)
);
```

Pattern matches existing `medications` history table — every rate change preserved.

### 4.5 Schema migration

New tables added via `initialize()` in `memory_plane.rs` using `CREATE TABLE IF NOT
EXISTS`. Idempotent; safe to apply on every startup. No data migration needed
(empty by default).

## 5. LLM tools (added to `axi_tools.rs`)

All tools follow the existing pattern (signature, error handling, system prompt
documentation entry). Each one emits structured JSON results that the LLM can use
in turn. All write tools log to the destructive-action audit log if a `confirm`
arg is required (none of these are destructive enough to require confirm by
default — except `cliente_delete`).

### 5.1 Cliente lifecycle

| Tool | Args | Returns |
|---|---|---|
| `cliente_add` | `{ nombre, tarifa_hora?, modalidad?, retainer_mensual?, horas_comprometidas_mes?, fecha_inicio?, contacto_email?, contacto_telefono?, rfc?, notas? }` | `{ cliente_id, ... }` |
| `cliente_list` | `{ estado?: 'activo'\|'pausado'\|'terminado' }` (default: `activo`) | `{ clientes: [...] }` |
| `cliente_get` | `{ cliente_id OR nombre }` | full cliente row |
| `cliente_update` | `{ cliente_id, ...partial fields }` | `{ updated_fields, cliente }` |
| `cliente_pause` | `{ cliente_id, razon? }` | `{ cliente_id }` |
| `cliente_resume` | `{ cliente_id }` | `{ cliente_id }` |
| `cliente_terminar` | `{ cliente_id, fecha_fin?, razon? }` | `{ cliente_id }` |
| `cliente_delete` | `{ cliente_id, confirm: true }` | hard delete (rare; archived tier preferred) |
| `tarifa_actualizar` | `{ cliente_id, tarifa_nueva, razon? }` | logs to history + updates cliente |

### 5.2 Sesiones

| Tool | Args | Returns |
|---|---|---|
| `sesion_log` | `{ cliente_id OR cliente_nombre, fecha?, horas, descripcion?, hora_inicio?, hora_fin?, facturable? }` | `{ sesion_id }` |
| `sesion_list` | `{ cliente_id?, desde?, hasta?, limit? }` | `{ sesiones: [...] }` |
| `sesion_update` | `{ sesion_id, ...partial }` | updated sesion |
| `sesion_delete` | `{ sesion_id }` | soft-delete (mark as deleted) |

### 5.3 Facturación

| Tool | Args | Returns |
|---|---|---|
| `factura_emit` | `{ cliente_id, monto_subtotal, monto_iva?, fecha_emision?, fecha_vencimiento?, concepto?, numero_externo?, sesion_ids?: string[] }` | `{ factura_id }` (links sesiones if provided) |
| `factura_pagar` | `{ factura_id, fecha_pago? }` | mark paid |
| `factura_cancelar` | `{ factura_id, razon? }` | cancela |
| `factura_list` | `{ cliente_id?, estado?, desde?, hasta? }` | `{ facturas: [...] }` |
| `facturas_pendientes` | `{ cliente_id? }` | only `emitida` and `vencida` |
| `facturas_vencidas` | (no args) | facturas where `fecha_vencimiento < today AND estado='emitida'` |

### 5.4 Análisis y consultas

| Tool | Args | Returns |
|---|---|---|
| `freelance_overview` | `{ mes?: 'YYYY-MM' }` (default: current) | `{ clientes_activos, horas_trabajadas, horas_comprometidas, facturacion_emitida, facturacion_pagada, cuentas_por_cobrar, alertas: [...] }` |
| `horas_libres` | `{ ventana?: 'semana'\|'mes' }` (default: `semana`) | `{ horas_comprometidas, horas_trabajadas, horas_disponibles, capacidad_pct }` |
| `cliente_estado` | `{ cliente_id OR cliente_nombre }` | `{ horas_mes_actual, vs_compromiso_pct, ultima_sesion, ultima_factura, monto_pendiente }` |
| `ingresos_periodo` | `{ desde, hasta, agrupado_por?: 'cliente'\|'mes' }` | aggregated revenue |
| `clientes_por_facturacion` | `{ desde?, hasta? }` | top clients by revenue contribution |

## 6. REST API endpoints (added to `daemon/src/api/`)

All under `/api/v1/freelance/` with `x-bootstrap-token` auth (existing middleware).

| Method | Path | Purpose |
|---|---|---|
| GET | `/clientes` | list (filter by `?estado=activo`) |
| POST | `/clientes` | create |
| GET | `/clientes/:id` | get one |
| PATCH | `/clientes/:id` | update partial |
| DELETE | `/clientes/:id?hard=true` | terminar (default soft) |
| GET | `/sesiones` | list (filter `?cliente_id=&desde=&hasta=`) |
| POST | `/sesiones` | log new |
| PATCH | `/sesiones/:id` | edit |
| DELETE | `/sesiones/:id` | soft-delete |
| GET | `/facturas` | list (filter `?cliente_id=&estado=`) |
| POST | `/facturas` | emit |
| PATCH | `/facturas/:id` | update (e.g., mark paid) |
| GET | `/overview?mes=YYYY-MM` | dashboard data |
| GET | `/horas-libres?ventana=semana` | capacity |

## 7. Dashboard UI (`daemon/static/dashboard/`)

New tab "Freelance" alongside existing tabs. Single-page-app (SPA) using existing
JS+CSS pattern (no framework added).

### 7.1 Sections

1. **Overview cards** (top of view):
   - Clientes activos (count, click → list view)
   - Horas trabajadas / comprometidas este mes (with progress bar, color: green if <85%, yellow 85-100%, red >100%)
   - Facturación emitida / pagada este mes
   - Cuentas por cobrar (count + total)

2. **Alertas activas** (right column):
   - Facturas vencidas
   - Clientes excediendo % comprometido
   - Capacidad por mes <30% (bandwidth alert)
   - Capacidad por mes >100% (overcommitment alert)

3. **Tabla clientes activos**:
   - Columnas: Nombre, Tarifa, Modalidad, Horas mes (actual/objetivo con bar), Última sesión, Estado, Acciones (pause/terminar)
   - Click row → drilldown view (sesiones recientes, facturas, notas)

4. **Sesiones recientes** (últimas 20):
   - Tabla: Fecha, Cliente, Horas, Descripción, Facturable

5. **Facturación**:
   - Lista de facturas con filtros (estado, cliente, fecha range)
   - Botón "marcar pagada" por row

### 7.2 Add/edit forms

Modal forms para crear cliente, log sesion, emitir factura. Validaciones:
- tarifa_hora > 0 si modalidad='horas'
- retainer_mensual > 0 si modalidad='retainer'
- fecha_inicio ≤ today
- horas > 0
- monto_subtotal > 0

### 7.3 Empty state

Cuando aún no hay clientes: pantalla "Welcome — agrega tu primer cliente"
con CTA grande. Educate that Axi can also add clients via SimpleX/voice.

## 8. Privacy & data handling

- All freelance data stored in `memory.db` under existing AES-256-GCM-SIV encryption.
- NO data leaves the device. All Axi reasoning over freelance data uses LOCAL LLM
  (Qwen3.5-9B) by default. Privacy Mode (already shipped Sprint 1) ensures no
  cloud LLM call when user enables strict mode.
- For complex multi-domain queries, future cross-domain reasoning engine MAY use
  cloud LLM IF user explicitly opts out of Privacy Mode for that query type.
- Auditable: every destructive action (delete cliente, cancelar factura) logged
  to `~/.local/share/lifeos/destructive_actions.log` (existing audit log from Sprint 1).

## 9. Tests

### 9.1 Unit (Rust, in `memory_plane.rs::tests` mod)

For each new function (cliente CRUD, sesion CRUD, factura CRUD, analytics):
- Happy path
- Edge case: cliente with no sesiones, factura with 0 sesiones linked
- Validation errors: negative monto, fecha_fin before fecha_inicio
- Concurrent insert handling

### 9.2 Integration

End-to-end test: add cliente → log 5 sesiones → emit factura linking sesiones → mark paid → run overview → assert numbers consistent.

### 9.3 Manual smoke (after deploy)

- Via SimpleX: "Axi, agregá cliente Acme, $500/hora, 20 horas/mes" → expect Axi confirms creation
- Open dashboard → Freelance tab → expect cliente appears
- Via SimpleX: "trabajé 3 horas con Acme hoy" → expect sesion logged
- Run dashboard refresh → expect horas_trabajadas updated

## 10. Success criteria

This v1 ships when:

1. ✅ All 4 schemas live in `memory.db` (created on startup, idempotent)
2. ✅ All ~20 LLM tools registered + tested + documented in SYSTEM_PROMPT
3. ✅ All REST endpoints serve correct data
4. ✅ Dashboard tab shows real-time data after any change (poll or WebSocket)
5. ✅ User can complete the full workflow via SimpleX without ever opening dashboard
6. ✅ User can complete the full workflow via dashboard without ever using SimpleX
7. ✅ Cross-domain skeleton: `freelance_overview` returns alertas that include
   simple cross-references (e.g., "facturación de este mes está 30% por debajo
   del promedio de los últimos 3 meses") even though full cross-domain reasoning
   engine is out-of-scope
8. ✅ JD adversarial review: 0 CRITICAL, ≤2 HIGH (with documented rationale)

## 11. Future extensions (NOT in v1, but designed-for)

This domain serves as the TEMPLATE for future life domains:

- **Travel domain**: viajes, gastos por viaje, fotos enlazadas, comparación
- **Projects domain**: proyectos personales, milestones, dependencias
- **Privacy/Personal domain**: pareja, familia íntima, decisiones privadas (encrypted vault tier)
- **Finance v2**: presupuestos, categorías de gasto detalladas, reconciliación

Each future domain follows the same pattern:
1. Schema in `memory_plane.rs::initialize()`
2. ~10-20 tools in `axi_tools.rs`
3. ~10-15 REST endpoints in `api/mod.rs`
4. Dashboard tab in `static/dashboard/`
5. Cross-domain alerts integrated into `*_overview` tools

When ALL major domains are in place, then build the **cross-domain reasoning
engine** that synthesizes across them (using local LLM for simple, cloud LLM for
complex queries — user-controlled via Privacy Mode).

## 12. Implementation roadmap (this PR)

Single PR `feat/freelance-domain` with the following commits in order:

1. `feat(freelance): schemas + initialize migration`
2. `feat(freelance): cliente CRUD + tests`
3. `feat(freelance): sesion CRUD + tests`
4. `feat(freelance): factura CRUD + tests`
5. `feat(freelance): analytics tools (overview, horas_libres, ingresos)`
6. `feat(freelance): REST endpoints`
7. `feat(freelance): LLM tool registration in axi_tools.rs`
8. `feat(freelance): dashboard tab + overview cards`
9. `feat(freelance): dashboard CRUD forms + drilldown`
10. `docs(freelance): user guide + tool reference`

Each commit ships independently sane. Final commit: bump version + update changelog.

## 13. Estimated effort

- Schemas + Rust CRUD + tests: 6-8 hrs
- LLM tools (~20): 4-5 hrs
- REST API: 2-3 hrs
- Dashboard SPA tab: 6-8 hrs
- Documentation + smoke testing: 2-3 hrs
- JD round + fixes: 2-4 hrs
- **Total**: 22-31 hrs of focused work

This is a multi-session effort. NOT a single sit-down. Plan accordingly.
