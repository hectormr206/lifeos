# 19 - Anti-Breakage Engineering Patterns

## Tesis

La pregunta mas valiosa sobre OpenClaw no es solo "que features tiene".
Es:

> que patrones de ingenieria repite una y otra vez para poder crecer sin romperse

Despues de revisar muchas capas, estos son los patrones mas consistentes.

## 1. Un contrato antes que una conveniencia

OpenClaw casi siempre prefiere introducir un contrato explicito antes que una regla implicita.

Se ve en:

- protocolo WS tipado y versionado
- manifests de plugins
- schema de config
- session keys con forma fija
- config options ACP anunciadas por capacidad

Efecto:

- menos magia
- menos drift
- menos dependencias invisibles entre capas

## 2. Un solo plano de control para varias superficies

En vez de tener una API para UI, otra para nodos y otra para automations, OpenClaw concentra mucho en el Gateway.

Efecto:

- una sola verdad de auth y estado
- un solo bus de eventos
- menos duplicacion de semantica entre clientes

## 3. Separar estado durable de ejecucion efimera

El patron aparece en varios lados:

- sesion vs intento del agente
- config persistida vs snapshot runtime
- runtime ACP cacheado vs turno activo
- store de cron vs corrida puntual

Efecto:

- puedes reintentar, fallar o compactar sin perder identidad
- los errores transitorios no destruyen todo el sistema

## 4. Fail-closed en bordes sensibles

OpenClaw rara vez deja una superficie sensible en modo permissive por accidente.

Ejemplos:

- primer frame WS debe ser `connect`
- metodo sin scope claro se niega
- pairing se invalida si cambia metadata importante
- daemon install se bloquea si la auth no puede resolverse
- ACP rechaza controles no soportados por el backend

Efecto:

- el sistema prefiere decir "no" antes que aceptar un estado ambiguo

## 5. Capas de policy encima de capas de capacidad

OpenClaw separa bastante bien:

- lo que una pieza sabe hacer
- y lo que se le permite hacer en ese contexto

Se ve en:

- tools vs approvals
- plugins vs allowlists
- canales vs routing/bindings
- ACP backend vs `acp.allowedAgents`

Efecto:

- puedes tener capacidades potentes sin regalar acceso universal

## 6. Persistir y auditar lo suficiente

El proyecto guarda mucho mas estado del que uno esperaria en una demo:

- transcripts JSONL
- stores de sesion
- pairing stores
- config audit log
- config health fingerprints
- cron store

Efecto:

- hay continuidad
- hay material para recovery
- hay rastros para entender que paso

## 7. Dedupe, idempotency y colas antes de escalar concurrencia

Muchos problemas de asistentes multi-canal no vienen del modelo.
Vienen de correr lo mismo dos veces o de correr demasiado al mismo tiempo.

OpenClaw responde con:

- `idempotencyKey`
- dedupe de inbound
- colas por sesion
- followups
- steering de corridas activas
- lanes y actor queues

Efecto:

- menos respuestas duplicadas
- menos carreras
- menos estado corrompido

## 8. Asumir entornos imperfectos

OpenClaw programa como si el mundo real fuera hostil a la perfeccion:

- providers fallan
- auth expira
- dispositivos duermen
- iOS no siempre puede ejecutar en background
- usuarios tienen config vieja
- CI no puede correr todo siempre

Por eso agrega:

- failover
- wake/pending invoke
- `doctor`
- migraciones legacy
- CI guiado por alcance

Efecto:

- el sistema sobrevive mejor a estados mediocres

## 9. Convertir bugs repetidos en checks

Este patron aparece mucho:

- si una clase de error se repite, la vuelven script o test

Por eso existen:

- `check-architecture-smells`
- baselines de SDK y config docs
- tests muy especificos por regression
- reglas de pairing/account scope

Efecto:

- el conocimiento del equipo deja de vivir solo en la cabeza de alguien

## 10. Productizar tambien el mantenimiento

OpenClaw no solo producto la parte bonita:

- onboarding
- dashboard
- apps

Tambien producto:

- doctor
- daemon install
- status y health
- wrappers de arranque
- recovery hints

Efecto:

- operar y reparar forma parte del producto
- no queda todo delegado a "lee el codigo y adivina"

## Conclusion

Si hubiera que condensar la ingenieria de OpenClaw en una sola idea, seria esta:

> casi siempre introduce estructura antes de introducir poder

Eso significa:

- contrato antes que magia
- policy antes que acceso
- estado durable antes que optimizacion oportunista
- repair path antes que happy path unico

Y esa forma de programar explica mucho mejor su estabilidad que cualquier feature individual.

