# Hoja de Ruta Publica de LifeOS

Ultima actualizacion: `2026-04-01`

LifeOS es una distribucion Linux nativa para IA enfocada en:

- inteligencia local-first
- privacidad por defecto
- computacion personal soberana

Esta hoja de ruta es la version publica y entendible del estado actual del proyecto y de lo que sigue.

Es intencionalmente mas simple que la estrategia tecnica, pero sigue la misma fuente de verdad.

---

## Que ya es real hoy

Estas bases ya existen hoy dentro del proyecto:

- inferencia local a traves del runtime de IA de LifeOS
- bases de memoria local cifrada
- bases del control plane de escritorio
- interaccion remota por Telegram
- bases de voz, vision y automatizacion
- branding publico y cimientos de la landing page

Importante:

LifeOS sigue en etapa temprana. La meta aqui no es fingir que el sistema ya esta terminado, sino mostrar con honestidad lo que ya existe y lo que aun se esta endureciendo.

---

## Ahora

Estas son las areas en las que estamos empujando con mas fuerza hoy.

### 1. Estabilizar la base de la beta publica

Estamos haciendo que el sistema real sea mas confiable en hardware real:

- instalacion y primer arranque
- confianza en updates y rollback
- consistencia de runtime
- validacion en host de features que ya existen en repo

### 2. Mejorar el control de escritorio y el loop operador

LifeOS no quiere ser solo un runner local de modelos. Va hacia un sistema operativo donde el asistente pueda actuar sobre el escritorio con mejor control y limites mas seguros.

Foco actual:

- superficies mas fuertes de control del sistema
- mejores workflows de operacion
- interaccion remota mas confiable
- caminos mas claros entre la intencion del usuario y la accion del sistema

### 3. Hacer crecer la documentacion publica y la claridad del producto

Queremos que el proyecto sea mas facil de entender desde fuera:

- roadmap publico mas claro
- mejores demos y onboarding
- mas documentacion publica
- mejor alineacion entre web, repo y estado real del runtime

---

## Lo siguiente

Estas son las siguientes areas grandes despues del empuje actual de estabilizacion.

### Inteligencia para reuniones y memoria

El pipeline de reuniones ya avanzo fuerte en repo. El siguiente paso es validarlo con cuidado en uso real de host para que:

- la deteccion sea confiable
- las transcripciones y resumenes sean utiles
- la retencion sea limpia y no deje basura innecesaria en disco

### Seguridad por defecto

LifeOS tambien va hacia una postura mas fuerte por default desde el primer momento:

- defaults mas seguros en host
- mejor hardening del sistema
- guardrails operativos mas claros

### Rails publicos para seguir y apoyar el proyecto

El proyecto ya tiene landing publica, y la siguiente capa es conectarla a:

- visibilidad del roadmap
- canales de apoyo
- demos y actualizaciones publicas

---

## Mas adelante

Estas son direcciones valiosas para LifeOS, pero no forman parte del camino critico inmediato.

- personalizacion mas rica y workflows adaptativos
- mejor control movil y cross-platform
- sistemas mas profundos de memoria y conocimiento
- entrenamiento local y modelos especializados
- mas superficies de producto hacia usuario final

Siguen siendo importantes, pero no deben ir por delante de la estabilidad real de la base.

---

## Camino a la beta publica

Para LifeOS, "beta publica" significa algo concreto.

No significa:

- que toda la vision de largo plazo ya este completa
- que cada subsistema experimental ya sea perfecto
- que todas las plataformas ya esten soportadas

Si significa:

- que el camino central de instalacion y actualizacion sea estable
- que las bases de IA local y memoria ya sean usables
- que el control de escritorio sea entendible y confiable
- que el proyecto este lo bastante documentado para que gente nueva lo pueda probar y seguir

---

## Como describimos el progreso

Ahora intentamos evitar claims vagos como "completo" a menos que esten realmente aterrizados.

Cuando sea posible, una feature debe caer en una de estas realidades:

- validada en host real
- integrada en repo
- parcial / todavia sin cerrar end-to-end

Esa honestidad importa porque LifeOS se esta construyendo en publico.

---

## Roadmap tecnico

Si quieres la fuente de verdad de ingenieria, revisa:

- [Indice de estrategia tecnica](../strategy/unified-strategy.md)
- [Auditoria de realidad / matriz de estados](../strategy/auditoria-estados-reales.md)

La hoja de ruta publica es la capa legible. Los docs de estrategia siguen siendo la capa detallada.
