// Una respuesta que no responde.
//
// Visto en el Pixel el 2026-08-20, en tres turnos seguidos:
//   yo:  "Mi esposa nació en Cadereyta de Montes, Querétaro"
//   Axi: "Tu esposa nació en Cadereyta de Montes, Querétaro."
//   yo:  "Nos hicimos novios el 12 de mayo del 2008"
//   Axi: "Nos hicimos novios el 12 de mayo del 2008."
//   yo:  "El 12 de septiembre del 2008 hicimos el amor por primera vez"
//   Axi: "¿Qué necesitas, Héctor?"
//
// Devolver la misma frase no es conversar: es un eco. Y "¿Qué necesitas?"
// después de que alguien te cuenta algo íntimo es peor que el eco, porque
// además de no escuchar, cambia de tema.
//
// El prompt YA pedía "reconócelo en una frase corta y natural y sigue la
// conversación". Un modelo de este tamaño no obedece esa clase de regla, y
// añadir una quinta rompe la cuarta. Así que la decisión se toma en Dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/reply_quality.dart';

void main() {
  group('el eco', () {
    test('la misma frase devuelta no vale', () {
      expect(
        isEchoReply(
          userText: 'Nos hicimos novios el 12 de mayo del 2008',
          reply: 'Nos hicimos novios el 12 de mayo del 2008.',
        ),
        isTrue,
      );
    });

    test('cambiar "mi" por "tu" sigue siendo el mismo eco', () {
      // Es lo que hace el modelo cuando cree que está confirmando.
      expect(
        isEchoReply(
          userText: 'Mi esposa nació en Cadereyta de Montes, Querétaro',
          reply: 'Tu esposa nació en Cadereyta de Montes, Querétaro.',
        ),
        isTrue,
      );
    });

    test('una respuesta que AÑADE algo no es eco', () {
      expect(
        isEchoReply(
          userText: 'Mi esposa nació en Cadereyta de Montes',
          reply: 'Qué bien, entonces es queretana como tú. ¿Sigue viviendo '
              'familia suya por allá?',
        ),
        isFalse,
      );
    });

    test('responder una pregunta con el dato guardado NO es eco', () {
      // "¿Dónde nació mi esposa?" → "Tu esposa nació en Cadereyta." Eso es
      // exactamente lo que tiene que hacer, y confundirlo con un eco rompería
      // la mitad útil del chat.
      expect(
        isEchoReply(
          userText: '¿Dónde nació mi esposa?',
          reply: 'Tu esposa nació en Cadereyta de Montes, Querétaro.',
        ),
        isFalse,
      );
    });

    test('un mensaje de una o dos palabras nunca es eco', () {
      // Con tan poco que comparar, cualquier respuesta que use esas palabras
      // parecería un eco — y eso convertiría respuestas legítimas en
      // reconocimientos genéricos. Hace falta una frase para poder repetirla.
      expect(isEchoReply(userText: 'uno', reply: 'reply-uno'), isFalse);
      expect(isEchoReply(userText: 'gracias', reply: 'Gracias a ti.'), isFalse);
      expect(
        isEchoReply(userText: 'mi esposa Celia', reply: 'Tu esposa Celia.'),
        isFalse,
      );
    });

    test('una respuesta corta y distinta no es eco', () {
      expect(
        isEchoReply(userText: 'Hoy dormí fatal', reply: 'Vaya. ¿Qué te '
            'desveló?'),
        isFalse,
      );
    });
  });

  group('la cortesía que no escucha', () {
    test('"¿Qué necesitas?" después de que te cuentan algo, no', () {
      expect(isEmptyPleasantry('¿Qué necesitas, Héctor?'), isTrue);
    });

    test('"¿En qué puedo ayudarte?" tampoco', () {
      expect(isEmptyPleasantry('En qué puedo ayudarte'), isTrue);
    });

    test('"Entendido" no es una respuesta', () {
      expect(isEmptyPleasantry('Entendido.'), isTrue);
    });

    test('una respuesta de verdad pasa', () {
      expect(
        isEmptyPleasantry('Qué fecha tan bonita. ¿Lo celebran cada año?'),
        isFalse,
      );
    });

    test('una pregunta legítima sobre lo dicho pasa', () {
      // El filtro busca fórmulas de recepcionista, no preguntas.
      expect(isEmptyPleasantry('¿Y cómo se llama ella?'), isFalse);
    });
  });
}
