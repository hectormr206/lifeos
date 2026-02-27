# El Modelo Biológico de LifeOS: Aprendiendo de OpenClaw

La investigación sobre **OpenClaw** muestra que su diferencial no fue solo "tener tools", sino formalizar una **arquitectura de identidad**. El agente no es un script efímero: es un sistema con memoria, límites y continuidad operativa.

Aplicar este enfoque en **LifeOS** es clave para que el sistema no sea solo "Linux + LLM", sino un entorno que aprende sin perder control, privacidad ni recuperabilidad.

---

## 1. El Archivo `Soul` (El Alma del Sistema)

En OpenClaw, `soul.md` define personalidad, directivas y comportamiento base.

**Perspectiva para LifeOS (Núcleo Cognitivo):**
No buscamos un bot genérico; buscamos que el OS se adapte a cada persona.

- **Propuesta de integración:** `Soul` por usuario en `~/.config/lifeos/soul/`.
- **Guardrails globales opcionales:** baseline corporativo en `/etc/lifeos/soul.defaults/` (solo lectura).
- **Composición recomendada:** `baseline global -> soul de usuario -> overrides por Workplace`.
- **Biología:** como el ADN, el `Soul` define estilo de interacción, límites de autonomía y respuesta bajo estrés (batería baja, red inestable, contexto sensible).

## 2. La Carpeta `Skills` (Habilidades Adquiridas)

OpenClaw usa un framework donde el agente crea y almacena habilidades reutilizables.

**Perspectiva para LifeOS (Sistema Nervioso Motor):**
Hoy tenemos comandos estáticos (`life update`, `life status`), pero falta memoria operativa acumulativa.

- **Propuesta de integración:** `~/.local/share/lifeos/skills/` para skills auto-generadas y reutilizables.
- **Flujo mínimo:** generar -> validar -> ejecutar en sandbox -> firmar -> publicar localmente.
- **Biología:** esto es memoria muscular; la segunda ejecución no "piensa desde cero", reutiliza lo aprendido con menor costo energético.

## 3. La Carpeta `Workplace` (El Entorno Sensorial)

OpenClaw llama *Workplace* al contexto digital accesible para el agente.

**Perspectiva para LifeOS (Hábitat Digital):**
LifeOS tiene ventaja estructural porque controla el entorno completo.

- **Propuesta de integración:** mapear `Workplace` a **COSMIC Workspaces** dinámicos (`Desarrollo`, `Finanzas`, `Gaming`, etc.).
- **Política contextual:** cada Workplace aplica perfiles de permisos/red/sensores distintos.
- **Biología:** el organismo activa sentidos diferentes según hábitat; en "Finanzas" endurece red y sensores, en "Desarrollo" prioriza toolchain.

## 4. La Carpeta `Agents` (Sistema Inmunológico y Enjambre)

OpenClaw delega capacidades en sub-identidades. Ese patrón es útil, pero en LifeOS debe ser explícitamente gobernado por políticas.

- **Propuesta de integración:** formalizar `Swarm Routing` con catálogo en `/usr/share/lifeos/agents/`.
- **Roles sugeridos:**
  - _Agente Macrófago (Auditor):_ modelo pequeño (1B) para detección de anomalías en logs.
  - _Agente Motor (Executor):_ ejecuta acciones operativas con tokens de capacidad y sandbox.
  - _Agente Córtex (Planner):_ modelo pesado (`llama-server`, 8B+) para planificación y tareas complejas.
- **Regla de oro:** ningún agente ejecuta fuera de política, aunque "el prompt lo pida".

## 5. La `Life Capsule` (Replicación y Recuperación)

Un sistema "biológico" que no puede recuperarse o migrar de host no es resiliente.

- **Propuesta de integración:** `life capsule export/restore` debe incluir `soul` de usuario, `skills`, memoria vectorial y estado de Workplaces.
- **Requisito de seguridad:** cifrado E2E + firma + restauración selectiva por componente.
- **Biología:** es mitosis operativa; el organismo se recrea en otro hardware sin perder identidad.

---

## 6. Decisiones Recomendadas para LifeOS

1. **`Soul` por usuario desde Fase 2:** `~/.config/lifeos/soul/` como fuente primaria, con guardrails globales opcionales.
2. **Firma de `Skills`: modelo híbrido (recomendado):**
   - `core`: firmado por clave raíz de LifeOS.
   - `verified`: firmado por mantenedor delegado + validación de pipeline de LifeOS.
   - `community/local`: permitido, pero con sandbox estricto y permisos mínimos por defecto.
3. **SLO CVE por severidad (recomendado):**
   - `critical`: mitigación <= 24h (o bloqueo de feature) y parche validado <= 48h.
   - `high`: parche validado <= 72h.
   - `medium`: <= 14 días.
   - `low`: siguiente release de mantenimiento.

## 7. Roadmap: Qué agregar o reforzar en fases

1. **Fase 1:** Heartbeats + broker de permisos por Workplace + Prompt Shield.
2. **Fase 2:** `Soul Plane` por usuario, `Skills Plane` con firma híbrida y awareness de COSMIC Workspaces.
3. **Fase 3:** `Life Capsule v2` con restauración selectiva y federación de firma para ecosistema de skills.

Si ejecutamos esto con disciplina, LifeOS no será "un asistente en Linux", sino un entorno operativo con identidad, memoria y control real de riesgo.
