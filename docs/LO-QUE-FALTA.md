# Lo que falta, y por qué cada cosa

Cinco huecos, encontrados leyendo el código y probando la app en el Pixel — no
imaginados. Tres ya están hechos; los otros dos siguen abiertos.

Aparte de esta lista, el boletín de la laptop ya se genera con la aplicación
cerrada (un temporizador de systemd lanza el mismo generador headless que usa
el teléfono), y una fuente repetida ya no sale dos veces.

## 1. Llévate tus datos — HECHO (886)

Había copias cifradas y restauración, y las dos sólo funcionan de vuelta HACIA
LifeOS. No había manera de sacar lo tuyo en algo legible sin nosotros, así que
"tu vida, tu máquina" era una frase, no algo comprobable. Y dejaba en falso el
plan de pago: "si dejas de pagar, tus datos siguen siendo tuyos" no es cierto
cuando el único formato en que existen es uno que nadie más abre.

Ajustes → Llévate tus datos. CSV para una hoja de cálculo, JSON para todo
incluidas las relaciones y lo borrado.

## 2. Corregir a Axi hablando — HECHO (886)

Los datos entran hablando y sólo se podían arreglar buscando la fila y
editándola a mano. Casi nadie hace eso, así que los errores se quedan — y un
dato equivocado no es inerte: se repite. Ahora "no, Mateo tiene 9" reemplaza,
nunca añade.

## 3. Que Axi diga algo primero — HECHO (887)

Nunca iniciaba: todo lo que sabía era porque el usuario fue a contárselo, lo
que pone la carga entera en la persona más ocupada. Ahora, si hace días que no
hablan, el chat abre citando las palabras del propio usuario. Nunca inventa un
seguimiento, y no se repite el mismo día.

## 4. Qué pasa cuando alguien pierde el teléfono — PENDIENTE

La frase de 12 palabras sincroniza entre aparatos. Pero quien tiene UN solo
aparato y lo pierde, pierde todo: las copias existen pero hay que activarlas
antes, y nadie activa copias antes de necesitarlas.

Cuando esto se reparta, le va a pasar a alguien. Lo que falta es una sola
pregunta el primer día — "¿dónde quieres tu respaldo?" — y que la respuesta
baste.

## 5. El primer día — PENDIENTE

Alguien abre la app y ve un axolote y una lista de botones. Todo lo que existe
—el Cerebro, las relaciones, el Desahogo— está detrás de saber qué tocar. La
app no tiene forma de decir "cuéntame algo y te enseño qué hago con eso".

Es lo que más va a decidir si la usan dos días o dos meses, y no cuesta código
difícil: cuesta decidir cuál es la primera frase.

## Deuda conocida

Dos pruebas intermitentes: `sync_auto_runner_test` ("a burst of changes is ONE
pass") y `sync_three_devices_test` ("the mailboxes do not grow without bound").
Pasan aisladas y fallan a veces en la suite completa. Hoy son ruido; el
problema es el día que una falle de verdad y nadie le haga caso.
