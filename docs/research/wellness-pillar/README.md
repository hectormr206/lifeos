# Wellness Pillar — Investigación profunda

> Documento de investigación para Fase BI (Bienestar Integral & Coach Personal).
> Resumen ejecutivo en `docs/strategy/fase-bi-bienestar-integral.md`.
> Fecha: 2026-04-06.

## 0. Tabla de contenidos

1. Por qué LifeOS puede hacer esto cuando otros no
2. Arquitectura técnica (almacenamiento, queries, cifrado)
3. Salud médica — modelo de datos detallado
4. Nutrición — fuentes de datos, recetas, listas de compras locales
5. Salud mental — la categoría más peligrosa
6. Comercio local — cómo integrar sin convertirse en marketplace
7. Ejercicio — rutinas, inventario, escalado
8. Salud femenina (ciclo menstrual) — lecciones post-Roe
9. Crecimiento personal — lectura, hábitos, carrera
9b. Las dimensiones extendidas (relaciones, espiritual, financiera, sexual, social, sueño)
10. Capa de coaching — cómo Axi conecta todo
11. Prior art comparado
12. Modos de fallo conocidos
13. Liability y disclaimers obligatorios
14. MVP roadmap (BI.1 → BI.14) y dependencias
15. Criterios de no-go

---

## 1. Por qué LifeOS puede hacer esto cuando otros no

El espacio de wellness apps está dominado por productos cloud-first,
ad-supported, suscripción mensual, y silos cerrados. La gran mayoría
tienen los mismos problemas de fondo:

| Problema | Apple Health | MyFitnessPal | Strava | Headspace | Flo |
|---|---|---|---|---|---|
| Datos en sus servidores | Sí (iCloud) | Sí | Sí | Sí | Sí |
| Vendidos a aseguradoras / anunciantes | Parcial | Sí (histórico) | Anunciantes | Anunciantes | Sí (controversia 2021) |
| Funciona offline | Parcial | No | No | Parcial | No |
| Funciona sin cuenta | No | No | No | No | No |
| Funciona sin internet | Lectura sí | No | No | Parcial | No |
| Datos exportables a formato abierto | Limitado | Limitado | GPX | No | No |
| Datos cifrados end-to-end | Parcial | No | No | No | No |
| Coaching cross-domain (salud + comida + sueño + ánimo) | Solo lectura | Solo comida | Solo ejercicio | Solo meditación | Solo ciclo |
| Disponible si te cancelan la cuenta | No | No | No | No | No |

LifeOS rompe **todas** estas restricciones simultáneamente porque:

1. **Local-first por arquitectura**, no por feature opcional. La base
   de datos vive en `~/.local/share/lifeos/memory.db` cifrada con
   AES-GCM-SIV. Sin internet sigue funcionando al 100%.
2. **Una sola memoria unificada** — el coach puede correlacionar
   "comiste pasta el martes", "te dolió la cabeza el miércoles",
   "dormiste 5h el martes" en una sola query, porque todo vive en la
   misma DB. Apple Health no puede hacer esto sin que tres apps
   distintas se hablen entre sí (y no lo hacen).
3. **Conversación natural en español** — no es un formulario, es una
   conversación. El usuario puede mandar "hoy desayuné chilaquiles
   verdes con dos huevos" por voz o texto y Axi lo registra. Apps
   tradicionales requieren tap-tap-tap en formularios.
4. **El usuario controla el LLM** — el procesamiento puede ser 100%
   local (llama-server con Qwen3.5-4B), o el usuario puede traer su
   propia API key (BYOK) si quiere modelos más grandes. Las apps
   comerciales no te dan esa opción.
5. **Sin lock-in** — los datos son del usuario, en su disco, en
   formato exportable. Si LifeOS desaparece mañana, los datos siguen
   ahí.

Esa combinación es **única** en el mercado actual. No conozco un solo
producto que tenga las 5 propiedades.

---

## 2. Arquitectura técnica

### 2.1 Una sola DB, múltiples side-tables

La regla es simple: **todo vive en `~/.local/share/lifeos/memory.db`**,
el archivo SQLite que ya tenemos. No creamos una DB nueva por dominio.

Razones:
- Backups automáticos ya cubren todo (`sqlite_protection::backup_all_databases`).
- Una sola clave de cifrado a default; key derivation por dominio es
  opt-in para mental health y ciclo menstrual.
- Las queries cross-domain (que son el valor diferenciador del coach)
  funcionan porque están en la misma DB.
- `cluster_summary` y `apply_decay` ya saben tratar diferentes `kind`s
  con políticas distintas.

Lo que cambia es que agregamos **side-tables estructuradas** además de
las narrativas en `memory_entries`. Cada side-table tiene su esquema,
sus índices, y un campo `source_entry_id` que la liga a la narrativa
correspondiente en `memory_entries`.

### 2.2 Esquema de side-tables (resumen)

Detalle completo en sección 3-9. Resumen del shape común:

```sql
CREATE TABLE health_facts (
    fact_id TEXT PRIMARY KEY,
    fact_type TEXT NOT NULL,        -- 'allergy', 'condition', 'blood_type', 'emergency_contact'
    label TEXT NOT NULL,            -- 'Penicilina', 'Diabetes tipo 2', 'O+', 'Mamá: 555-1234'
    severity TEXT,                  -- 'mild', 'moderate', 'severe', 'life_threatening'
    notes TEXT,
    source_entry_id TEXT,           -- FK opcional a memory_entries
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE health_medications (
    med_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    dosage TEXT NOT NULL,           -- '500mg', '10 unidades'
    frequency TEXT NOT NULL,        -- 'cada 12h', '2 veces al día con comida'
    condition TEXT,                 -- '¿para qué?'
    prescribed_by TEXT,
    started_at TEXT NOT NULL,
    ended_at TEXT,                  -- NULL = activo
    notes TEXT,
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE health_vitals (
    vital_id TEXT PRIMARY KEY,
    vital_type TEXT NOT NULL,       -- 'blood_pressure', 'glucose', 'weight', 'heart_rate', 'temperature'
    value_numeric REAL,             -- 130.0, 110.0, 78.5
    value_text TEXT,                -- '130/85' (presión necesita 2 valores)
    unit TEXT NOT NULL,             -- 'mmHg', 'mg/dL', 'kg', 'bpm', '°C'
    measured_at TEXT NOT NULL,
    context TEXT,                   -- 'en ayunas', 'después de correr'
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE health_lab_results (
    lab_id TEXT PRIMARY KEY,
    test_name TEXT NOT NULL,        -- 'Glucosa en ayunas', 'HbA1c', 'LDL'
    value_numeric REAL NOT NULL,
    unit TEXT NOT NULL,
    reference_low REAL,
    reference_high REAL,
    measured_at TEXT NOT NULL,
    lab_name TEXT,
    notes TEXT,
    attachment_path TEXT,           -- path a PDF cifrado opcional
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE health_attachments (
    attachment_id TEXT PRIMARY KEY,
    file_path TEXT NOT NULL,        -- ~/.local/share/lifeos/health_attachments/<uuid>.enc
    file_type TEXT NOT NULL,        -- 'prescription', 'lab_pdf', 'xray', 'scan'
    description TEXT,
    related_event TEXT,             -- 'gripa marzo 2026'
    encryption TEXT NOT NULL,       -- 'aes-gcm-siv'
    nonce_b64 TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE nutrition_log (
    log_id TEXT PRIMARY KEY,
    meal_type TEXT NOT NULL,        -- 'breakfast', 'lunch', 'dinner', 'snack'
    description TEXT NOT NULL,      -- texto libre del usuario o resultado de visión
    photo_path TEXT,                -- path opcional a foto cifrada
    voice_note_path TEXT,           -- path opcional a audio cifrado
    macros_kcal REAL,               -- estimación opcional
    macros_protein_g REAL,
    macros_carbs_g REAL,
    macros_fat_g REAL,
    consumed_at TEXT NOT NULL,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);
```

El resto de las tablas (mental, ciclo, ejercicio, etc.) sigue el mismo
patrón: una clave primaria, campos estructurados específicos del
dominio, un `source_entry_id` opcional, timestamps.

### 2.3 Cifrado por capas

| Categoría | Cifrado |
|---|---|
| `memory_entries` (narrativa general) | AES-GCM-SIV con clave default `lifeos-memory-local-key` (igual que hoy) |
| `health_*` excepto mental | Misma clave default |
| `nutrition_*`, `exercise_*` | Misma clave default |
| `health_attachments` (archivos en disco) | AES-GCM-SIV per file con la misma clave default |
| `mental_health_journal` | **Clave derivada de passphrase del usuario** vía Argon2id. Sin la passphrase, las entradas son opacas para search/recall |
| `menstrual_cycle` | **Misma clave derivada que mental health** (opt-in). Por defecto usa la default key — el usuario puede elevarla |

**Por qué no separar más claves:** complica el modelo mental del usuario.
Si tiene 5 passphrases distintas para 5 dominios, va a olvidar alguna y
perder datos. Una clave default + una passphrase opcional para los dos
dominios más sensibles es el balance correcto.

**Cómo se deriva la passphrase:** Argon2id con parámetros conservadores
(memoria 64MB, t=3, p=1). El hash NO se almacena en disco — la
passphrase se pide en cada arranque del daemon (vía dashboard al
loguear) y queda en RAM solo mientras la sesión está activa. Si el
daemon se reinicia, hay que reingresarla. Es fricción intencional.

### 2.4 Queries cross-domain

El valor del coach está en queries que cruzan dominios. Ejemplos:

```sql
-- ¿Mis migrañas correlacionan con noches de poco sueño?
SELECT
    mig.measured_at AS migraine_date,
    s.value_numeric AS hours_slept
FROM health_vitals mig
LEFT JOIN health_vitals s
    ON s.vital_type = 'sleep_hours'
   AND DATE(s.measured_at) = DATE(mig.measured_at, '-1 day')
WHERE mig.vital_type = 'migraine_intensity'
ORDER BY mig.measured_at DESC
LIMIT 90;

-- ¿Cómo ha cambiado mi glucosa en ayunas en los últimos 6 meses?
SELECT measured_at, value_numeric
FROM health_vitals
WHERE vital_type = 'glucose'
  AND context = 'en ayunas'
  AND measured_at > date('now', '-6 months')
ORDER BY measured_at;

-- ¿Qué medicamentos tomo activamente hoy?
SELECT name, dosage, frequency, condition
FROM health_medications
WHERE ended_at IS NULL
ORDER BY started_at DESC;

-- ¿Comí algo nuevo esta semana que no había comido antes?
WITH recent AS (
    SELECT description FROM nutrition_log
    WHERE consumed_at > date('now', '-7 days')
),
historical AS (
    SELECT DISTINCT description FROM nutrition_log
    WHERE consumed_at <= date('now', '-7 days')
)
SELECT description FROM recent
WHERE description NOT IN (SELECT description FROM historical);
```

Estas queries son rapidísimas en SQLite con índices apropiados (sub-ms
en datasets de 100K+ rows). No necesitan LLM. Axi las dispara como
tools nuevos cuando el usuario pregunta cosas concretas.

---

## 3. Salud médica — modelo de datos detallado

### 3.1 `health_facts` — los facts permanentes

Esta es la tabla más simple pero la más crítica. Contiene los datos que
**nunca** deben olvidarse:

- Alergias (con severidad)
- Condiciones crónicas (diabetes, hipertensión, asma, etc.)
- Tipo de sangre
- Donante de órganos sí/no
- Contactos de emergencia
- Médico de cabecera + datos de contacto
- Seguro médico (IMSS, Pemex, Sedena, privado, ninguno)

**Auto-inyección en system prompt:** cada vez que el usuario habla con
Axi sobre algo médico (detector simple de palabras clave: "doctor",
"hospital", "medicina", "dolor", "síntoma", "enfermedad", etc.) Axi
recibe los `health_facts` críticos en su system prompt, sin que el
LLM tenga que pedirlos. Esto resuelve el caso "soy alérgico a X y
NUNCA quiero que se olvide": las alergias literalmente viajan en cada
prompt médico.

### 3.2 `health_medications` — history table

**Crítico:** las dosis cambian con el tiempo y cambian por razones
clínicas. Una tabla normal con UPDATE pierde el historial. Por eso es
una **history table**:

- Cada cambio de dosis es un `INSERT`, nunca un `UPDATE`.
- Los rows viejos se marcan con `ended_at`.
- Un mismo medicamento puede tener N rows a lo largo de los años con
  distintas dosis.

Ejemplo del caso del usuario (diabetes):

```
2024-01-15: metformina 500mg / 12h (started_at) → activo
2024-08-20: metformina 850mg / 12h (started_at) → ended_at del row anterior
2025-03-10: metformina 850mg / 12h + sitagliptina 100mg / 24h
2026-01-05: metformina suspendida (ended_at), solo sitagliptina
2026-06-15: ambas suspendidas, control con dieta y ejercicio
```

Una query sobre "qué tomas hoy" devuelve solo los rows con `ended_at IS NULL`.
Una query sobre "qué has tomado en los últimos 2 años" devuelve todo el
historial — invaluable para el médico nuevo que necesita contexto.

### 3.3 `health_vitals` — timeseries

Diseñada para ser **alimentada manualmente** desde Telegram/voz/dashboard.
No hay integración con wearables en V1 (ver sección 7).

Tipos de vitales soportados desde el día 1:
- `blood_pressure_systolic` + `blood_pressure_diastolic` (dos rows
  separados por lectura, mismo `measured_at`)
- `glucose` (mg/dL en México, mmol/L en otros países — guardar la
  unidad explícita)
- `weight`
- `heart_rate_resting`
- `temperature`
- `oxygen_saturation`
- `sleep_hours`
- `mood` (1-10)
- `pain_intensity` + `pain_location` (texto)
- `migraine_intensity`

Extensible: el campo `vital_type` es texto libre, pero hay una lista
canónica para autocompletado y para que las queries del coach sepan
qué buscar.

### 3.4 `health_attachments` — archivos cifrados

Las recetas en foto, los PDFs de análisis, las radiografías. El archivo
en disco se cifra con AES-GCM-SIV (igual que `memory_entries.ciphertext_b64`)
y la tabla guarda solo la metadata + el path.

**Importante:** el archivo cifrado vive en
`~/.local/share/lifeos/health_attachments/<uuid>.enc`, NO en `/tmp` y
NO en lugares que se borren al reiniciar. El daemon es el único que
puede descifrarlo en RAM cuando el usuario lo solicita explícitamente.

**Vision pipeline:** cuando el usuario sube una foto de una receta,
Axi automáticamente:
1. Guarda el archivo cifrado.
2. Manda la foto al LLM con visión (Qwen3.5-VL local o BYOK) para
   extraer texto estructurado: nombre del medicamento, dosis,
   frecuencia, indicaciones.
3. Le pregunta al usuario para confirmar la extracción.
4. Crea rows en `health_medications` con la info confirmada.
5. Ofrece crear reminders en `calendar` para las dosis.

---

## 4. Nutrición

### 4.1 El problema de las bases de datos nutricionales

El gran reto de las apps de nutrición es: **¿de dónde sale la
información de macros (kcal, proteína, carbs, grasa) por alimento?**

Opciones reales:

| Fuente | Cobertura | Open? | Útil para LifeOS? |
|---|---|---|---|
| **USDA FoodData Central** | Excelente para alimentos genéricos en USA | Sí, dominio público | Sí, base genérica |
| **Open Food Facts** | Amplia para productos empacados con código de barras (incluyendo varios productos mexicanos) | Sí, ODbL | Sí, vital |
| **FatSecret API** | Excelente, comercial | No | Solo BYOK |
| **Nutritionix API** | Excelente, comercial | No | Solo BYOK |
| **BEDCA** (España) | Buena para alimentos hispanos | Sí, restricciones de uso | Útil parcialmente |
| **Sistema Mexicano de Alimentos Equivalentes (SMAE)** | Excelente para platillos mexicanos típicos | No es API, es libro/PDF | Tabla manual de referencia |
| **LLM solo** (estimación por descripción) | Variable, hasta ±30% de error | N/A | Como fallback solamente |

**Estrategia para LifeOS:**

1. **Capa 1 — Open Food Facts.** Snapshot inicial + actualización
   mensual de productos comerciales. Lookup por código de barras
   (cuando el usuario manda foto del producto) o por nombre.
2. **Capa 2 — USDA FoodData Central** para alimentos genéricos
   ("manzana", "pechuga de pollo", "arroz blanco cocido").
3. **Capa 3 — Tabla SMAE manual** para platillos mexicanos típicos
   ("chilaquiles verdes", "tacos al pastor", "mole rojo"). 200-300
   entradas precargadas en el shipment, expandible por el usuario.
4. **Capa 4 — LLM como fallback estimador.** Cuando ninguna de las
   anteriores responde, el LLM da una estimación con un disclaimer
   explícito de que es una estimación.
5. **Capa 5 — El usuario puede editar siempre.** Si Axi estima
   "chilaquiles ≈ 600 kcal" y el usuario sabe que en su receta son
   ~450, lo corrige y queda guardado para futuro.

Las capas 1, 2 y 3 viven en una tabla `nutrition_food_db` precargada
en el shipment de la imagen bootc. Tamaño estimado: ~50 MB para
USDA + Open Food Facts México + SMAE. Trivial.

### 4.2 Ingest desde foto

Pipeline:

1. Usuario manda foto a Telegram: "esto comí".
2. Telegram bridge descarga la imagen y la pasa a `agentic_chat` con
   el contenido multimodal.
3. El system prompt incluye instrucciones específicas: "si la foto
   muestra comida, identifica los componentes principales y estima
   porciones".
4. El LLM con visión devuelve una descripción estructurada: "huevos
   revueltos (2 piezas), pan tostado (2 rebanadas), café con leche".
5. Axi consulta la tabla `nutrition_food_db` para cada componente y
   estima macros.
6. Axi pregunta confirmación al usuario en lenguaje natural.
7. Si el usuario confirma → crea row en `nutrition_log`.

### 4.3 Recetas y listas de compras

`nutrition_recipes` guarda recetas con ingredientes estructurados:

```sql
CREATE TABLE nutrition_recipes (
    recipe_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    ingredients_json TEXT NOT NULL,  -- [{"name":"huevo","amount":2,"unit":"pieza"},...]
    steps_json TEXT NOT NULL,
    prep_time_min INTEGER,
    cook_time_min INTEGER,
    servings INTEGER,
    tags TEXT NOT NULL,              -- JSON: ["desayuno","alto_proteina","apto_diabetes"]
    source TEXT,                     -- 'axi_propuesta', 'usuario', 'nutriologo:juan'
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);
```

**Generador de listas de compras:** Axi toma N recetas planeadas para
la semana, agrupa los ingredientes, cuenta cantidades, y genera la lista.
Este es el lugar donde se cruza con `local_commerce` (sección 6).

### 4.4 Conexión con salud

Las queries cross-domain hacen el coaching real:

- "¿Cómo ha estado mi glucosa después de los días que como pasta?"
- "¿Hay correlación entre mis migrañas y el café del desayuno?"
- "¿Cuánta fibra estoy comiendo en promedio? ¿He mejorado desde el
  diagnóstico de diabetes?"

Esto es lo que Apple Health no puede hacer porque la comida vive en
MyFitnessPal y la glucosa en otra app.

---

## 5. Salud mental — la categoría más peligrosa

### 5.1 Por qué requiere salvaguardas extras

La salud mental es la categoría con **más potencial de daño** si algo
sale mal. Razones concretas:

1. **Los usuarios cuentan más a los AI que a los humanos.** Es un
   fenómeno documentado: menos juicio, no hay costo social. La gente
   le habla a Axi de cosas que jamás contaría a un terapeuta humano.
   Eso significa que el archivo `memory.db` puede acumular el conjunto
   de datos más sensible imaginable: trauma de infancia, ideación
   suicida, abuso, depresión, ansiedad, secretos sexuales, problemas
   familiares.
2. **Si esos datos se filtran, la consecuencia es real.** Robo de
   laptop, familia abusiva mirando, divorcio judicial con peritaje de
   dispositivos, demanda donde el contenido se vuelve evidencia.
3. **Si Axi da mal consejo, puede empujar al usuario al precipicio.**
   Un LLM diciendo "creo que sí deberías rendirte" en respuesta a
   ideación suicida no es ciencia ficción — es algo que sucede en
   modelos mal alineados. Axi debe tener guardrails duros.
4. **En muchas jurisdicciones (México incluido), practicar terapia sin
   licencia es delito.** Si Axi se posiciona como "terapeuta", LifeOS
   se expone legalmente.

### 5.2 Salvaguardas obligatorias (no negociables)

**S1. Cifrado reforzado.** Las entradas de `mental_health_journal` se
cifran con una clave **derivada de una passphrase del usuario** vía
Argon2id. Si el usuario no ingresa la passphrase, las entradas existen
en disco pero son opacas — `search_entries` no las puede descifrar,
`recall` no las trae al system prompt, el dashboard las muestra como
"entradas mentales protegidas". El usuario tiene que ingresar la
passphrase para abrir el modo mental.

**S2. Auth secundaria al abrir el modo mental.** Después de la
passphrase, una segunda confirmación (PIN local o segundo prompt
"¿estás seguro de que quieres abrir el diario mental ahora?"). Esto
protege contra "alguien encontró la passphrase escrita pero no
sabe el contexto".

**S3. Detección de crisis.** Axi corre patrones de detección
sobre cada mensaje del usuario que toca salud mental. Patrones tipo:

```
"quiero morir(me)?" 
"no puedo más"
"ya no vale la pena"
"voy a hacerme daño"
"voy a (matarme|suicidar)"
"no quiero (vivir|estar aquí|seguir)"
"piensan? (estarían) mejor sin mí"
"plan(eo|eando) (suicidarme|hacerme daño)"
```

(La lista real debe ser revisada por un profesional de salud mental
antes de shippear.)

Cuando se detecta cualquiera de esos patrones, Axi **siempre** responde
con una combinación de:
1. Empatía explícita ("lo que me cuentas es importante y te creo").
2. Número de hotline local impreso textualmente:
   - **México:** SAPTEL 55 5259 8121 (24/7)
   - **México:** Línea de la Vida 800 290 0024 (24/7)
   - **España:** 024 (línea de crisis)
   - **USA:** 988 (Suicide & Crisis Lifeline)
   - **Internacional:** befrienders.org
3. Una pregunta de apoyo concreta ("¿hay alguien cerca con quien puedas
   hablar ahora mismo?").
4. **Nunca** un consejo médico, **nunca** una interpretación, **nunca**
   "estás exagerando", **nunca** silencio.

Estos patrones y respuestas viven en código Rust, **no en el system
prompt del LLM**. Razón: si se confía la respuesta al LLM, en un mal
día puede salir cualquier cosa. La detección y la respuesta son
deterministas, vienen del daemon, no del modelo.

**S4. Disclaimer "no soy terapeuta".** Una vez por sesión que toca
salud mental, Axi recuerda explícitamente:

> "Yo soy Axi, un compañero digital. No soy psicólogo, psiquiatra, ni
> terapeuta. Lo que me cuentas queda solo entre nosotros y tu disco
> duro. Si necesitas hablar con un profesional, puedo ayudarte a
> buscar uno. Y si en algún momento sientes que no puedes solo,
> SAPTEL (55 5259 8121) tiene gente real disponible 24/7."

Se puede ocultar después de N veces si el usuario lo pide explícitamente,
pero por default aparece.

**S5. No salir nunca del dispositivo.** Las entradas de
`mental_health_journal`:
- NO se sincronizan a ningún lado.
- NO se exportan automáticamente.
- NO se mandan al upstream de federación de compatibilidad (Fase BH.13).
- NO se procesan con LLMs remotos por default — solo el LLM local.
- Si el usuario quiere mandar una entrada al LLM remoto, lo tiene que
  activar explícitamente por entrada con preview completo.

**S6. Modo pánico.** Comando `/wipe-mental` desde Telegram + botón
rojo en el dashboard, ambos con doble confirmación. Borra de forma
segura (sobreescribe + delete) TODO el `mental_health_journal`.
**Razón de existir:** familia abusiva accediendo, divorcio, situación
legal donde el contenido se podría usar contra el usuario.

**S7. Nunca diagnosticar.** Axi NO dice "tienes depresión", NO dice
"tienes ansiedad generalizada", NO dice "creo que tienes TDAH". Solo
puede decir "lo que describes me suena difícil, ¿has considerado ver
a alguien?". El LLM tiene esto en su system prompt y se valida con
guardrails de output (post-processing del response antes de mandarlo
al usuario).

### 5.3 Lo que Axi SÍ puede hacer

- Escuchar sin juzgar.
- Reflejar lo que el usuario dice ("me dices que te sientes...").
- Hacer preguntas abiertas ("¿qué piensas que disparó eso?").
- Llevar registro de patrones (sin diagnosticar): "noto que hablamos
  de esto los lunes, ¿quieres que exploremos por qué?".
- Recordar lo importante de sesiones anteriores.
- Ofrecer recursos: "¿quieres que te ayude a buscar un terapeuta cerca
  de ti?".
- Sugerir técnicas básicas con disclaimer: "una técnica que algunas
  personas encuentran útil para ansiedad es la respiración 4-7-8.
  ¿Te explico cómo? Recuerda, esto es general — no sustituye terapia."

---

## 6. Comercio local — cómo integrar sin convertirse en marketplace

El usuario quiere que las listas de compras se filtren por
disponibilidad local: "no me propongas X si no se vende cerca de mí".

### 6.1 La trampa del scope creep

Es muy tentador convertir esto en "LifeOS sabe los precios en tiempo
real de Walmart, Soriana, Chedraui, mercado". **No vamos por ahí.** Eso
es:
- Un proyecto de scrapers de tamaño industrial.
- Sujeto a romperse cuando los sitios cambian.
- Dependiente de internet.
- Cuestionable legalmente (TOS de cada cadena).
- Convierte a LifeOS en un agregador de comercio, que es otro producto.

### 6.2 Lo que SÍ vamos a hacer (V1)

**Catálogo manual + curado por el usuario.** Estructura:

```sql
CREATE TABLE local_commerce_products (
    product_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,        -- 'fruta', 'verdura', 'lácteo', 'cereal', etc.
    where_available TEXT NOT NULL, -- JSON: ["walmart_local","mercado_jueves","soriana"]
    notes TEXT,                    -- 'temporada noviembre-marzo'
    added_at TEXT NOT NULL
);

CREATE TABLE local_commerce_stores (
    store_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,            -- 'Walmart Av. Tecnológico', 'Mercado del jueves'
    type TEXT NOT NULL,            -- 'supermarket', 'farmers_market', 'convenience', 'specialty'
    distance_km REAL,
    notes TEXT,
    added_at TEXT NOT NULL
);
```

**Cómo se llena este catálogo:**

1. **Catálogo base mexicano** precargado en el shipment: ~500
   productos comunes (huevo, leche, tortilla, frijol, arroz, pollo,
   pescados accesibles, verduras de temporada por mes, etc.) marcados
   como "disponible en tiendas mexicanas estándar". Esto cubre el 80%
   de las recetas básicas sin que el usuario configure nada.

2. **El usuario expande el catálogo conversacionalmente.** Cuando Axi
   propone una lista de compras y un producto no está en el catálogo,
   pregunta: "¿el queso feta es algo que encuentras cerca de ti?" El
   usuario dice sí/no/solo en X tienda, Axi lo agrega al catálogo.
   Al cabo de unas semanas, el catálogo refleja la realidad de la
   zona del usuario.

3. **El usuario puede importar listas** de productos desde texto/foto.
   "Estos son los productos que vi hoy en Walmart" + foto del pasillo
   → vision LLM extrae nombres → todos se agregan como "disponibles
   en walmart_local".

4. **(Opcional, opt-in) Sincronización con catálogos comunitarios.**
   Si Fase BH (federación de compatibilidad) llega a producción, este
   catálogo podría sincronizarse a un registry comunitario para que
   usuarios en la misma zona se beneficien mutuamente. Pero eso es
   muy futuro y opt-in estricto.

5. **NO scraping de sitios comerciales en V1.** Los sitios cambian, se
   rompen, y violan TOS.

### 6.3 Cómo Axi usa el catálogo

Cuando Axi propone una lista de compras, el flujo es:

1. Generar lista de ingredientes desde recetas activas.
2. Para cada ingrediente, lookup en `local_commerce_products`:
   - Si existe → marcar tienda(s) donde está disponible.
   - Si no existe → marcar como "no sé si lo encuentras cerca, ¿lo
     conoces?".
3. Agrupar por tienda al imprimir la lista: "Walmart: ... | Mercado: ...".
4. Si un ingrediente es necesario y no está disponible localmente,
   ofrecer alternativas: "el bulgur no lo encontré en tu catálogo —
   ¿quieres que sustituya por arroz integral en esta receta?".

---

## 7. Ejercicio

### 7.1 Inventario importa más que el plan

La diferencia entre una rutina útil y una inútil es si el usuario
**puede ejecutarla**. Una rutina perfecta de pesas no sirve si solo
tiene una banda de resistencia en casa.

`exercise_inventory` registra:

- Equipo pesado (mancuernas con peso, banca, barra olímpica, máquinas)
- Equipo ligero (ligas, banda, kettlebell, pelota suiza, foam roller)
- Equipo cardio (caminadora, elíptica, bicicleta estática)
- Acceso a gimnasio (sí/no, frecuencia, qué tiene el gym)
- Espacio disponible en casa (m² aproximados)
- Limitaciones físicas (rodilla mala, hombro lesionado, etc. — esto
  cruza con `health_facts`)

### 7.2 Generación de rutinas

Axi propone rutinas usando un prompt estructurado al LLM:

```
Inventario del usuario:
- Mancuernas ajustables 5-25kg
- Banco plano
- Liga de resistencia media
Limitaciones:
- Rodilla derecha sensible (no sentadillas profundas)
Objetivo:
- Fuerza tren superior, 3 días/semana, 45min máx por sesión

Genera una rutina de 3 sesiones (lunes/miércoles/viernes) con
ejercicios concretos, sets, reps, descansos, y notas de forma.
NO incluyas ejercicios que requieran equipo no listado.
NO incluyas sentadillas profundas.
```

El resultado se guarda como row en `exercise_plans` y se puede activar.

### 7.3 Log de sesiones

`exercise_log` registra cada sesión completada:

```sql
CREATE TABLE exercise_log (
    session_id TEXT PRIMARY KEY,
    plan_id TEXT,                  -- FK opcional a exercise_plans
    session_type TEXT NOT NULL,    -- 'strength', 'cardio', 'flexibility', 'sport'
    exercises_json TEXT NOT NULL,  -- detalle de qué se hizo
    duration_min INTEGER NOT NULL,
    rpe_1_10 INTEGER,              -- intensidad percibida
    notes TEXT,
    completed_at TEXT NOT NULL
);
```

### 7.4 Por qué NO wearables en V1

Apple Watch, Fitbit, Garmin viven en silos cloud. Importarlos
correctamente requiere:
- Cuenta del usuario en cada plataforma.
- API keys o OAuth flows.
- Mantenimiento constante porque las APIs cambian.
- Manejo de privacy diferente porque los wearables miden cosas que el
  usuario no autorizó conscientemente (ej: ritmo cardíaco continuo).

Eso es un proyecto separado (Fase BJ — "Wearables import"). Por ahora
el usuario registra manualmente, lo cual genera fricción real pero es
simple, privado, y suficiente para empezar.

---

## 8. Salud femenina (ciclo menstrual)

### 8.1 Por qué tiene salvaguardas extras (lecciones post-Roe)

Junio 2022: la Suprema Corte de USA revocó Roe v. Wade. En meses,
varias apps populares de tracking menstrual (Flo, Clue) se vieron
forzadas a defenderse públicamente sobre si entregarían datos a
fiscales en estados que criminalizaron el aborto. **Algunas no lo
hicieron, otras sí, otras prometieron pero su modelo de negocio dependía
de vender datos.**

México **no está exactamente en esa situación** — el aborto es legal
nacionalmente desde 2023 (SCJN) — pero:
- Algunos estados siguen criminalizando efectivamente.
- Las usuarias pueden viajar.
- Una usuaria puede vivir en una situación familiar abusiva donde el
  ciclo es información sensible aunque no sea legalmente perseguible.

**Conclusión:** los datos de ciclo menstrual son **categoría sensible
que merece las mismas salvaguardas que mental health**.

### 8.2 Salvaguardas

- **Opt-in explícito.** El módulo `menstrual_cycle` no existe hasta
  que el usuario lo activa desde el dashboard.
- **Cifrado reforzado** con la misma passphrase opcional que mental
  health (o una propia si el usuario lo prefiere).
- **Jamás sale del dispositivo.** Cero sync, cero export automático,
  cero federación.
- **Modo pánico** equivalente: `/wipe-cycle` con doble confirmación.
- **Predicciones simples** (no ML, no cloud) basadas en promedio de
  los últimos 6 ciclos del propio usuario. Sin compartir datos de
  modelos entrenados con miles de usuarias.

### 8.3 Schema

```sql
CREATE TABLE menstrual_cycle (
    entry_id TEXT PRIMARY KEY,
    cycle_day INTEGER,             -- día del ciclo desde el último periodo
    flow TEXT,                     -- 'none', 'light', 'medium', 'heavy'
    symptoms_json TEXT,            -- ["cramps", "headache", "bloating", ...]
    mood TEXT,                     -- texto libre
    notes TEXT,
    encrypted_with TEXT NOT NULL,  -- 'default' o 'user_passphrase'
    nonce_b64 TEXT,                -- si encrypted_with = user_passphrase
    ciphertext_b64 TEXT,
    recorded_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

---

## 9. Crecimiento personal

Más simple que las anteriores porque no toca dominios sensibles.

### 9.1 `reading_log`

```sql
CREATE TABLE reading_log (
    book_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    author TEXT,
    status TEXT NOT NULL,          -- 'wishlist', 'reading', 'finished', 'abandoned'
    started_at TEXT,
    finished_at TEXT,
    rating_1_5 INTEGER,
    notes TEXT,                    -- highlights, takeaways
    isbn TEXT,
    created_at TEXT NOT NULL
);
```

Axi puede preguntar pasivamente "¿sigues con [libro]?" cada N días, y
ofrecer recomendaciones basadas en lo que terminaste/calificaste alto.

### 9.2 `habits` y `growth_goals`

```sql
CREATE TABLE habits (
    habit_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    frequency TEXT NOT NULL,       -- 'daily', 'weekly:3', 'custom:MO,WE,FR'
    started_at TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1,
    notes TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE habit_log (
    log_id TEXT PRIMARY KEY,
    habit_id TEXT NOT NULL,
    completed INTEGER NOT NULL,    -- 0 o 1
    logged_for_date TEXT NOT NULL, -- YYYY-MM-DD
    notes TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE growth_goals (
    goal_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    deadline TEXT,
    progress_pct INTEGER DEFAULT 0,
    status TEXT NOT NULL,          -- 'active', 'paused', 'achieved', 'abandoned'
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

Axi corre una rutina diaria a hora configurable (default 21:00) que
pregunta sobre los hábitos del día, sin presionar. La gente abandona
los habit trackers que sermonean — Axi acompaña.

---

## 9b. Dimensiones extendidas (Vida Plena completa)

Las primeras secciones cubren las dimensiones más obvias (física,
mental, nutrición, ejercicio). Esta sección agrega las dimensiones que
completan el modelo "Vida Plena" — las que inicialmente no estaban
contempladas pero que son críticas para que LifeOS realmente sea un
compañero de vida.

### 9b.1 Relaciones humanas (BI.9)

**Por qué importa:** El Harvard Study of Adult Development (estudio
longitudinal de 85+ años, dirigido actualmente por Robert Waldinger)
encontró que **la calidad de las relaciones cercanas es el predictor
más fuerte de salud y felicidad a largo plazo** — más fuerte que
ingreso, IQ, genes, o clase social. Si LifeOS quiere ser un coach de
vida real, no puede ignorar esto.

**Modelo de datos:**

```sql
CREATE TABLE relationships (
    person_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    relationship_type TEXT NOT NULL,    -- 'partner', 'spouse', 'ex_partner', 'child',
                                        -- 'parent', 'sibling', 'friend', 'colleague',
                                        -- 'mentor', 'extended_family'
    current_stage TEXT,                 -- libre: 'noviazgo', 'casados 5 años',
                                        -- 'distanciamiento', 'reconectando'
    closeness_1_10 INTEGER,             -- subjetivo del usuario, cambia con el tiempo
    important_dates_json TEXT,          -- {"birthday":"03-15","anniversary":"06-20"}
    notes TEXT,
    started_at TEXT,                    -- cuándo entró en la vida del usuario
    ended_at TEXT,                      -- NULL = activa
    encrypted_with TEXT NOT NULL,       -- 'default' o 'user_passphrase'
    source_entry_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE relationship_events (
    event_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    event_type TEXT NOT NULL,           -- 'positive', 'conflict', 'milestone',
                                        -- 'reconnect', 'distance', 'support_given',
                                        -- 'support_received'
    description TEXT NOT NULL,
    user_feeling TEXT,                  -- cómo se sintió el usuario
    occurred_at TEXT NOT NULL,
    encrypted_with TEXT NOT NULL,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE family_members (
    family_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,            -- FK a relationships
    parentesco TEXT NOT NULL,           -- 'mamá', 'papá', 'hermano', 'tía', etc.
    blood_relation INTEGER NOT NULL,    -- 0/1 (importa para historial heredable)
    health_conditions_json TEXT,        -- ['diabetes_t2', 'hipertension'] - puede dispar
                                        -- alertas tipo "tu papá tuvo X a los 50"
    deceased INTEGER NOT NULL DEFAULT 0,
    deceased_at TEXT,
    deceased_cause TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE children_milestones (
    milestone_id TEXT PRIMARY KEY,
    child_person_id TEXT NOT NULL,
    milestone_type TEXT NOT NULL,       -- 'first_word', 'first_step', 'first_day_school',
                                        -- 'tooth', 'vaccine', 'illness', 'achievement'
    description TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    photo_path TEXT,
    permanent INTEGER NOT NULL DEFAULT 1,  -- siempre permanente por diseño
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);
```

**Coaching de relaciones — fuentes de literatura:**

Axi puede recomendar lecturas/recursos basados en investigación
robusta, no en pop-psychology:

- **John Gottman** — "The Seven Principles for Making Marriage Work",
  investigación de 40+ años en parejas, los 4 jinetes del apocalipsis
  (crítica, desprecio, defensividad, evasión).
- **Esther Perel** — "Mating in Captivity", "The State of Affairs",
  podcast "Where Should We Begin?". Trabajo serio sobre intimidad,
  deseo, infidelidad.
- **Gary Chapman** — "The 5 Love Languages". Pop pero útil para
  conversaciones iniciales sobre cómo expresar/recibir afecto.
- **Sue Johnson** — "Hold Me Tight", terapia centrada en emociones
  para parejas, basada en teoría del apego.
- **Brené Brown** — vulnerabilidad, vergüenza, conexión.
- **Adam Grant** — "Give and Take", relaciones de reciprocidad
  saludable.

Axi NO inventa estos consejos — los recomienda como recursos. Si el
usuario dice "siento que me alejo de mi pareja", Axi puede:

1. Preguntar más (sin diagnosticar).
2. Reflejar lo que escucha.
3. Sugerir reflexión: "¿qué crees que cambió?".
4. Recomendar 1-2 recursos específicos basados en el patrón ("lo que
   describes me suena al concepto de 'parallel lives' que Esther Perel
   discute en su libro X").
5. Sugerir acciones concretas pequeñas ("una técnica que algunas
   parejas encuentran útil es la 'cita semanal' sin teléfonos —
   solo 1 hora juntos. ¿Podrían intentarlo?").
6. **Y siempre** recordar que para problemas serios, terapia de pareja
   con un profesional certificado vale infinitamente más que cualquier
   sugerencia de IA.

**Detección de violencia / abuso:**

Si el usuario describe algo que parece violencia doméstica (golpes,
gritos sostenidos, control coercitivo, aislamiento forzado, abuso
económico, abuso sexual), Axi responde con:

1. Validación ("lo que describes no es normal en una relación sana").
2. Sin presionar a "qué vas a hacer".
3. Recursos: en México, **Línea Mujeres CDMX 800 1084**, **Locatel
   55 5658 1111**, **Línea de Atención a Víctimas 800 4623 357**.
4. Recordatorio de seguridad digital ("si crees que alguien revisa
   tu laptop, recuerda que LifeOS tiene modo pánico para borrar
   conversaciones").

### 9b.2 Espiritualidad (BI.10)

**Por qué importa:** La espiritualidad —entendida ampliamente como
sentido de propósito, conexión con algo más grande, contemplación—
correlaciona con menor estrés, mejor salud mental, y mayor longevidad
(meta-análisis de Koenig 2012, Pargament 2013). Esto es válido tanto
para personas religiosas como para las que viven la espiritualidad
de forma secular.

**El error de las apps comerciales:** Headspace y Calm asumen
mindfulness budista como default. Hallow asume catolicismo. La
mayoría de apps tienen una postura. LifeOS NO toma postura.

**Modelo de datos:**

```sql
CREATE TABLE spiritual_practices (
    practice_id TEXT PRIMARY KEY,
    practice_name TEXT NOT NULL,        -- libre: 'meditación', 'oración', 'lectura
                                        -- bíblica', 'caminata en bosque', 'yoga',
                                        -- 'journaling reflexivo', 'silencio contemplativo'
    tradition TEXT,                     -- libre: 'budismo', 'cristianismo', 'secular',
                                        -- 'agnóstico', 'paganismo', 'sin etiqueta'
    frequency TEXT,                     -- 'diaria', 'semanal:3', etc.
    duration_min INTEGER,
    last_practiced TEXT,
    notes TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
);

CREATE TABLE spiritual_reflections (
    reflection_id TEXT PRIMARY KEY,
    topic TEXT,                         -- 'sentido de vida', 'duda', 'gratitud',
                                        -- 'sufrimiento', 'mortalidad', 'propósito'
    content TEXT NOT NULL,              -- entrada narrativa
    encrypted_with TEXT NOT NULL,
    nonce_b64 TEXT,
    ciphertext_b64 TEXT,
    occurred_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE values_compass (
    value_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,                 -- 'familia', 'libertad', 'creatividad',
                                        -- 'servicio', 'honestidad', 'justicia'
    importance_1_10 INTEGER NOT NULL,
    notes TEXT,                         -- por qué importa para el usuario
    defined_at TEXT NOT NULL,
    last_reviewed TEXT,
    created_at TEXT NOT NULL
);
```

**Acompañamiento sin proselitismo:** Axi tiene en su system prompt
una directriz explícita: *"Cuando el usuario hable de espiritualidad,
fe, dudas existenciales, o prácticas contemplativas: NO promuevas
ninguna religión específica, NO descalifiques creencias del usuario,
NO empujes hacia o lejos de prácticas. Acompaña, pregunta, refleja.
Si el usuario es religioso, respeta. Si es ateo, respeta. Si está en
búsqueda, acompaña la búsqueda sin dirigirla."*.

**Recursos generales:**
- Filosofía: Marco Aurelio (estoicismo), Viktor Frankl ("Man's Search
  for Meaning"), Hannah Arendt, Simone Weil.
- Espiritualidad comparada: Karen Armstrong ("A History of God"),
  Mircea Eliade, Joseph Campbell.
- Psicología existencial: Irvin Yalom ("Existential Psychotherapy"),
  Rollo May.
- Mindfulness secular: Jon Kabat-Zinn (MBSR), Sam Harris ("Waking Up").
- Espiritualidad cristiana: Thomas Merton, Henri Nouwen, C.S. Lewis.
- Espiritualidad budista: Pema Chödrön, Thich Nhat Hanh.
- Espiritualidad indígena: Robin Wall Kimmerer ("Braiding Sweetgrass").
- Espiritualidad islámica: Rumi, Al-Ghazali.
- Espiritualidad judía: Abraham Heschel, Martin Buber.

Axi puede sugerir según lo que el usuario explore, sin direccionarlo.

**Conexión con propósito:** una vez que el usuario tiene definido su
`values_compass`, Axi puede preguntar mensualmente: "¿qué hiciste este
mes que sentiste alineado con tus valores? ¿qué hiciste que sentiste
en contra?". Sin sermonear — solo invitando a la reflexión.

### 9b.3 Salud financiera (BI.11)

**Por qué importa:** Las encuestas globales (APA Stress in America,
Gallup) consistentemente identifican **el dinero como la fuente #1
de estrés crónico** en adultos. El estrés financiero crónico está
ligado a hipertensión, diabetes, ansiedad, depresión, y conflictos
de pareja. Si ignoramos las finanzas, ignoramos uno de los drivers
más fuertes de mala salud en todas las demás dimensiones.

**Lo que NO hacemos:**
- NO conectamos a cuentas bancarias vía API. Eso requiere
  certificación PCI-DSS, agreements con bancos, y abre superficie de
  ataque enorme. **Plaid, Belvo, Tink** son las APIs comunes en
  Latinoamérica para esto pero implican enviar datos del usuario a
  un tercero. NO lo hacemos en V1.
- NO recomendamos instrumentos financieros específicos.
- NO predecimos mercados.
- NO somos asesores certificados.

**Lo que SÍ hacemos:**
- Registro manual de ingresos, gastos, deudas, metas.
- Categorización automática (con LLM cuando hay duda).
- Reportes mensuales de "a dónde se fue tu dinero" sin juzgar.
- Educación financiera básica: tasas de interés, interés compuesto,
  fondo de emergencia, priorización de deudas (avalancha vs bola de
  nieve), inversión pasiva (Bogleheads, fondos indexados).
- Alertas suaves cuando hay patrones preocupantes (ej. gastos en
  delivery > X% del ingreso).

**Modelo de datos:**

```sql
CREATE TABLE financial_accounts (
    account_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,                 -- 'BBVA débito', 'efectivo', 'cetes', 'tarjeta X'
    account_type TEXT NOT NULL,         -- 'checking', 'savings', 'investment',
                                        -- 'credit_card', 'loan', 'cash'
    institution TEXT,                   -- libre
    balance_last_known REAL,            -- usuario lo actualiza manualmente
    balance_currency TEXT NOT NULL DEFAULT 'MXN',
    balance_updated_at TEXT,
    notes TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
);

CREATE TABLE expenses (
    expense_id TEXT PRIMARY KEY,
    amount REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'MXN',
    category TEXT NOT NULL,             -- 'comida', 'transporte', 'vivienda',
                                        -- 'salud', 'entretenimiento', 'ropa', etc.
    description TEXT,
    payment_method TEXT,                -- FK opcional a financial_accounts
    receipt_path TEXT,                  -- foto del ticket cifrada (opcional)
    occurred_at TEXT NOT NULL,
    source_entry_id TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE income_log (
    income_id TEXT PRIMARY KEY,
    amount REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'MXN',
    source TEXT NOT NULL,               -- 'salario', 'freelance', 'renta', 'venta'
    description TEXT,
    received_at TEXT NOT NULL,
    recurring INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE financial_goals (
    goal_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,                 -- 'fondo emergencia 6 meses', 'pagar tarjeta X',
                                        -- 'enganche casa', 'viaje Japón'
    target_amount REAL NOT NULL,
    target_currency TEXT NOT NULL DEFAULT 'MXN',
    target_date TEXT,
    current_amount REAL NOT NULL DEFAULT 0,
    notes TEXT,
    status TEXT NOT NULL,               -- 'active', 'achieved', 'paused', 'abandoned'
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

**Recursos educativos:**
- **Ramit Sethi** — "I Will Teach You to Be Rich", específicamente
  pragmático.
- **Bogleheads Wiki** — para inversión pasiva.
- **Financial Independence (FIRE) movement** — para metas de
  retiro temprano.
- **Sofía Macías** — "Pequeño cerdo capitalista", específico para
  finanzas personales en México.
- **CONDUSEF** — recursos oficiales mexicanos sobre productos
  financieros y derechos del consumidor.

### 9b.4 Salud sexual (BI.12)

**Por qué importa:** La salud sexual es parte integral de la salud
general (definición OMS). En México, hay tabú cultural significativo
para hablar de sexo con médicos — los usuarios buscan información en
internet, donde encuentran desinformación. Axi puede ser un espacio
sin tabú para preguntas honestas y registro seguro.

**Categoría sensible** — trato similar a mental health.

**Modelo de datos:**

```sql
CREATE TABLE sexual_health (
    record_id TEXT PRIMARY KEY,
    record_type TEXT NOT NULL,          -- 'sti_test', 'contraception',
                                        -- 'reproductive_health', 'consultation'
    description TEXT NOT NULL,
    result TEXT,                        -- 'negative', 'positive', etc.
    related_treatment TEXT,
    encrypted_with TEXT NOT NULL,
    nonce_b64 TEXT,
    ciphertext_b64 TEXT,
    occurred_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE intimacy_log (
    entry_id TEXT PRIMARY KEY,
    libido_1_10 INTEGER,
    satisfaction_1_10 INTEGER,
    notes TEXT,
    encrypted_with TEXT NOT NULL,
    nonce_b64 TEXT,
    ciphertext_b64 TEXT,
    occurred_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

**Educación:**
- Información factual sobre ITS, métodos anticonceptivos, fertilidad,
  menopausia, andropausia, función sexual.
- Sin juzgar, sin moralizar, sin direccionar.
- Para problemas específicos (disfunción, dolor, infertilidad),
  recomendar profesional (ginecólogo, urólogo, sexólogo certificado).

**Detección de abuso sexual:** patrones explícitos → respuesta con
recursos:
- México: **Línea Mujeres CDMX 800 1084**, **Locatel 55 5658 1111**.
- A nivel federal: **Centro Nacional de Equidad de Género y Salud
  Reproductiva** (CNEGSR).
- Internacional: **RAINN** (rainn.org) para referencias globales.

### 9b.5 Salud social y comunitaria (BI.13)

**Por qué importa:** Robert Putnam ("Bowling Alone", 2000) documentó
el declive del capital social en USA y su correlación con peor salud
y menor satisfacción de vida. Estudios subsecuentes en países
desarrollados encuentran patrones similares — la soledad crónica
está asociada a mortalidad equivalente a fumar 15 cigarros al día
(Holt-Lunstad meta-analysis 2010). LifeOS no puede ignorar esto.

**Modelo de datos:**

```sql
CREATE TABLE community_activities (
    activity_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,                 -- 'club de lectura', 'parroquia', 'voluntariado X',
                                        -- 'liga de futbol', 'grupo de meditación'
    activity_type TEXT NOT NULL,        -- 'religious', 'sport', 'volunteer', 'hobby',
                                        -- 'professional', 'educational', 'civic'
    frequency TEXT,                     -- 'semanal', 'mensual'
    last_attended TEXT,
    notes TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
);

CREATE TABLE civic_engagement (
    engagement_id TEXT PRIMARY KEY,
    engagement_type TEXT NOT NULL,      -- 'vote', 'volunteer', 'donation', 'protest',
                                        -- 'town_hall', 'community_meeting'
    description TEXT,
    occurred_at TEXT NOT NULL,
    notes TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE contribution_log (
    contribution_id TEXT PRIMARY KEY,
    description TEXT NOT NULL,          -- 'ayudé a vecino con compras', 'doné sangre',
                                        -- 'enseñé a sobrino a programar'
    beneficiary TEXT,
    occurred_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

**Coaching:**
- Si Axi nota que el usuario no ha registrado actividad comunitaria
  en N meses, puede preguntar gentilmente "¿hace cuánto que no vas a
  [grupo]? ¿lo extrañas?".
- La gratitud por contribuir está ligada al bienestar — Axi puede
  preguntar semanalmente "¿hubo algún momento esta semana donde
  ayudaste a alguien?".
- Sin presionar.

### 9b.6 Sueño profundo (BI.14)

**Por qué importa:** El sueño es **una de las palancas más poderosas**
para todas las demás dimensiones. Matthew Walker ("Why We Sleep",
2017) sintetiza décadas de evidencia: dormir mal afecta sistema
inmune, regulación de glucosa, salud cardiovascular, regulación
emocional, memoria, y función cognitiva. Una sola noche de 4h baja
las natural killer cells un 70%.

**Modelo de datos:**

```sql
CREATE TABLE sleep_log (
    sleep_id TEXT PRIMARY KEY,
    bedtime TEXT NOT NULL,              -- RFC3339
    wake_time TEXT NOT NULL,
    duration_hours REAL NOT NULL,       -- calculado pero guardado por queries rápidas
    quality_1_10 INTEGER,
    interruptions INTEGER NOT NULL DEFAULT 0,
    dreams_notes TEXT,
    feeling_on_wake TEXT,               -- 'descansado', 'cansado', 'irritable'
    created_at TEXT NOT NULL
);

CREATE TABLE sleep_environment (
    env_id TEXT PRIMARY KEY,
    sleep_id TEXT NOT NULL,             -- FK a sleep_log
    room_temperature_c REAL,
    darkness_1_10 INTEGER,
    noise_1_10 INTEGER,
    screen_use_before_bed INTEGER,      -- minutos
    caffeine_after_2pm INTEGER NOT NULL DEFAULT 0,
    alcohol INTEGER NOT NULL DEFAULT 0,
    heavy_dinner INTEGER NOT NULL DEFAULT 0,
    exercise_intensity_today TEXT,      -- 'none', 'light', 'moderate', 'intense'
    notes TEXT,
    created_at TEXT NOT NULL
);
```

**Coaching de higiene del sueño** (no controversial, bien establecido):

- Horario consistente (incluyendo fines de semana).
- Cuarto fresco (16-19°C ideal).
- Oscuridad total (cortinas blackout, parchear LEDs de electrónicos).
- Sin pantallas 1h antes de dormir.
- Sin cafeína después de 2pm.
- Sin alcohol cerca de dormir (sí ayuda a caer pero arruina la
  arquitectura del sueño).
- Cena ligera.
- Ejercicio moderado durante el día (no en las 3h previas).
- Cama solo para dormir (no trabajo).
- Si no puedes dormir en 20min, levantarte y hacer algo aburrido en
  otro cuarto.

**Lo que NO hace:**
- NO diagnostica trastornos del sueño (apnea, narcolepsia, parasomnias).
- NO recomienda pastillas para dormir.
- Si el usuario reporta insomnio crónico, ronquidos severos, apneas
  presenciales reportadas por la pareja, o somnolencia diurna
  excesiva → recomienda evaluación con especialista en medicina del
  sueño.

---

## 10. Capa de coaching unificada (BI.8)

Esta es la culminación. Sin BI.1-BI.7 no hay datos suficientes; con
ellos, Axi empieza a sintetizar.

### 10.1 Resúmenes semanales/mensuales

Cada domingo noche (configurable) Axi corre una rutina:

```
Pseudocódigo:
1. Pull last 7 days from health_vitals, nutrition_log, exercise_log,
   mental_health_journal (si está abierto), habit_log, sleep_data.
2. Build a structured "week digest" prompt for the LLM.
3. LLM produces a short narrative summary in Spanish:
   "Esta semana comiste mejor que la anterior (más verduras, menos
   azúcar). Tres días de ejercicio. Dormiste un promedio de 7.2h
   (mejor que la semana pasada de 6.5h). Tu glucosa en ayunas bajó
   de 115 a 108. Hubo un día de migraña fuerte el jueves. Cumpliste
   tu hábito de meditar 5/7 días. ¿Qué te gustaría cambiar la
   próxima semana?"
4. Saved as memory_entries with kind="weekly_summary",
   permanent=1, importance=85.
```

Estos summaries son lo que Axi recuerda con facilidad meses después
("hace 6 meses tu glucosa estaba en 115, hoy está en 92, llevas un
camino increíble").

### 10.2 Detección de patrones cruzados

**Sin diagnosticar**, Axi puede notar correlaciones:

- "He notado que las migrañas suelen aparecer dentro de 24h después
  de comer algo con cafeína después de las 6pm. ¿Has notado eso tú?"
- "Tu glucosa ha estado más alta los días que haces menos de 30
  minutos de actividad. ¿Te gustaría que lo exploremos?"
- "Tu estado de ánimo en el journal se siente más bajo los lunes.
  ¿Quieres que pensemos juntos por qué?"

Estas observaciones se generan con queries SQL deterministas + un LLM
que las **convierte a lenguaje natural empático**, NO con un LLM
analizando datos crudos.

### 10.3 Preparación para visitas médicas

Comando explícito: "Axi, mañana voy al doctor por mi diabetes". Axi
responde con un resumen estructurado:

```markdown
# Resumen para tu consulta del 2026-04-07

## Diagnóstico activo
- Diabetes tipo 2 (registrada: 2024-01-12)

## Medicamentos actuales
- Metformina 850mg / 12h (desde 2024-08-20)
- Sitagliptina 100mg / 24h (desde 2025-03-10)

## Vitales recientes (últimos 30 días)
- Glucosa en ayunas (12 lecturas): promedio 108 mg/dL, rango 95-125
- Peso: 78.5 kg (hace 90 días: 81.2 kg, -2.7 kg)
- Presión: promedio 122/78 (estable)

## Análisis de laboratorio recientes
- HbA1c (2026-03-15): 6.4% (referencia: <5.7% normal, 5.7-6.4% prediabetes)
- LDL (2026-03-15): 110 mg/dL (referencia: <100)

## Eventos relevantes
- Ejercicio: 14 sesiones en los últimos 30 días (caminar + bicicleta)
- Episodios reportados: 1 hipoglucemia leve (2026-03-22, post-ejercicio)

## Preguntas que tal vez quieras hacerle al médico
1. ¿Es momento de reducir alguna dosis dado que la glucosa va bajando?
2. ¿Qué objetivo de HbA1c es razonable para mí?
3. ¿El LDL en 110 amerita estatinas o puedo seguir con cambios de dieta?

[Generado por LifeOS — para consulta con tu médico, no es diagnóstico]
```

El usuario puede copiar esto, imprimirlo, mandarlo por email, o
mostrarle el celular al doctor. Es **información objetiva del propio
usuario**, no inferencias.

### 10.4 Chequeo proactivo de no-olvido

Esto resuelve el caso original que motivó toda esta fase: "tenía un
proyecto pausado y Axi se olvidó".

Cada N días (mensual por default), Axi corre:

```sql
SELECT * FROM memory_entries
WHERE importance >= 30
  AND last_accessed < date('now', '-60 days')
  AND created_at < date('now', '-90 days')
  AND (kind LIKE '%project%' OR kind LIKE '%goal%' OR kind LIKE '%idea%')
ORDER BY importance DESC
LIMIT 5;
```

Para cada resultado, Axi pregunta proactivamente: "Hace 3 meses
mencionaste que querías retomar [X], ¿sigue en pie?". Sin presionar,
solo recordando.

---

## 11. Prior art comparado

| Producto | Categoría | Pros | Cons que LifeOS resuelve |
|---|---|---|---|
| **Apple Health** | Plataforma agregadora salud | Nativo en iOS, importa de muchas fuentes | iCloud por default, no exportable bien, no sintetiza, no conversa, no en otras plataformas |
| **MyFitnessPal** | Tracking de comida | Catálogo enorme | Cloud, ads, freemium agresivo, datos vendidos, sin contexto cross-domain |
| **Cronometer** | Tracking de comida pro | Más preciso que MFP, foco en micros | Cloud, suscripción, sin coaching |
| **Strava** | Ejercicio + social | Excelente para deporte | Cloud, social-first (privacy issues), no acompaña salud general |
| **Headspace / Calm** | Meditación / mental | Buen contenido guiado | Cloud, suscripción, contenido enlatado, no personalizado |
| **Flo / Clue** | Ciclo menstrual | UI excelente | Cloud, controversia post-Roe, datos vendidos (Flo en 2021) |
| **MacroFactor** | Tracking de comida + adaptación | Algoritmo adaptativo | Cloud, suscripción, foco en pérdida de peso |
| **Notion / Obsidian** | Notas estructuradas | Local-first (Obsidian), flexible | No tienen schemas para salud, todo es texto libre, sin coaching |
| **GNU Health** | Sistema clínico open source | Robusto, FOSS | Diseñado para clínicas/hospitales, no para una persona, complejidad enorme |
| **OpenEMR** | Sistema clínico open source | Robusto, FOSS | Igual: B2B, no para usuario final |
| **Sleep as Android** | Tracking de sueño | Bueno para una métrica | Una sola dimensión |
| **Habitica** | Tracking de hábitos gamificado | Divertido | Cloud, gimmicky, no integra salud |
| **Daylio** | Diario de ánimo | Simple, mobile-first | Cloud, móvil only, sin acompañamiento |
| **Reflectly** | Diario guiado | UX bonita | Cloud, suscripción, IA propietaria |
| **Replika / Pi** | AI companion | Conversacional | Cloud, privacidad cuestionable, modelo cerrado, sin memoria estructurada |
| **Lasting / Paired / Relish** | Apps de coaching de pareja | Contenido curado por terapeutas | Cloud, suscripción, sin contexto del resto de la vida |
| **Insight Timer** | Meditación multi-tradición | Mejor que Headspace en diversidad | Cloud, freemium, sin acompañamiento personal |
| **Hallow** | Oración católica | Excelente para ese nicho | Solo para católicos, cloud, suscripción |
| **YNAB / Monarch** | Presupuesto / finanzas | Excelente filosofía | Cloud, suscripción, requiere link a cuentas |
| **Mint** (descontinuado 2024) | Tracking financiero | Era gratuito | Murió cuando Intuit lo cerró — lección de lock-in |
| **Pequeño Cerdo Capitalista app** | Educación financiera MX | Específico para México | Limitado en alcance |
| **PrEP/PEP apps, Healthvana** | Salud sexual | Foco específico | Cloud, datos médicos sensibles en tercero |
| **Nextdoor** | Comunidad vecinal | Conexión local | Privacy issues serios, cloud, social |
| **Meetup** | Grupos de interés | Útil para descubrir | Solo descubrir, no llevar registro personal |
| **Sleep Cycle** | Tracking de sueño | Funciona razonable | Cloud, móvil, una sola dimensión |

**Conclusión:** ningún producto cubre las 5 propiedades simultáneamente:
local-first + privado + conversacional + cross-domain + sin lock-in. La
mayoría son verticales de uno o dos dominios. Los que abarcan más
(Apple Health) son lectores pasivos sin coaching real.

LifeOS puede ser **el primero** que une todo en una sola memoria
unificada, conversacional y local. Es un nicho real con valor real.

---

## 12. Modos de fallo conocidos

### 12.1 LLM hallucina dosis o medicamento

**Riesgo:** el LLM, al resumir o describir un evento médico, inventa
una dosis ("metformina 5000mg") o un nombre de medicamento que no
existe.

**Mitigación:**
- Las dosis y nombres NUNCA vienen del LLM solo. Siempre vienen de
  input del usuario o de la receta escaneada con confirmación
  explícita ("¿correcto que esto dice metformina 850mg cada 12h?").
- En las queries que devuelven medicamentos, Axi lee directamente de
  `health_medications` y los presenta literal, no parafraseados.
- Cualquier mención a un medicamento en respuesta a una pregunta del
  usuario se valida contra `health_medications` antes de mandar la
  respuesta. Si el LLM mencionó algo que no está en la tabla, se le
  pide al LLM regenerar.

### 12.2 Usuario sobre-confía en Axi y no ve médico real

**Riesgo:** Axi se vuelve tan bueno acompañando que el usuario deja de
buscar atención profesional cuando la necesita.

**Mitigación:**
- Disclaimers periódicos explícitos.
- Recomendación activa de profesionales en eventos clave: "ese
  síntoma merece que veas a un médico, ¿quieres que te ayude a
  encontrar uno cerca?".
- Detección de patrones que requieren atención (síntomas que persisten
  más de N días, dolor severo, fiebre alta prolongada, etc.) → Axi
  automáticamente sugiere ir al médico.

### 12.3 Datos en disco accesibles a familiares

**Riesgo:** alguien con acceso físico a la laptop puede leer todo lo
descifrado en sesión activa.

**Mitigación:**
- Auth secundaria opt-in para categorías sensibles (mental, ciclo).
- Lock automático del daemon después de N min de inactividad.
- El usuario debería bloquear su sesión OS — esto es responsabilidad
  del sistema operativo, no de LifeOS, pero documentamos la
  recomendación.
- Modo pánico para borrado seguro.

### 12.4 Subpoena legal / acceso forzado

**Riesgo:** un juez ordena acceso al disco. El usuario está en
contexto legal donde los datos son evidencia.

**Mitigación:**
- Cifrado en disco con clave default es resistente a casual access
  pero NO a forensics serio si el atacante tiene la passphrase del
  usuario o acceso al binario.
- Para mental + ciclo, la passphrase derivada Argon2id es lo más
  fuerte que ofrece SQLite local sin hardware attestation.
- Modo pánico es la mitigación final: si el usuario sabe que viene
  un riesgo, puede borrar antes de que llegue.
- Este es un trade-off honesto: LifeOS no puede garantizar contra
  forensics estatal serio. Lo dice explícitamente en la
  documentación de privacidad.

### 12.5 Crecimiento del DB con muchos años de datos

**Riesgo:** después de 10 años de tracking diario, ¿la DB explota?

**Estimación:**
- `health_vitals`: 5 lecturas/día × 365 × 10 años = 18,250 rows. ~2 MB.
- `nutrition_log`: 4 entradas/día × 365 × 10 = 14,600 rows. ~5 MB sin
  fotos. Con fotos a 200KB cifradas: 14,600 × 200KB = 2.8 GB.
- `mental_health_journal`: 1 entrada/día × 365 × 10 = 3,650 rows. ~10 MB.
- `exercise_log`: 4 sesiones/semana × 52 × 10 = 2,080 rows. ~1 MB.

**Total estimado a 10 años:** ~3 GB principalmente por las fotos de
comida. Sin fotos, ~30 MB. Trivial.

**Mitigación:** las fotos se pueden archivar (mover a archivo aparte
y guardar solo thumbnail) después de N meses si el usuario lo activa.

---

## 13. Liability y disclaimers obligatorios

**LifeOS NO es:**
- Un dispositivo médico
- Un servicio médico
- Un servicio de salud mental
- Un servicio de nutrición
- Un servicio de farmacia
- Un servicio de fitness profesional
- Un servicio de terapia de pareja o familiar
- Un servicio de consejería matrimonial
- Una guía espiritual ni religiosa
- Un asesor financiero certificado ni una casa de bolsa
- Un servicio de educación sexual médica certificado
- Un servicio de medicina del sueño

**LifeOS ES:**
- Una herramienta de software local que ayuda al usuario a llevar
  registro de su propia información de salud y hábitos.
- Un asistente conversacional que ofrece sugerencias generales no
  prescriptivas.
- Un sistema de recordatorios para tomar medicamentos según
  indicación del médico real del usuario.

**Disclaimer en el README + en el dashboard:**

> LifeOS es una herramienta para llevar registro personal de salud,
> hábitos y bienestar. NO es un sustituto de atención médica, terapia
> psicológica, asesoría nutricional ni entrenamiento físico profesional.
> Si tienes una condición médica, consulta con un profesional de salud
> certificado. En caso de crisis de salud mental, llama a SAPTEL
> (55 5259 8121) o a Línea de la Vida (800 290 0024). LifeOS no se
> hace responsable por decisiones tomadas con base en su contenido.

Este disclaimer aparece:
- En el README del repo.
- En el dashboard, en la primera apertura del tab de salud.
- En la primera respuesta de Axi en cada conversación que toca un
  dominio médico.
- En cada `health_summary` exportado.

---

## 14. MVP roadmap (BI.1 → BI.8)

Orden recomendado de implementación. Cada paso es autocontenido y
entregable; cada uno desbloquea el siguiente.

**Sprint 1 — BI.1: Nunca perder nada (la base universal)**
- Estimación: 1 turno de coding + tests.
- Pre-requisito de TODO el resto.
- Resuelve los casos del usuario "proyecto pausado" y "idea olvidada"
  inmediatamente, antes de tocar nada de salud.
- Detalles técnicos: cambiar GC delete → GC archive en `apply_decay`,
  nuevo tool `recall_archived`, auto-permanent para kinds de salud.

**Sprint 2 — BI.2: Salud médica estructurada**
- Estimación: 2-3 turnos.
- Side-tables: `health_facts`, `health_medications`, `health_vitals`,
  `health_lab_results`, `health_attachments`.
- Migrations idempotentes en `run_migrations`.
- API Rust + tests.
- Integración con vision pipeline para recetas en foto.
- 5-7 tools nuevos en `telegram_tools.rs`.

**Sprint 3 — BI.3: Nutrición**
- Estimación: 2-3 turnos.
- `nutrition_log`, `nutrition_preferences`, `nutrition_recipes`,
  `nutrition_plans`.
- Tabla `nutrition_food_db` precargada (USDA + Open Food Facts MX +
  SMAE).
- Pipeline de ingest desde foto.
- Generador de listas de compras.

**Sprint 4 — BI.5: Ejercicio**
- Estimación: 1-2 turnos.
- `exercise_log`, `exercise_inventory`, `exercise_plans`.
- Generador de rutinas hardware-aware.
- Tools.

**Sprint 5 — BI.7: Crecimiento personal**
- Estimación: 1-2 turnos.
- `reading_log`, `habits`, `habit_log`, `growth_goals`.
- Reminder diario opcional.
- Tools.

**Sprint 6 — BI.6: Salud femenina (opt-in)**
- Estimación: 1-2 turnos.
- `menstrual_cycle` con cifrado reforzado.
- Modo pánico.
- Predicciones simples basadas en historial propio.
- Tools.

**Sprint 7 — BI.4: Salud mental (la más sensible)**
- Estimación: 2-3 turnos.
- `mental_health_journal` con cifrado reforzado (Argon2id).
- Auth secundaria.
- Detección de crisis con respuestas deterministas.
- Disclaimer.
- Modo pánico.
- Hotlines integradas.
- **Esta sub-fase debería ser revisada por un profesional de salud
  mental antes de shippear.**

**Sprint 8 — BI.8: Coaching unificado**
- Estimación: 2-3 turnos.
- Resúmenes semanales/mensuales automáticos.
- Detección de patrones cruzados.
- Preparación para visitas médicas.
- Chequeo proactivo de no-olvido.

**Sprint 9 — BI.3.1: Comercio local**
- Estimación: 1-2 turnos.
- `local_commerce_products`, `local_commerce_stores`.
- Catálogo base mexicano precargado.
- Expansión conversacional.
- Filtrado de listas de compras.

**Sprint 10 — BI.9: Relaciones humanas**
- Estimación: 2-3 turnos.
- `relationships`, `relationship_events`, `family_members`,
  `children_milestones`.
- Cifrado reforzado para `relationship_events` (puede contener
  contenido sensible: discusiones, infidelidad, abuso).
- Detección de patrones de violencia + recursos automáticos.
- Recomendador de literatura/recursos basado en el tipo de problema.
- Tools de coaching de relaciones.

**Sprint 11 — BI.10: Espiritualidad**
- Estimación: 1-2 turnos.
- `spiritual_practices`, `spiritual_reflections`, `values_compass`.
- Cifrado reforzado opcional para `spiritual_reflections`.
- Directrices estrictas en system prompt: NO proselitismo, NO
  descalificación.
- Recomendador de recursos multi-tradición.

**Sprint 12 — BI.11: Salud financiera**
- Estimación: 2-3 turnos.
- `financial_accounts`, `expenses`, `income_log`, `financial_goals`.
- Categorización automática de gastos con LLM (con confirmación).
- Reportes mensuales sin juzgar.
- Pipeline de ingest de tickets desde foto.
- Alertas suaves de patrones.

**Sprint 13 — BI.12: Salud sexual**
- Estimación: 1-2 turnos.
- `sexual_health`, `intimacy_log`.
- Cifrado reforzado obligatorio (mismo nivel que mental).
- Modo pánico activo.
- Educación factual sin tabú.
- Detección de abuso + recursos.

**Sprint 14 — BI.13: Salud social y comunitaria**
- Estimación: 1 turno.
- `community_activities`, `civic_engagement`, `contribution_log`.
- Sin cifrado reforzado (no es categoría sensible en general).
- Sugerencias proactivas suaves.

**Sprint 15 — BI.14: Sueño profundo**
- Estimación: 1-2 turnos.
- `sleep_log`, `sleep_environment`.
- Coaching de higiene del sueño.
- Detección de patrones cruzados con otras dimensiones.

**Estimación total revisada:** ~25-30 turnos de coding + tests para
todo el pillar BI completo (las 14 sub-fases). Spread a lo largo de
varios meses al ritmo sustentable de un developer. **Importante:**
no es necesario hacer todas — el usuario puede priorizar las que
más le importan y dejar otras como opcionales o futuras.

---

## 15. Criterios de no-go

Hay 5 escenarios donde abortamos esta fase y volvemos a un alcance
más reducido:

1. **Si la detección de crisis genera más del 1% de falsos positivos
   o falsos negativos** durante el dogfooding interno, paramos BI.4
   hasta tener supervisión profesional.
2. **Si los disclaimers no son suficientes para protegernos
   legalmente** según un abogado mexicano, reescribimos el alcance
   antes de seguir. Los datos siguen siendo del usuario, pero LifeOS
   tal vez se posicione como "registro de bitácora" sin coaching
   activo en dominios médicos.
3. **Si el catálogo nutricional generado por LLM tiene >10% de error
   en macros** sobre alimentos comunes mexicanos, no shippeamos
   estimaciones automáticas — solo permitimos input manual del
   usuario.
4. **Si los usuarios reportan que la passphrase para mental health es
   demasiada fricción**, evaluamos si la salvaguarda vale el costo
   de UX. Pero la respuesta default es: la fricción es intencional.
5. **Si en algún momento LifeOS recibe una orden judicial relacionada
   con datos de un usuario**, la fase entra en revisión legal
   inmediata. Documentamos la situación públicamente y consultamos.

---

## 16. Próximos pasos concretos

1. Revisar este doc con el usuario y validar prioridades.
2. Empezar Sprint 1 (BI.1) cuando tenga luz verde.
3. Antes del Sprint 7 (BI.4 mental), buscar a un profesional de salud
   mental para revisar la lista de patrones de crisis y los
   disclaimers.
4. Antes del Sprint 9 (BI.3.1 comercio local), validar con un usuario
   real (Hector) que el catálogo base mexicano cubre su realidad.
5. Documentar en el README principal de LifeOS qué hace BI y qué NO
   hace, con disclaimers visibles.

---

## Notas finales

- Este documento se actualiza cada vez que aprendemos algo nuevo.
- El prior art en wellness apps cambia rápido — la lista de la sección
  11 puede estar desactualizada en 6 meses.
- Las salvaguardas de salud mental deben ser revisadas por un
  profesional ANTES de shippear esa sub-fase.
- Esta fase es lo que diferencia a LifeOS del resto de los AI
  assistants. Vale la pena hacerlo bien.
