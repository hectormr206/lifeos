# 14 - Agent Runtime Execution Pipeline

## Tesis

El runtime del agente de OpenClaw esta partido en piezas que tienen responsabilidades distintas.
Eso suena obvio, pero en la practica es una de las razones mas fuertes por las que el sistema aguanta sesiones largas y fallos de provider sin desordenarse.

## La separacion clave: sesion estable, intento efimero

Mirando `src/agents/pi-embedded-runner/run.ts`, `run/setup.ts`, `run/attempt.ts` y `compact.ts` aparece un patron clarisimo:

- la sesion es duradera
- el intento de inferencia es intercambiable
- la compaction es un flujo normal

Esto permite reintentar, compactar o hacer failover sin perder la identidad conversacional.

## Setup de sesion antes de tocar el modelo

`run/setup.ts` arma el contexto real del turno:

- resuelve workspace y agent dir
- prepara transcript y session file
- carga tools y runtime plugins
- resuelve provider/model efectivos
- resuelve auth profiles
- inicializa context engine
- arma prompt base e invariantes de bootstrap

Esto es importante porque evita el antipatron de "resolver cosas a mitad del turno" de forma desordenada.

## `run.ts` como orquestador

`run.ts` no ejecuta directamente la inferencia mas compleja.
Su trabajo es mas de scheduler y supervisor:

- prepara la sesion
- abre el loop de intentos
- clasifica errores
- decide retry, failover o compaction
- lleva accounting y backoff
- mantiene continuidad de estado entre intentos

Esa separacion hace que la logica de control no quede mezclada con el detalle del provider.

## `attempt.ts` como pipeline real del turno

`run/attempt.ts` es donde se nota que OpenClaw ya resolvio muchas fricciones del mundo real.

El archivo hace cosas como:

- construir la llamada concreta al modelo
- registrar tool definitions y tool loops
- procesar streaming, partials y heartbeats
- convertir tool calls y tool results en transcript estructurado
- proteger writes de sesion
- resolver contexto post-compaction
- normalizar contenido multimodal
- lidiar con timeouts, aborts y errores de provider

Interpretacion:

- el intento no es solo `await model.generate()`
- es un micro-pipeline de inferencia con observabilidad y recovery

## Herramientas tratadas como eventos del transcript

Una de las mejores decisiones del runtime es que las tools no viven "fuera" de la conversacion.

Se tratan como parte de la historia estructurada:

- tool call
- output parcial
- result final
- ubicaciones de archivos cuando aplica

Eso permite varias cosas:

- mantener coherencia entre texto y herramientas
- compactar sin perder del todo el rastro de acciones
- emitir eventos consistentes hacia Gateway, UI y ACP

## Compaction como camino normal

`src/agents/pi-embedded-runner/compact.ts` confirma algo importante:

- el overflow de contexto no se trata como excepcion rara
- se trata como parte esperada del ciclo de vida de una sesion

La compaction hace trabajo serio:

- estima tokens
- recorta resultados muy grandes
- repara o normaliza session files
- invoca hooks antes y despues
- usa context engines
- reaplica invariantes despues de resumir

Esto evita que una sesion larga se degrade solo porque el historial ya no cabe.

## Bootstrap y system prompt como contrato

`system-prompt.ts` centraliza el prompt base y el bootstrap operativo.
Eso importa mucho despues de retries, compaction y failover.

Si el sistema no recentralizara esas invariantes, cada intento correria el riesgo de:

- olvidar reglas del agente
- perder parte del setup operativo
- derivar hacia prompts inconsistentes entre intentos

OpenClaw decide lo contrario:

- hay una capa canonica
- despues de compaction se reconstruye
- el comportamiento base no depende de que el transcript siga intacto

## Context engine selectivo

`src/context-engine/index.ts`, `init.ts`, `registry.ts` y `legacy.ts` muestran que el proyecto no depende de reenviar el transcript bruto cada vez.

El context engine aporta:

- seleccion de contexto util
- compatibilidad con estrategias viejas
- desacople entre transcript persistido y contexto efectivo de inferencia

Eso ayuda a que el costo del prompt no crezca linealmente con toda la historia del agente.

## Failover en varios niveles

La doc `docs/concepts/model-failover.md` y el runner dejan claro que "failover" no significa solo cambiar de modelo.

Hay varias palancas:

- retry simple
- rotacion de auth profile
- rotacion de modelo
- rotacion de provider
- cooldowns y deshabilitacion temporal

Esto es exactamente lo que uno esperaria en un producto que ya vio:

- credenciales vencidas
- OAuth roto
- modelos saturados
- errores de billing
- timeouts intermitentes

## Por que aguanta sesiones largas

Las sesiones largas funcionan mejor aqui por la combinacion de:

- transcript persistente
- intentos reemplazables
- compaction normalizada
- contexto selectivo
- failover explicito
- prompt/base bootstrap centralizados

OpenClaw no necesita elegir entre:

- "recordar todo"
- o "seguir funcionando"

Tiene infraestructura para negociar entre ambas cosas.

## Archivos mas importantes

- `../openclaw-main/src/agents/pi-embedded-runner/run.ts`
- `../openclaw-main/src/agents/pi-embedded-runner/run/setup.ts`
- `../openclaw-main/src/agents/pi-embedded-runner/run/attempt.ts`
- `../openclaw-main/src/agents/pi-embedded-runner/compact.ts`
- `../openclaw-main/src/agents/pi-embedded-runner/system-prompt.ts`
- `../openclaw-main/src/context-engine/index.ts`
- `../openclaw-main/src/context-engine/init.ts`
- `../openclaw-main/src/context-engine/registry.ts`
- `../openclaw-main/docs/concepts/agent.md`
- `../openclaw-main/docs/concepts/model-failover.md`

## Conclusion

La ejecucion del agente en OpenClaw esta programada como runtime, no como wrapper.

Eso se nota en la separacion entre:

- sesion
- intento
- compaction
- contexto
- failover

Y esa separacion es, probablemente, una de las piezas que mas explica por que OpenClaw puede crecer en complejidad sin romper conversaciones cada vez que algo falla.

