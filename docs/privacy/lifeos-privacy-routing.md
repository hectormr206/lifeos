# Resumen de Privacidad para LifeOS: Analisis Comparativo de Proveedores LLM

**Fecha:** 2026-03-28
**Contexto:** Este documento sintetiza las politicas de privacidad de los proveedores LLM que LifeOS utiliza o puede utilizar a traves de `llm_router.rs`, y establece recomendaciones concretas para el enrutamiento basado en sensibilidad de datos.

**Fuentes:** Documentos en `docs/Privacidad de la informacion/` (claude.md, gemini.md, openai.md, grok.md, kimi.md, qwen.md, zai.md) — analisis de la paradoja de privacidad y capitalismo de vigilancia por cada proveedor, cruzados con las politicas oficiales de API de cada empresa.

---

## 1. Tabla Comparativa de Proveedores

| Proveedor | Entrena con datos API? | Retencion de datos | ZDR disponible? | Servidores | Jurisdiccion | Puede compartir con gobierno? | Incidentes conocidos | Tier en LifeOS |
|---|---|---|---|---|---|---|---|---|
| **Local (Qwen3.5-4B)** | No aplica | No aplica (todo local) | Si (inherente) | Tu maquina | Tu jurisdiccion | No (datos nunca salen) | N/A | `Local` |
| **Cerebras** | No | Zero data retention | Si (por defecto) | EE.UU. (Sunnyvale, CA) | Ley de EE.UU. | Potencialmente (CLOUD Act) | Ninguno conocido | `Free` |
| **Groq** | No | Zero data retention | Si (por defecto) | EE.UU. | Ley de EE.UU. | Potencialmente (CLOUD Act) | Ninguno conocido | `Free` |
| **Anthropic (Claude)** | No en API | 30 dias (seguridad/abuso), no entrena | Disponible para Enterprise | EE.UU. (AWS us-east/west) | Ley de EE.UU. | Si (CLOUD Act, orden judicial) | Ninguno conocido | `Premium` |
| **OpenAI (GPT)** | No en API (desde marzo 2023) | 30 dias (abuso), opt-out disponible | Si (API por defecto desde 2023) | EE.UU. (Azure) | Ley de EE.UU. | Si (CLOUD Act) | Filtracion ChatGPT historial 2023, datos Samsung | `Premium` |
| **Google (Gemini)** | **SI en tier gratuito** | Hasta 18 meses en tier gratuito | Solo en tier de pago (Vertex AI) | EE.UU., global | Ley de EE.UU. + GDPR si EU | Si (CLOUD Act, FISA 702) | Multiples multas GDPR, historial de vigilancia | `Free` (RIESGO) |
| **xAI (Grok)** | **SI** (mejora de productos) | Retencion indefinida posible | No claramente disponible | EE.UU. | Ley de EE.UU. | Si (CLOUD Act) | Vinculacion con datos de X/Twitter | `Free` |
| **Z.AI / Zhipu (GLM)** | **Probable** (politica opaca) | No especificado claramente | No disponible | **China** (Beijing) | **Ley de ciberseguridad china, PIPL** | **Si (obligatorio por ley china)** | Opacidad regulatoria | `Cheap` |
| **Moonshot (Kimi)** | **Probable** (politica opaca) | No especificado claramente | No disponible | **China** (Beijing) | **Ley de ciberseguridad china, PIPL** | **Si (obligatorio por ley china)** | Opacidad regulatoria | `Cheap` |
| **MiniMax** | **Probable** (politica opaca) | No especificado claramente | No disponible | **China** (Shanghai) | **Ley de ciberseguridad china, PIPL** | **Si (obligatorio por ley china)** | Opacidad regulatoria | `Cheap` |
| **OpenRouter** | Depende del modelo subyacente | Transitorio (proxy) | Depende del modelo final | EE.UU. (proxy) | Ley de EE.UU. + proveedor final | Doble exposicion | Riesgo de cadena | `Free` |

### Leyenda de riesgo

- **Verde (seguro):** Local, Cerebras, Groq
- **Amarillo (aceptable con precaucion):** Anthropic, OpenAI (API de pago)
- **Naranja (usar solo para datos no sensibles):** Google Gemini (gratuito), Grok, OpenRouter
- **Rojo (riesgo alto para datos personales):** Z.AI, Kimi, MiniMax (jurisdiccion china)

---

## 2. Clasificacion de Privacidad para LifeOS

### Nivel 1 — Maximo secreto (SensitivityLevel::Critical)
**Datos:** contrasenas, claves API, datos financieros, informacion medica, memorias intimas
**Proveedores permitidos:** SOLO `Local`
**Justificacion:** Estos datos nunca deben abandonar la maquina bajo ninguna circunstancia. Ni siquiera proveedores con ZDR son aceptables porque el transporte en si es un vector de ataque.

### Nivel 2 — Alto (SensitivityLevel::High)
**Datos:** conversaciones personales, contenido de emails, documentos de trabajo, datos de relaciones
**Proveedores permitidos:** `Local` + `Premium` (Anthropic, OpenAI API de pago)
**Justificacion:** Anthropic y OpenAI en modo API no entrenan con estos datos y tienen politicas de retencion limitada (30 dias para seguridad). Cerebras y Groq tambien serian aceptables aqui por su ZDR, pero el router actual los clasifica como `Free`, no `Premium`.

### Nivel 3 — Medio (SensitivityLevel::Medium)
**Datos:** configuracion del sistema, logs no personales, notas de reuniones genericas
**Proveedores permitidos:** `Local` + `Free` (Cerebras, Groq) + `Premium`
**Proveedores excluidos:** `Cheap` (proveedores chinos)
**Justificacion:** Los proveedores chinos estan sujetos a la Ley de Ciberseguridad de China (2017) y la PIPL (2021), que obligan a las empresas a proporcionar acceso a datos si el gobierno lo solicita. Para datos de configuracion de sistema, esto podria exponer la arquitectura interna.

### Nivel 4 — Bajo (SensitivityLevel::Low)
**Datos:** preguntas genericas, codigo open source, traducciones publicas
**Proveedores permitidos:** Todos
**Justificacion:** Informacion publica que no tiene valor de privacidad. Aqui se prioriza velocidad y costo.

---

## 3. Recomendaciones para el LLM Router

### 3.1 Cambios necesarios en `llm_router.rs`

**Problema actual:** El router trata a Gemini gratuito como `Free` al mismo nivel que Cerebras/Groq, pero Gemini gratuito **si entrena con tus datos**. Esto es una brecha de privacidad significativa.

**Recomendacion 1: Reclasificar Gemini gratuito**
Gemini en tier gratuito deberia ser tratado como `Cheap` o tener una bandera especial `trains_on_data: true`. Actualmente en `default_providers()` esta como `tier: ProviderTier::Free` con el comentario "free tier trains on data! use with caution", pero el codigo no actua sobre esta advertencia.

**Recomendacion 2: Crear un tier intermedio o bandera de privacidad**
El campo `privacy: String` existe en `ProviderConfig` pero esta vacio (`String::new()`) para todos los proveedores. Deberia usarse con valores como:
- `"zdr"` — Zero Data Retention (Cerebras, Groq)
- `"no_training"` — No entrena pero retiene temporalmente (Anthropic, OpenAI API)
- `"trains_free"` — Entrena en tier gratuito (Gemini, Grok)
- `"opaque_china"` — Politica opaca + jurisdiccion china (Z.AI, Kimi, MiniMax)

**Recomendacion 3: Incorporar la bandera de privacidad en `select_candidates()`**
Cuando `sensitivity >= Medium` y `privacy_level == Careful`:
- Excluir proveedores con `privacy == "trains_free"` o `privacy == "opaque_china"`
- Preferir proveedores con `privacy == "zdr"` sobre los demas

**Recomendacion 4: Cerebras y Groq merecen un tier especial**
Estos proveedores ofrecen ZDR gratuito — son mas seguros para datos sensibles que algunos proveedores `Premium`. El router deberia poder usarlos para `SensitivityLevel::High` cuando el usuario tiene `PrivacyLevel::Balanced`.

### 3.2 Cambios necesarios en `privacy_filter.rs`

**Problema actual:** El filtro `is_safe_for_tier()` solo mira el `ProviderTier` (Local/Free/Cheap/Premium), no la politica de privacidad real del proveedor. Un proveedor `Free` con ZDR (Cerebras) se trata igual que un `Free` que entrena con datos (Gemini gratuito).

**Recomendacion:** `is_safe_for_tier` deberia aceptar un `&ProviderConfig` completo en vez de solo el `ProviderTier`, para poder consultar el campo `privacy`.

---

## 4. Lo que LifeOS Ya Hace Bien

### 4.1 Arquitectura local-first
LifeOS incluye un modelo local (Qwen3.5-4B en llama-server) como primera opcion. Los datos criticos **nunca salen de la maquina**. Esto es fundamentalmente superior a cualquier servicio en la nube.

### 4.2 Filtro de privacidad antes de enviar
`privacy_filter.rs` sanitiza contenido antes de enviarlo a APIs externas:
- Detecta y redacta claves API, tokens Bearer
- Redacta direcciones de email, tarjetas de credito, telefonos
- Redacta IPs privadas
- Clasifica contenido por sensibilidad (Critical/High/Medium/Low)
- Soporta 4 niveles de privacidad del usuario (Paranoid/Careful/Balanced/Open)

### 4.3 Enrutamiento por sensibilidad
`llm_router.rs` ya implementa enrutamiento basado en `SensitivityLevel`:
- `Critical` -> solo Local
- `High` -> Local o Premium
- `Medium` en modo Careful -> excluye Cheap
- `Low` -> todos los proveedores

### 4.4 Prioridad de proveedores ZDR
Los proveedores Cerebras y Groq (ambos con ZDR) estan configurados como prioridad 2 y 3, justo despues del modelo local. Esto significa que en la practica, la mayoria de las solicitudes van a proveedores que no retienen datos.

### 4.5 Modo Paranoico
`PrivacyLevel::Paranoid` restringe TODO a solo el modelo local. Para usuarios con maxima preocupacion por la privacidad, LifeOS puede funcionar 100% offline.

---

## 5. Lo que LifeOS Debe Mejorar

### 5.1 CRITICO: Gemini gratuito esta mal clasificado
En `default_providers()`, Gemini Flash esta como `tier: ProviderTier::Free` pero **Google entrena con datos del tier gratuito**. Deberia ser `Cheap` o tener una restriccion adicional. Actualmente, si el usuario tiene mode `Careful` y sensibilidad `Medium`, Gemini gratuito SERA candidato, lo cual viola la expectativa de privacidad.

### 5.2 IMPORTANTE: Campo `privacy` no se usa
Cada `ProviderConfig` tiene un campo `privacy: String` que esta vacio para todos los proveedores. Este campo deberia:
1. Estar populado con la politica real de cada proveedor
2. Ser consultado en `select_candidates()` y `is_safe_for_tier()`

### 5.3 IMPORTANTE: Proveedores chinos sin advertencia explicita
Z.AI (GLM), Kimi (Moonshot) y MiniMax estan clasificados como `Cheap`, lo cual impide su uso para datos `Medium` en modo `Careful`. Esto es correcto, pero el usuario no recibe ninguna explicacion de **por que** se excluyen. El router deberia emitir un log o notificacion cuando un proveedor chino es excluido por razones de privacidad.

### 5.4 MEJORA: Transparencia al usuario
Cuando el router elige un proveedor, el `RouterResponse` incluye `provider` y `model`, pero no incluye:
- La politica de privacidad del proveedor seleccionado
- Si los datos fueron sanitizados antes de enviar
- Cuantas redacciones se hicieron

Agregar un campo `privacy_info` al `RouterResponse` daria transparencia al usuario.

### 5.5 MEJORA: Deteccion de patrones en espanol
`privacy_filter.rs` tiene buena cobertura en ingles pero limitada en espanol. Solo incluye: "contrasena", "tarjeta de credito", "cuenta bancaria", "enfermedad", "tratamiento", "pareja", "vida personal", "empleado", "notas de reunion". Faltan patrones como:
- "numero de seguro social", "CURP", "RFC", "INE"
- "diagnostico", "receta medica", "historial clinico"
- "sueldo", "nomina", "estado de cuenta"
- "direccion", "domicilio"

### 5.6 MEJORA: Auditing trail
No existe un registro persistente de que datos se enviaron a que proveedor. Para cumplimiento de GDPR/privacidad, LifeOS deberia mantener un log (local, encriptado) de:
- Timestamp de cada solicitud externa
- Proveedor y modelo usado
- Nivel de sensibilidad detectado
- Numero de redacciones realizadas
- Hash del contenido (no el contenido en si)

---

## 6. Detalle por Proveedor

### 6.1 Modelo Local (Qwen3.5-4B en llama-server)
- **Privacidad:** Maxima. Los datos nunca salen del dispositivo.
- **Limitacion:** Modelo pequeno (4B parametros), capacidad limitada para tareas complejas.
- **Uso en LifeOS:** Primera opcion para todo. Fallback cuando no hay internet.
- **Riesgo:** Ninguno desde perspectiva de privacidad. El riesgo es de calidad de respuesta.

### 6.2 Cerebras
- **Politica:** Zero Data Retention explicita. No almacenan prompts ni completions despues de procesarlos.
- **Jurisdiccion:** EE.UU. (California). Sujeto a CLOUD Act y potenciales ordenes judiciales.
- **Riesgo real:** Bajo. Dado que no retienen datos, una orden judicial no encontraria nada que entregar.
- **Modelos en LifeOS:** Qwen3 235B (razonamiento), Llama 3.1 8B (tareas simples).
- **Recomendacion:** Proveedor externo mas seguro disponible. Podria usarse para High con Balanced.

### 6.3 Groq
- **Politica:** Zero Data Retention explicita. Similar a Cerebras.
- **Jurisdiccion:** EE.UU. Mismas consideraciones que Cerebras.
- **Riesgo real:** Bajo. ZDR real.
- **Modelos en LifeOS:** Llama 3.3 70B, Qwen3 32B, Llama 3.1 8B, GPT-OSS 120B.
- **Recomendacion:** Segundo proveedor externo mas seguro. Excelente para tareas de coding.

### 6.4 Anthropic (Claude)
- **Politica API:** No entrena con datos de API. Retiene datos 30 dias para seguridad y deteccion de abuso. Elimina despues. Enterprise puede negociar ZDR.
- **Politica gratuita:** Claude.ai gratuito SI puede usar datos para mejora, pero con opt-out.
- **Jurisdiccion:** EE.UU. (Delaware). Sujeto a CLOUD Act.
- **Incidentes:** Ninguno conocido de filtracion de datos.
- **Riesgo:** Bajo-medio. La retencion de 30 dias significa que existe una ventana donde una orden judicial podria acceder a datos.
- **Uso en LifeOS:** Premium. Para tareas complejas con datos High.

### 6.5 OpenAI (GPT)
- **Politica API:** Desde marzo 2023, NO entrena con datos de API por defecto. Retencion de 30 dias para abuso. Opt-out explico disponible. Enterprise ofrece ZDR.
- **Politica gratuita:** ChatGPT gratuito SI entrena con datos por defecto.
- **Jurisdiccion:** EE.UU. (San Francisco). CLOUD Act aplicable.
- **Incidentes:** Bug que filtro titulos de historial de ChatGPT a otros usuarios (marzo 2023). Empleados de Samsung filtraron codigo propietario via ChatGPT.
- **Riesgo:** Bajo-medio para API. Los incidentes fueron en producto consumer, no API.
- **Uso en LifeOS:** Premium. Solo via API de pago.

### 6.6 Google (Gemini)
- **Politica API gratuita:** **Los datos SE USAN para mejorar productos.** Google lo dice explicitamente: "For unpaid Services, Google uses your prompts, generated responses... to improve our models."
- **Politica API de pago (Vertex AI):** No entrena con datos del cliente.
- **Jurisdiccion:** EE.UU. Sujeto a CLOUD Act, FISA 702, National Security Letters.
- **Historial:** Google tiene el historial mas extenso de recoleccion de datos de cualquier empresa tecnologica. Multiples multas GDPR.
- **Riesgo:** **ALTO en tier gratuito.** Los datos enviados a Gemini Flash gratuito se usan para entrenar modelos futuros de Google. Esto incluye cualquier contenido del usuario de LifeOS.
- **Uso en LifeOS:** Actualmente `Free`, deberia ser `Cheap` o tener restriccion de privacidad.

### 6.7 xAI (Grok)
- **Politica:** Usa datos para "mejorar productos". Vinculado al ecosistema de X/Twitter. Politica de privacidad ambigua sobre separacion entre datos de Grok y datos de X.
- **Jurisdiccion:** EE.UU. (Nevada).
- **Riesgo:** Medio-alto. La falta de claridad sobre como se separan los datos de Grok de los datos de X es preocupante.
- **Uso en LifeOS:** No incluido actualmente en default_providers(). Si se agrega, deberia ser `Cheap`.

### 6.8 Z.AI / Zhipu (GLM)
- **Politica:** Opaca. Documentacion principalmente en chino mandarin. Terminos de servicio no claros sobre uso de datos de API para entrenamiento.
- **Jurisdiccion:** **China (Beijing).** Sujeto a:
  - Ley de Ciberseguridad de China (2017): Obliga a almacenar datos en China y cooperar con autoridades.
  - PIPL (2021): Equivalente chino de GDPR, pero incluye excepciones amplias para "seguridad nacional".
  - Ley de Inteligencia Nacional (2017): Obliga a empresas e individuos a cooperar con agencias de inteligencia.
- **Riesgo:** **ALTO.** El gobierno chino tiene acceso legal a cualquier dato procesado por servidores en China. No hay mecanismo de opt-out.
- **Uso en LifeOS:** `Cheap`. Solo para datos `Low`.

### 6.9 Moonshot (Kimi)
- **Politica:** Similar a Z.AI. Documentacion principalmente en chino. Condiciones opacas.
- **Jurisdiccion:** **China (Beijing).** Mismas leyes que Z.AI.
- **Riesgo:** **ALTO.** Mismas razones que Z.AI.
- **Uso en LifeOS:** `Cheap`. Solo para datos `Low`.

### 6.10 MiniMax
- **Politica:** Similar a Z.AI y Kimi. Empresa china con sede en Shanghai.
- **Jurisdiccion:** **China.** Mismas leyes.
- **Riesgo:** **ALTO.** Mismas razones.
- **Uso en LifeOS:** `Cheap`. Solo para datos `Low`.

### 6.11 OpenRouter
- **Politica:** OpenRouter es un proxy/aggregador. NO procesa inferencia directamente. Pasa solicitudes al proveedor final.
- **Riesgo doble:** Tu datos pasan por OpenRouter (EE.UU.) Y por el proveedor final. Dos entidades ven tus datos.
- **Uso en LifeOS:** `Free`. Fallback de ultimo recurso. Solo para datos `Low`.

---

## 7. Marco Legal Relevante

### 7.1 Leyes que afectan a proveedores en EE.UU.
- **CLOUD Act (2018):** Permite a EE.UU. exigir datos almacenados en servidores extranjeros de empresas estadounidenses. Aplica a Anthropic, OpenAI, Google, Groq, Cerebras, OpenRouter.
- **FISA 702:** Permite vigilancia de comunicaciones de extranjeros sin orden judicial. Potencialmente aplica a datos de usuarios no-estadounidenses en servidores de EE.UU.
- **CCPA/CPRA (California):** Da derechos de acceso, eliminacion y opt-out a residentes de California. No aplica directamente a usuarios fuera de EE.UU.

### 7.2 Leyes que afectan a proveedores en China
- **Ley de Ciberseguridad (2017):** Datos deben almacenarse en China. Gobierno puede solicitar acceso.
- **PIPL (2021):** Requiere consentimiento para procesamiento, PERO tiene excepciones amplias para "seguridad publica" y "emergencias de salud publica".
- **Ley de Inteligencia Nacional (2017):** Articulo 7: "Todas las organizaciones y ciudadanos deben apoyar, asistir y cooperar con el trabajo de inteligencia nacional." No hay opt-out posible.

### 7.3 Para el usuario de LifeOS en Mexico/LATAM
- La LFPDPPP (Ley Federal de Proteccion de Datos Personales en Posesion de los Particulares) de Mexico ofrece protecciones basicas.
- En la practica, ninguna ley mexicana puede forzar a Anthropic, Google o Zhipu a eliminar datos.
- **La unica proteccion real es no enviar datos sensibles en primer lugar** — que es exactamente lo que el privacy_filter de LifeOS hace.

---

## 8. Conclusion para el Usuario Final

**LifeOS protege tu privacidad de tres formas fundamentales:**

1. **Tu modelo local procesa lo mas sensible.** Contrasenas, datos financieros, informacion medica, memorias personales — nada de esto sale de tu computadora. El modelo Qwen3.5-4B corre directamente en tu hardware.

2. **Cuando necesita ayuda externa, LifeOS prefiere proveedores que no guardan tus datos.** Cerebras y Groq tienen politica de Zero Data Retention: procesan tu solicitud y la borran inmediatamente. No entrenan con tus datos. No los venden.

3. **Antes de enviar algo a internet, LifeOS censura informacion sensible.** El filtro de privacidad automaticamente detecta y redacta contrasenas, emails, tarjetas de credito, telefonos e IPs privadas.

**Lo que debes saber:**
- En modo **Careful** (el predeterminado), tus datos personales nunca llegan a Google, ni a empresas chinas, ni a ningun proveedor que entrene con tus datos.
- En modo **Paranoico**, absolutamente nada sale de tu maquina. Toda la IA funciona local.
- Los proveedores chinos (Z.AI, Kimi, MiniMax) solo se usan para preguntas genericas y publicas, nunca para datos personales. El gobierno chino tiene acceso legal a cualquier dato en servidores chinos.
- Incluso los proveedores estadounidenses de confianza (Anthropic, OpenAI) estan sujetos a ordenes judiciales. LifeOS mitiga esto enviandoles solo datos que ya fueron sanitizados.

**En resumen:** LifeOS no es como usar ChatGPT o Gemini directamente, donde todo lo que escribes alimenta el modelo de la empresa. LifeOS es un intermediario inteligente que decide que proveedor merece ver que datos, y siempre prefiere que tus datos se queden contigo.

---

## 9. Plan de Accion Tecnico (Priorizado)

| Prioridad | Accion | Archivo | Impacto |
|---|---|---|---|
| P0 | Reclasificar Gemini gratuito: cambiar tier a `Cheap` o agregar `privacy: "trains_free"` | `llm_router.rs` | Evita enviar datos Medium a Google |
| P0 | Popular campo `privacy` en todos los `ProviderConfig` de `default_providers()` | `llm_router.rs` | Habilita enrutamiento basado en politica real |
| P1 | Modificar `select_candidates()` para consultar campo `privacy` ademas de `tier` | `llm_router.rs` | Enrutamiento privacidad-aware real |
| P1 | Modificar `is_safe_for_tier()` para aceptar `ProviderConfig` completo | `privacy_filter.rs` | Decisions de seguridad mas granulares |
| P2 | Agregar patrones de datos sensibles en espanol al filtro | `privacy_filter.rs` | Mejor proteccion para usuarios hispanohablantes |
| P2 | Agregar campo `privacy_info` a `RouterResponse` | `llm_router.rs` | Transparencia al usuario |
| P3 | Implementar audit trail local encriptado | Nuevo modulo | Cumplimiento y trazabilidad |
| P3 | Notificar al usuario cuando se excluye un proveedor por privacidad | `llm_router.rs` | Educacion del usuario |
