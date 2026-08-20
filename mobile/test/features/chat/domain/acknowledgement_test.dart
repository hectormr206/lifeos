// Lo que Axi dice cuando le cuentas algo.
//
// Sustituye al eco y a "¿Qué necesitas?". Tiene que hacer dos cosas a la vez:
// dejar claro que lo escuchó, y dar pie a seguir hablando. Y no puede inventar
// nada — es la regla que no se rompe ni para sonar natural.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/acknowledgement.dart';
import 'package:lifeos/features/chat/domain/reply_quality.dart';

void main() {
  group('reconocer y seguir', () {
    test('nunca devuelve el mensaje del usuario', () {
      const dicho = 'Nos hicimos novios el 12 de mayo del 2008';
      final respuesta = acknowledgeStatement(dicho);

      expect(isEchoReply(userText: dicho, reply: respuesta), isFalse);
    });

    test('nunca es una fórmula de recepcionista', () {
      final respuesta = acknowledgeStatement('Mi esposa nació en Cadereyta');

      expect(isEmptyPleasantry(respuesta), isFalse);
    });

    test('ante una fecha, pregunta por la fecha', () {
      final respuesta =
          acknowledgeStatement('Nos casamos el 6 de septiembre de 2018');

      expect(respuesta, contains('?'));
    });

    test('dos hechos distintos no reciben la misma frase', () {
      // Contestar siempre igual es otra forma de no escuchar.
      final a = acknowledgeStatement('Mi esposa nació en Cadereyta');
      final b = acknowledgeStatement('Nos casamos el 6 de septiembre');

      expect(a, isNot(b));
    });

    test('el mismo hecho dicho dos veces recibe la misma frase', () {
      // Determinista: sin esto, ninguna prueba de arriba probaría nada.
      expect(
        acknowledgeStatement('Mi esposa nació en Cadereyta'),
        acknowledgeStatement('Mi esposa nació en Cadereyta'),
      );
    });

    test('no inventa ningún dato', () {
      // La respuesta puede preguntar, nunca afirmar algo que nadie dijo.
      final respuesta = acknowledgeStatement('Mi hija se llama Ana');

      for (final inventado in ['años', 'nació en', 'vive en', 'trabaja']) {
        expect(respuesta.toLowerCase(), isNot(contains(inventado)));
      }
    });

    test('ante algo íntimo no interroga', () {
      // "El 12 de septiembre del 2008 hicimos el amor por primera vez" no se
      // responde con curiosidad: se responde con respeto y se deja espacio.
      final respuesta = acknowledgeStatement(
          'El 12 de septiembre del 2008 hicimos el amor por primera vez');

      expect(respuesta, isNot(contains('?')),
          reason: 'preguntar aquí convierte una confidencia en un formulario');
      expect(respuesta.length, lessThan(120));
    });

    test('siempre cabe en una frase leída en voz alta', () {
      for (final dicho in [
        'Mi esposa nació en Cadereyta de Montes, Querétaro',
        'Hoy pesé 82 kilos',
        'Mi jefe se llama Ricardo',
      ]) {
        expect(acknowledgeStatement(dicho).length, lessThan(140));
      }
    });
  });
}
