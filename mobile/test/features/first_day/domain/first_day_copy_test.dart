// El texto del primer día, fijado.
//
// No es una prueba de ortografía: es la única defensa contra que alguien
// "mejore" esta frase hacia el sitio al que todas estas frases tienden — un
// resumen de funciones, o una lista de lo que la app NO hace.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/first_day/domain/first_day_copy.dart';

void main() {
  group('lo primero que se lee', () {
    test('la promesa cabe en una línea', () {
      // Si no se lee de un vistazo, no se lee.
      expect(kFirstDayPromise.length, lessThan(60));
    });

    test('habla de la persona, no del producto', () {
      const jerga = [
        'sincroniza',
        'cifrad',
        'modelo local',
        'base de datos',
        'grafo',
        'plataforma',
        'IA',
      ];
      final texto = '$kFirstDayPromise $kFirstDayPrivacy'.toLowerCase();
      for (final palabra in jerga) {
        expect(texto, isNot(contains(palabra)),
            reason: '"$palabra" no significa nada el primer día');
      }
    });

    test('dice lo que ES antes que lo que no es', () {
      // "No sube nada a la nube" explica una ausencia. Donde vive tu vida es
      // un hecho, y es lo que la persona necesita saber.
      expect(kFirstDayPrivacy, contains('se queda en este aparato'));
    });

    test('la invitación trae ejemplos cotidianos, no metas', () {
      expect(kFirstDayInvitation, contains('dormiste'));
      expect(kFirstDayInvitation.toLowerCase(), isNot(contains('metas')));
      expect(kFirstDayInvitation.toLowerCase(), isNot(contains('objetivos')));
    });

    test('el botón es un verbo', () {
      expect(kFirstDayCallToAction, startsWith('Contarle'));
    });

    test('se puede entrar sin escribir nada', () {
      // Obligar a escribir para pasar es la forma más rápida de que alguien
      // cierre la app y no vuelva.
      expect(kFirstDayLookAround, isNotEmpty);
    });

    test('tutea, como el resto de la app', () {
      final texto = [
        kFirstDayPromise,
        kFirstDayPrivacy,
        kFirstDayInvitation,
      ].join(' ').toLowerCase();
      for (final usted in ['cuéntenos', 'usted', 'su vida diaria']) {
        expect(texto, isNot(contains(usted)));
      }
    });
  });
}
