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

## 4. Qué pasa cuando alguien pierde el teléfono — HECHO (896)

La frase de 12 palabras sincroniza entre aparatos. Pero quien tiene UN solo
aparato y lo pierde, pierde todo: las copias existen pero hay que activarlas
antes, y nadie activa copias antes de necesitarlas.

Cuando esto se reparta, le va a pasar a alguien.

Lo que se hizo NO fue otro mecanismo de respaldo: ya había tres y ninguno
protegía a nadie. Lo que faltaba era que la pregunta se hiciera. Y no el primer
día: respaldar una app vacía no protege nada y gasta la única vez que alguien
va a leer ese aviso con atención. Ahora aparece cuando ya hay unas veinte cosas
guardadas —cuando la persona entiende por qué se le pregunta— y vuelve si dice
"luego": a la semana, luego a las dos, hasta un tope de ocho semanas. Nunca
desaparece del todo mientras no haya copia, y desaparece para siempre en cuanto
la hay.

## 5. El primer día — HECHO (896)

Alguien abre la app y ve un axolote y una lista de botones. Todo lo que existe
—el Cerebro, las relaciones, el Desahogo— está detrás de saber qué tocar. La
app no tiene forma de decir "cuéntame algo y te enseño qué hago con eso".

Es lo que más va a decidir si la usan dos días o dos meses, y no cuesta código
difícil: cuesta decidir cuál es la primera frase.

Es esta:

> **Hola, soy Axi.**
> Cuéntame tu vida y yo me encargo de recordarla.

Y debajo, lo único técnico que se menciona el primer día, porque es la
diferencia real: lo que le cuentes se queda en ese aparato, el que contesta
corre ahí dentro, y funciona sin internet. Termina invitando a contar algo
—"cómo dormiste, con quién comiste, qué te dijo el doctor"— y el botón entra
directo al chat, porque lo que engancha no es entender la app: es ver qué hace
con la primera cosa que le cuentas. Quien prefiera mirar antes de escribir
tiene su salida, y de ahí pasa a los permisos.

El texto vive en `first_day_copy.dart` con una prueba que lo defiende de
convertirse en un resumen de funciones o en una lista de lo que la app NO
hace.

## Deuda conocida

Dos pruebas intermitentes: `sync_auto_runner_test` ("a burst of changes is ONE
pass") y `sync_three_devices_test` ("the mailboxes do not grow without bound").
Pasan aisladas y fallan a veces en la suite completa. Hoy son ruido; el
problema es el día que una falle de verdad y nadie le haga caso.
