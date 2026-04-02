# Fase BF — Modelos Remotos Gratis y Preview

> Dar al usuario acceso opcional a modelos remotos gratuitos o en preview
> (por ejemplo Qwen 3.6 Plus Preview y futuras promos similares) sin mover
> el corazon de LifeOS fuera del enfoque local-first y privacy-first.

## Estado

**Vision futura. No es prioridad actual.**

Esta fase existe para no perder la idea y para que, cuando la retomemos, no
se implemente de forma improvisada ni contradiga las promesas de privacidad
de LifeOS.

## Problema que resuelve

LifeOS hoy tiene una base local muy fuerte:

- modelo local por defecto
- memoria privada
- control del sistema en host
- routing multi-provider existente

Pero el ecosistema de modelos cambia muy rapido. Herramientas como OpenCode
demuestran que muchos usuarios valoran poder probar modelos nuevos y gratuitos
por tiempo limitado, aun cuando sean remotos, para:

- evaluar calidad
- acceder a contextos muy largos
- probar coding/agentic models nuevos
- usar cuotas gratis de proveedores sin pagar de inmediato

La oportunidad para LifeOS no es copiar ciegamente ese enfoque, sino ofrecer
algo mas honesto:

- local por defecto
- remoto solo si el usuario lo elige
- privacidad explicita
- memoria protegida
- previews aislados del contexto sensible

## Principios no negociables

### BF.1 — El modelo local sigue siendo el default

- LifeOS no debe cambiar su default local por un preview remoto.
- El modelo remoto gratis es una **opcion extra**, no el corazon del sistema.
- La experiencia base sigue siendo usable sin nube.

### BF.2 — Todo modelo remoto gratis debe ser opt-in

- Nada de activarlo por defecto.
- Nada de fallback silencioso.
- El usuario debe conectar conscientemente la cuenta, OAuth o API key.

### BF.3 — Etiquetado visible de privacidad y estabilidad

Cada modelo del catalogo debe mostrar claramente:

- `Local`
- `Remote`
- `Free`
- `Preview`
- `May use data for model improvement`
- `Stable`
- `Experimental`

Y tambien una explicacion corta:

- quien opera el modelo
- si es gratis por tiempo limitado
- si puede usar prompts/completions para mejorar el modelo
- si requiere cuenta propia del usuario

### BF.4 — Sin memoria privada por defecto en modelos preview

Si el usuario usa un modelo remoto gratis/preview:

- no se envia memoria privada automaticamente
- no se envia contexto sensible del sistema por defecto
- no se adjuntan archivos o screenshots sin consentimiento explicito
- no se activa el operador desktop automaticamente

Primero se usa como:

- chat
- coding advisor
- comparador de respuestas
- laboratorio de modelos

Despues, si el usuario lo autoriza, se podrian abrir permisos mas fuertes.

### BF.5 — El usuario trae su propia cuenta o cuota

LifeOS no debe subsidiar esto al inicio.

Los caminos correctos son:

- OpenRouter free / preview
- OAuth oficial del proveedor
- cuotas gratis oficiales del vendor
- API key del propio usuario

## Que modelos/proveedores encajan

### BF.6 — Candidatos iniciales

**OpenRouter free / preview**

- util para modelos experimentales y comparacion rapida
- pero requiere advertencia fuerte porque algunos modelos indican
  explicitamente que recolectan prompts y completions para mejorar el modelo

**Qwen / Alibaba**

- encaja bien para previews como `Qwen 3.6 Plus Preview`
- tambien para cuotas gratis oficiales del ecosistema Qwen
- especialmente interesante para coding, reasoning y contexto largo

**Otros modelos gratuitos temporales**

- OpenCode Zen es referencia de producto, no dependencia
- si un modelo esta gratis por tiempo limitado y tiene API compatible,
  LifeOS podria integrarlo como opcion experimental

## UX sugerida

### BF.7 — Catalogo de modelos con niveles claros

El catalogo de modelos deberia tener al menos estas vistas:

- `Local`
- `Remote trusted`
- `Free / Preview`
- `Experimental`

Ejemplo de presentacion:

| Modelo | Tipo | Privacidad | Estado | Notas |
|---|---|---|---|---|
| Qwen3.5-4B local | Local | Alta | Default | Corre en tu hardware |
| Qwen 3.6 Plus Preview | Remote | Baja/Variable | Preview | Puede usar datos para mejora |
| Gemini Flash Free | Remote | Variable | Experimental | Bueno como fallback visual |

### BF.8 — Modo laboratorio

La mejor UX inicial no es "reemplazar el modelo actual", sino:

- comparar respuestas
- correr tareas manuales con modelo remoto
- evaluar calidad/costo/privacidad
- dejar que el usuario decida

En otras palabras:

- `usar como laboratorio primero`
- `usar como default del sistema despues, si demuestra valor`

## Arquitectura sugerida

### BF.9 — Encaje con la base actual de LifeOS

LifeOS ya tiene piezas que ayudan:

- `llm_router.rs`
- filtro/configuracion de providers
- docs de privacidad por provider
- dashboard que ya distingue providers

La fase futura consistiria en agregar:

- metadata extendida por modelo
- flags de `free`, `preview`, `privacy_level`, `requires_oauth`
- politicas de aislamiento para memoria y tools
- UI de consentimiento y seleccion

## Reglas de seguridad y producto

### BF.10 — Reglas iniciales obligatorias

- Nunca usar preview remoto como fallback silencioso del local
- Nunca mandar memoria privada por defecto
- Nunca mandar screenshots/camara/microfono por defecto
- Nunca ocultar si un modelo puede usar datos para mejora
- Nunca vender como "gratis" algo que depende de promo temporal sin avisarlo

## Resultado esperado

Si esta fase se implementa bien, LifeOS podria decir:

> "Tu sistema sigue siendo local por defecto. Pero si quieres, puedes probar
> modelos nuevos gratuitos o preview desde una capa experimental, con etiquetas
> claras de privacidad, estabilidad y origen."

Eso si es consistente con la filosofia de LifeOS.

## Prioridad real

**Prioridad baja por ahora.**

Antes de tocar esto, siguen por delante:

- validacion host de lo ya construido
- Activity Real
- control plane del OS
- madurez de reuniones, workers y dashboard
- cierre de gaps entre repo, host y docs
