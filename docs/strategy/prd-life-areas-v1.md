# PRD — LifeOS Life Areas v1 Cohort (Finanzas, Vehículos, Viajes, Proyectos)

**Status**: Approved 2026-04-26
**Owner**: Hector (LifeOS)
**Companion to**: `prd-freelance-domain.md` (Freelance is the prototype this cohort follows)
**Implementation target**: Next sprint after Sprint 3+4 + Freelance MVP

---

## 1. Why this PRD covers 4 domains together

The Freelance domain established the PATTERN (schemas + tools + REST + dashboard).
This PRD scopes 4 more high-value domains using the SAME pattern. Implementing
them together (parallel via git worktrees) is more efficient than serially:

- They share the meta-architecture (encryption, tool registration, REST patterns)
- They share dashboard chrome (tabs, cards, tables)
- They will eventually share the cross-domain reasoning engine

The 4 domains in this cohort:

1. **Finanzas** — gastos, ingresos, presupuestos, cuentas (tarjetas + débito)
2. **Vehículos** — autos del hogar, mantenimientos, seguros, gastos
3. **Viajes** — viajes episódicos con destino, fechas, gastos por categoría
4. **Proyectos** — proyectos personales/familiares con milestones y deadlines

Future cohort v2 (NOT in this PRD): Aprendizaje, Patrimonio, Hogar, Privado/Familia.

## 2. Pattern recap (shared across all 4)

Each domain follows this structure:
- 3-5 SQLite tables in `memory.db` (encrypted text fields, plaintext numerics for analytics)
- 15-25 LLM tools in `axi_tools.rs` (CRUD + analytics)
- 8-12 REST endpoints under `/api/v1/<domain>/`
- Dashboard tab (deferred — separate PR per domain)
- Tests for happy path + edge cases

Cross-domain skeleton: each `<domain>_overview` tool emits alertas that may
include simple cross-domain references (e.g., gasto del mes excede % del ingreso
freelance). Full cross-domain reasoning engine = separate PRD later.

---

## 3. Finanzas Domain

### 3.1 Why

Hector already has parcial finanzas data in `personalProjects/gama/analisis/`. The
Resumen Ejecutivo, decision_log, plan_de_accion live as Markdown. Need them
QUERYABLE by Axi: "¿cuánto gasté este mes en restaurantes?", "¿cuál es mi
balance de tarjetas?", "¿estoy abajo de mi presupuesto de comida?".

This domain captures the **transactional** layer. The strategic layer (decision
log, plan de acción) stays as Markdown in user's analisis/ folder — but Axi can
index it via memory_plane (future).

### 3.2 Schemas

```sql
CREATE TABLE IF NOT EXISTS finanzas_cuentas (
  cuenta_id      TEXT PRIMARY KEY,           -- "cta-<uuid>"
  nombre         TEXT NOT NULL,              -- "Santander débito Hector"
  tipo           TEXT NOT NULL,              -- 'debito'|'credito'|'efectivo'|'inversion'|'ahorro'
  banco          TEXT,                       -- "Santander"
  ultimos_4      TEXT,                       -- "1234"
  moneda         TEXT NOT NULL DEFAULT 'MXN',
  saldo_actual   REAL,                       -- nullable; user-reported
  limite_credito REAL,                       -- if tipo='credito'
  fecha_corte    INTEGER,                    -- día del mes (1-31), if tipo='credito'
  fecha_pago     INTEGER,                    -- día del mes
  titular        TEXT NOT NULL DEFAULT 'hector', -- 'hector'|'cely'|'ambos'
  estado         TEXT NOT NULL DEFAULT 'activo',  -- 'activo'|'cerrada'
  notas          TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS finanzas_categorias (
  categoria_id   TEXT PRIMARY KEY,           -- "cat-<uuid>"
  nombre         TEXT NOT NULL UNIQUE,       -- "Comida fuera"
  tipo           TEXT NOT NULL,              -- 'gasto'|'ingreso'|'transferencia'
  parent_id      TEXT,                       -- "cat-<uuid>" — opcional jerarquia
  emoji          TEXT,                       -- "🍔"
  color          TEXT,                       -- hex
  presupuesto_mensual REAL,                  -- nullable
  created_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS finanzas_movimientos (
  movimiento_id  TEXT PRIMARY KEY,           -- "mov-<uuid>"
  cuenta_id      TEXT NOT NULL,              -- FK
  categoria_id   TEXT,                       -- FK nullable
  tipo           TEXT NOT NULL,              -- 'gasto'|'ingreso'|'transferencia'
  fecha          TEXT NOT NULL,              -- ISO date
  monto          REAL NOT NULL,              -- positive number; tipo determines direction
  moneda         TEXT NOT NULL DEFAULT 'MXN',
  descripcion    TEXT,
  comercio       TEXT,                       -- "Costco"
  metodo         TEXT,                       -- 'tarjeta'|'efectivo'|'transferencia'|'pse'
  cuenta_destino_id TEXT,                    -- if tipo='transferencia'
  recurrente     INTEGER NOT NULL DEFAULT 0, -- 1 = mensual fijo
  notas          TEXT,
  -- Vinculación opcional a otros dominios:
  viaje_id       TEXT,                       -- FK to viajes_viajes (NULL if not travel-related)
  vehiculo_id    TEXT,                       -- FK to vehiculos_vehiculos (NULL if not vehicle-related)
  proyecto_id    TEXT,                       -- FK to proyectos (NULL if not project-related)
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS finanzas_presupuestos (
  presupuesto_id TEXT PRIMARY KEY,           -- "pre-<uuid>"
  categoria_id   TEXT NOT NULL,              -- FK
  mes            TEXT NOT NULL,              -- 'YYYY-MM'
  monto_objetivo REAL NOT NULL,
  monto_gastado  REAL NOT NULL DEFAULT 0,    -- recalculado on-demand
  alerta_pct     REAL NOT NULL DEFAULT 80.0, -- alerta cuando gastado >= % de objetivo
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  UNIQUE (categoria_id, mes)
);

CREATE TABLE IF NOT EXISTS finanzas_metas_ahorro (
  meta_id        TEXT PRIMARY KEY,           -- "met-<uuid>"
  nombre         TEXT NOT NULL,              -- "Fondo emergencia 6 meses"
  monto_objetivo REAL NOT NULL,
  monto_actual   REAL NOT NULL DEFAULT 0,
  fecha_objetivo TEXT,                       -- nullable
  cuenta_id      TEXT,                       -- which account holds it
  prioridad      INTEGER NOT NULL DEFAULT 5, -- 1-10
  estado         TEXT NOT NULL DEFAULT 'activa', -- 'activa'|'pausada'|'lograda'|'abandonada'
  notas          TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_finanzas_movimientos_cuenta ON finanzas_movimientos(cuenta_id, fecha);
CREATE INDEX IF NOT EXISTS idx_finanzas_movimientos_categoria ON finanzas_movimientos(categoria_id, fecha);
CREATE INDEX IF NOT EXISTS idx_finanzas_movimientos_fecha ON finanzas_movimientos(fecha);
CREATE INDEX IF NOT EXISTS idx_finanzas_movimientos_viaje ON finanzas_movimientos(viaje_id) WHERE viaje_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_finanzas_movimientos_vehiculo ON finanzas_movimientos(vehiculo_id) WHERE vehiculo_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_finanzas_presupuestos_mes ON finanzas_presupuestos(mes);
```

### 3.3 Tools (LLM)

**Cuentas**: `cuenta_add`, `cuenta_list`, `cuenta_update`, `cuenta_saldo_update`, `cuenta_cerrar`.

**Categorías**: `categoria_add`, `categoria_list`, `categoria_update`, `categoria_delete` (with confirm).

**Movimientos**: `movimiento_log`, `movimiento_list` (filtros: cuenta, categoria, fecha range, tipo), `movimiento_update`, `movimiento_delete`.

**Presupuestos**: `presupuesto_set` (categoria + mes + monto), `presupuesto_status` (mes actual o specified), `presupuestos_list`.

**Metas**: `meta_ahorro_add`, `meta_ahorro_aporte` (suma a monto_actual), `meta_ahorro_list`, `meta_ahorro_progress`.

**Analytics**:
- `finanzas_overview(mes?)` — gastos por categoría, ingresos, balance, alertas (presupuestos excedidos, metas atrasadas, deudas vencidas)
- `gastos_por_categoria(desde, hasta)` — agregación
- `ingresos_vs_gastos(meses_atras?)` — tendencia
- `cuentas_balance` — saldo total + por banco + tipo
- `gastos_recurrentes_list` — solo movimientos `recurrente=1`
- `cuanto_puedo_gastar(categoria_o_general?)` — calcula presupuesto restante mes actual

### 3.4 REST endpoints

`/api/v1/finanzas/` — análogo a freelance. Standard CRUD + overview + analytics.

---

## 4. Vehículos Domain

### 4.1 Why

Hector tiene 2 autos: **Honda Pilot** (con kit distribución vencido y otros pendientes
mecánicos) y **Honda Civic**. Ya hay docs en `analisis/docs/valuacion_pilot.md`,
`talleres_reparacion_pilot.md`, `seguro_pilot.md`. Necesita estructura para:
- Inventario vehículos del hogar
- Mantenimientos (programados + realizados)
- Gastos por vehículo (combustible, mantenimiento, seguros, tenencia, peajes)
- Seguros activos (con vencimientos)
- Documentos (factura, tarjeta circulación, póliza)

### 4.2 Schemas

```sql
CREATE TABLE IF NOT EXISTS vehiculos_vehiculos (
  vehiculo_id    TEXT PRIMARY KEY,           -- "veh-<uuid>"
  alias          TEXT NOT NULL,              -- "Pilot", "Civic"
  marca          TEXT NOT NULL,
  modelo         TEXT NOT NULL,
  anio           INTEGER,
  placas         TEXT,
  vin            TEXT,
  color          TEXT,
  kilometraje_actual INTEGER,
  fecha_compra   TEXT,                       -- ISO date
  precio_compra  REAL,
  titular        TEXT NOT NULL DEFAULT 'hector', -- 'hector'|'cely'|'ambos'
  estado         TEXT NOT NULL DEFAULT 'activo', -- 'activo'|'vendido'|'siniestrado'
  fecha_baja     TEXT,
  precio_venta   REAL,
  notas          TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS vehiculos_mantenimientos (
  mantenimiento_id TEXT PRIMARY KEY,         -- "man-<uuid>"
  vehiculo_id    TEXT NOT NULL,
  tipo           TEXT NOT NULL,              -- 'cambio_aceite'|'banda_distribucion'|'frenos'|'amortiguadores'|'revision_general'|'otro'
  descripcion    TEXT,
  fecha_realizado TEXT,                      -- null si solo programado
  fecha_programada TEXT,                     -- null si ya realizado
  kilometraje_realizado INTEGER,
  km_proximo     INTEGER,                    -- recordatorio próximo
  taller         TEXT,
  costo          REAL,
  movimiento_id  TEXT,                       -- FK to finanzas_movimientos (auto-link)
  notas          TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS vehiculos_seguros (
  seguro_id      TEXT PRIMARY KEY,           -- "seg-<uuid>"
  vehiculo_id    TEXT NOT NULL,
  aseguradora    TEXT NOT NULL,              -- "Qualitas"
  tipo           TEXT NOT NULL,              -- 'amplia'|'limitada'|'rc_unica'
  numero_poliza  TEXT,
  fecha_inicio   TEXT NOT NULL,
  fecha_vencimiento TEXT NOT NULL,
  prima_total    REAL,
  cobertura_rc   REAL,                       -- monto cobertura RC
  deducible_dh   REAL,                       -- daños y robo
  agente         TEXT,
  movimiento_id  TEXT,                       -- FK to finanzas_movimientos
  notas          TEXT,
  estado         TEXT NOT NULL DEFAULT 'vigente', -- 'vigente'|'vencido'|'cancelado'
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS vehiculos_combustible (
  carga_id       TEXT PRIMARY KEY,           -- "fuel-<uuid>"
  vehiculo_id    TEXT NOT NULL,
  fecha          TEXT NOT NULL,
  litros         REAL,
  monto          REAL NOT NULL,
  precio_litro   REAL,
  kilometraje    INTEGER,
  estacion       TEXT,
  movimiento_id  TEXT,                       -- FK to finanzas_movimientos
  notas          TEXT,
  created_at     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_vehiculos_mantenimientos_vehiculo ON vehiculos_mantenimientos(vehiculo_id);
CREATE INDEX IF NOT EXISTS idx_vehiculos_mantenimientos_programada ON vehiculos_mantenimientos(fecha_programada) WHERE fecha_programada IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_vehiculos_seguros_vencimiento ON vehiculos_seguros(fecha_vencimiento);
CREATE INDEX IF NOT EXISTS idx_vehiculos_combustible_vehiculo ON vehiculos_combustible(vehiculo_id, fecha);
```

### 4.3 Tools

`vehiculo_add`, `vehiculo_list`, `vehiculo_update`, `vehiculo_kilometraje_actualizar`, `vehiculo_vender`.

`mantenimiento_log` (registrar realizado), `mantenimiento_programar` (futuro), `mantenimiento_list` (vehículo, pendientes, realizados), `mantenimiento_completar` (mover de programado a realizado), `mantenimientos_proximos` (alerta).

`seguro_add`, `seguro_renovar` (cierra vigente + crea nuevo), `seguro_list`, `seguros_por_vencer` (siguientes 30/60/90 días).

`combustible_log`, `combustible_stats` (rendimiento km/litro últimos N tanques).

**Analytics**:
- `vehiculos_overview` — todos los vehículos + alertas (mantenimientos vencidos, seguros por vencer, kilometraje sin actualizar)
- `vehiculo_costo_total(vehiculo_id, periodo?)` — todos los gastos asociados
- `rendimiento_combustible(vehiculo_id)` — km/litro

### 4.4 Cross-domain links

- `vehiculos_mantenimientos.movimiento_id` → `finanzas_movimientos.movimiento_id` (cada mantenimiento puede generar un gasto)
- `vehiculos_seguros.movimiento_id` → idem
- `vehiculos_combustible.movimiento_id` → idem
- `finanzas_movimientos.vehiculo_id` → idem (búsqueda inversa)

Auto-link cuando user dice "puse 800 pesos de gasolina en la Pilot" → log combustible_log → auto-create movimiento finanzas con categoria 'Combustible' + vehiculo_id.

---

## 5. Viajes Domain

### 5.1 Why

User mencionó: "si un dia le platico sobre un viaje que me diga que la vez pasada
que fui me gaste tanto dinero". Necesita estructura para viajes episódicos con:
- Destino, fechas, motivo
- Gastos del viaje (con vínculo a finanzas)
- Notas / experiencias
- Fotos (referencias a archivos, no almacenamiento)

### 5.2 Schemas

```sql
CREATE TABLE IF NOT EXISTS viajes_viajes (
  viaje_id       TEXT PRIMARY KEY,           -- "via-<uuid>"
  nombre         TEXT NOT NULL,              -- "Mazatlán Mar 2026"
  destino        TEXT NOT NULL,              -- "Mazatlán, Sinaloa"
  pais           TEXT,                       -- "México"
  motivo         TEXT,                       -- 'vacaciones'|'trabajo'|'familiar'|'evento'|'otro'
  fecha_inicio   TEXT NOT NULL,
  fecha_fin      TEXT NOT NULL,
  acompanantes   TEXT,                       -- "Cely, los suegros"
  presupuesto_inicial REAL,                  -- planeado
  estado         TEXT NOT NULL DEFAULT 'planeado', -- 'planeado'|'en_curso'|'completado'|'cancelado'
  notas          TEXT,
  fotos_path     TEXT,                       -- path al folder de fotos en disco
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS viajes_destinos (
  destino_id     TEXT PRIMARY KEY,           -- "des-<uuid>"
  viaje_id       TEXT NOT NULL,              -- FK
  ciudad         TEXT NOT NULL,
  pais           TEXT,
  fecha_llegada  TEXT NOT NULL,
  fecha_salida   TEXT,
  alojamiento    TEXT,                       -- "Hotel X"
  notas          TEXT,
  created_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS viajes_actividades (
  actividad_id   TEXT PRIMARY KEY,
  viaje_id       TEXT NOT NULL,
  fecha          TEXT NOT NULL,
  titulo         TEXT NOT NULL,
  descripcion    TEXT,
  tipo           TEXT,                       -- 'comida'|'tour'|'museo'|'transporte'|'otro'
  costo          REAL,
  movimiento_id  TEXT,                       -- FK finanzas
  rating         INTEGER,                    -- 1-5
  recomendaria   INTEGER,                    -- 0|1
  notas          TEXT,
  created_at     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_viajes_viajes_estado ON viajes_viajes(estado);
CREATE INDEX IF NOT EXISTS idx_viajes_viajes_destino ON viajes_viajes(destino);
CREATE INDEX IF NOT EXISTS idx_viajes_viajes_fechas ON viajes_viajes(fecha_inicio, fecha_fin);
```

### 5.3 Tools

`viaje_add`, `viaje_list` (filter estado, año), `viaje_update`, `viaje_iniciar` (marca en_curso), `viaje_completar`, `viaje_cancelar`.

`destino_add`, `destino_list` (per viaje), `destino_update`.

`actividad_log`, `actividades_list`, `actividad_recomendar` (rating).

**Analytics**:
- `viajes_overview(año?)` — total viajes, gastos, destinos
- `viaje_resumen(viaje_id)` — full debrief con gastos por categoría, actividades top
- `comparar_viajes(viaje_a, viaje_b)` — gastos lado a lado
- `mejor_viaje_a(destino)` — todos los viajes a ese destino con totales y ratings
- `cuanto_gaste_en(destino_o_pais)` — query por lugar

### 5.4 Cross-domain

- `viajes_actividades.movimiento_id` → finanzas
- `finanzas_movimientos.viaje_id` → viajes (cuando user dice "este gasto fue del viaje")
- Future: `vehiculos_combustible.viaje_id` (carga de gasolina durante viaje)

---

## 6. Proyectos Domain

### 6.1 Why

User mencionó "después hablarle de proyectos futuros". `personalProjects/` ya
existe en disco, pero NO está estructurado en memory_plane. Necesita:
- Proyectos personales (LifeOS dev, otros)
- Proyectos familiares (remodelación casa, viaje de aniversario, etc.)
- Estados, deadlines, milestones
- Vínculo opcional a gastos (proyecto puede tener presupuesto + gastos asociados)

### 6.2 Schemas

```sql
CREATE TABLE IF NOT EXISTS proyectos_proyectos (
  proyecto_id    TEXT PRIMARY KEY,           -- "pro-<uuid>"
  nombre         TEXT NOT NULL,
  descripcion    TEXT,
  tipo           TEXT NOT NULL,              -- 'personal'|'familiar'|'trabajo'|'aprendizaje'
  prioridad      INTEGER NOT NULL DEFAULT 5, -- 1-10
  fecha_inicio   TEXT,
  fecha_objetivo TEXT,                       -- target completion
  fecha_real_fin TEXT,                       -- actual completion
  presupuesto_estimado REAL,
  presupuesto_gastado  REAL NOT NULL DEFAULT 0,
  estado         TEXT NOT NULL DEFAULT 'planeado', -- 'planeado'|'activo'|'pausado'|'completado'|'cancelado'|'bloqueado'
  bloqueado_por  TEXT,                       -- razón si estado='bloqueado'
  ruta_disco     TEXT,                       -- path al folder en disco si aplica
  url_externo    TEXT,                       -- repo, drive folder, etc
  notas          TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS proyectos_milestones (
  milestone_id   TEXT PRIMARY KEY,           -- "mil-<uuid>"
  proyecto_id    TEXT NOT NULL,
  nombre         TEXT NOT NULL,
  descripcion    TEXT,
  fecha_objetivo TEXT,
  fecha_completado TEXT,                     -- null si aún no
  orden          INTEGER NOT NULL DEFAULT 0,
  notas          TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS proyectos_dependencias (
  proyecto_id      TEXT NOT NULL,
  depende_de_id    TEXT NOT NULL,
  tipo             TEXT NOT NULL DEFAULT 'bloqueante', -- 'bloqueante'|'relacionado'
  notas            TEXT,
  PRIMARY KEY (proyecto_id, depende_de_id)
);

CREATE INDEX IF NOT EXISTS idx_proyectos_estado ON proyectos_proyectos(estado);
CREATE INDEX IF NOT EXISTS idx_proyectos_prioridad ON proyectos_proyectos(prioridad);
CREATE INDEX IF NOT EXISTS idx_proyectos_milestones_proyecto ON proyectos_milestones(proyecto_id, orden);
CREATE INDEX IF NOT EXISTS idx_proyectos_milestones_objetivo ON proyectos_milestones(fecha_objetivo) WHERE fecha_objetivo IS NOT NULL;
```

### 6.3 Tools

`proyecto_add`, `proyecto_list` (filtros: estado, tipo, prioridad), `proyecto_update`, `proyecto_pausar`, `proyecto_completar`, `proyecto_cancelar`, `proyecto_bloquear`.

`milestone_add`, `milestone_list`, `milestone_completar`, `milestone_update`.

`proyecto_dependencia_add`, `proyecto_dependencias_list`.

**Analytics**:
- `proyectos_overview` — todos los activos + pendientes + bloqueados
- `proyectos_priorizados` — top N por prioridad
- `proyectos_atrasados` — fecha_objetivo < today AND estado != completado
- `proyecto_progress(proyecto_id)` — % completado por milestones + presupuesto consumido
- `proyectos_por_completar_esta_semana` — milestones con fecha_objetivo en próximos 7 días

### 6.4 Cross-domain

- `finanzas_movimientos.proyecto_id` → proyectos (gastos atribuibles a proyecto)
- Auto-update `proyectos.presupuesto_gastado` cuando se inserta movimiento con `proyecto_id`
- Future: `proyectos.dependencia` con tareas externas (Linear, GitHub Issues, etc.)

---

## 7. Cross-domain alertas (skeleton incluido en cada *_overview)

Cada `<domain>_overview` tool incluye sección `alertas` con cross-references SIMPLES
(no deep reasoning yet):

| Trigger | Domain origen | Cross-ref |
|---|---|---|
| Presupuesto excedido categoría X | finanzas | "$X gastado este mes en [categoria], 130% del presupuesto" |
| Mantenimiento vencido | vehículos | "Pilot necesita banda de distribución hace 2 meses, costo estimado $X" |
| Seguro por vencer 30 días | vehículos | "Póliza Pilot vence en 25 días" |
| Viaje próximo sin presupuesto | viajes | "Viaje X en 30 días sin presupuesto registrado" |
| Proyecto atrasado high-priority | proyectos | "Proyecto X (prioridad 9) atrasado 15 días" |
| Cliente excede comprometido | freelance | "(ya en freelance_overview)" |

Future cross-domain reasoning engine combinará estas señales para recommendations
holísticas: "no aceptes nuevo cliente este mes — proyecto X es prioridad 9 y está
atrasado, presión arterial alta los últimos 3 días, gastos del mes ya en 95% del
presupuesto".

---

## 8. Privacy & encryption

Mismo patrón que freelance: text fields sensibles encrypted (notas, descripcion,
nombres de comercios), money REAL plaintext para analytics.

Para Privado/Familia (futuro v2): tabla en `reinforced_vault_meta` con doble
encryption (passphrase user-controlled).

## 9. Tests por dominio

Cada dominio: 5-7 tests cubriendo:
- Happy path CRUD
- Cross-domain link cuando aplique
- Edge cases (fechas inválidas, montos negativos, FK orphans)
- Soft-delete preserva audit trail
- Overview aggregation

## 10. Success criteria

Por dominio:
1. ✅ Schemas live in memory.db (idempotent CREATE IF NOT EXISTS)
2. ✅ Tools registered + documented in SYSTEM_PROMPT
3. ✅ REST endpoints responsive
4. ✅ Tests pass logically (CI verifies)
5. ✅ Cross-domain alertas básicas funcionan
6. ✅ JD adversarial: 0 CRITICAL, ≤2 HIGH per dominio

## 11. Implementation strategy (este PR cohort)

**Branches separadas por dominio**, pero TODAS desde main actualizado:
- `feat/finanzas-domain`
- `feat/vehiculos-domain`
- `feat/viajes-domain`
- `feat/proyectos-domain`

Cada agente trabaja en su worktree. PRs separadas. CI cycles paralelos. Merge
sequential (no race conditions porque cada uno toca tablas diferentes — solo
overlap en `axi_tools.rs` dispatch table y `api/mod.rs` route registration).

Para resolver overlap automático: usar pattern de "register module" en lugar de
modificar dispatch table directamente. Cada dominio expone `register_<domain>_tools()`
y `register_<domain>_routes()` que main llama. Conflicts mínimos.

## 12. Out of scope (futuro v2)

- **Aprendizaje/Cursos**: cursos en plataformas (Udemy, Coursera), libros (LifeOS YA tiene `books`), certificaciones, progreso
- **Patrimonio**: bigger picture (vivienda, AFORE, inversiones, deudas largo plazo, valor neto)
- **Hogar**: gastos casa, mantenimientos, suministros, inquilinos si aplica
- **Privado/Familia**: vault encrypted dedicado para info muy sensible (médico íntimo, conversaciones privadas con Cely, decisiones íntimas)
- **Salud-extended**: ya hay base (vitals, mood, sleep, nutrition) pero faltaría: agenda médica (citas con médicos), recetas activas, estudios de laboratorio históricos, vacunas, alergias detalladas

Estas se implementarán en cohorts futuras siguiendo MISMO patrón.

## 13. Cross-domain reasoning engine (futuro v3)

Una vez todos los dominios tienen data viva (3-6 meses de uso), implementar:
- "Cross-Domain Planner Agent" que recibe pregunta compleja
- Consulta múltiples *_overview tools
- Sintetiza con LLM strong (Qwen3.5-9B local OR Claude/GPT cloud per Privacy Mode)
- Devuelve recommendation holística

Ejemplo:
```
User: "Estoy pensando en aceptar un cliente nuevo de 30 hrs/mes a $800/hora. ¿Qué piensas?"

Cross-Domain Planner:
1. freelance_overview → 12 hrs libres semana, 35 hrs/mes
2. vehiculos_overview → Pilot mantenimiento $15K pendiente
3. health vital recall → presión 145/95 últimos 3 días
4. proyectos_overview → 2 proyectos prioridad 9 atrasados
5. finanzas → balance $77K, gasto último mes $48K, ingreso $52K
6. viajes próximos → ninguno

LLM síntesis (con TODO el contexto):
"Sí podés en términos de horas (35 disponibles, cliente requiere 30). Económicamente
relevante: $24K extra/mes, ayudaría a cubrir mantenimiento Pilot. PERO presión
arterial alta + proyectos atrasados sugieren que ya estás cargado. Recomiendo:
acepta SOLO si podés bajar uno de los proyectos atrasados a prioridad 6 y tomar
medio cliente nuevo (15 hrs/mes), reevaluando en 2 semanas con tus vitales."
```

Esta es la NORTH STAR de LifeOS+Axi. El stack actual + estos dominios la habilitan.
