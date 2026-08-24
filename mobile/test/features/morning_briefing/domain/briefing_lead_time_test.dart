// La hora que el usuario elige es cuando el boletín debe estar LISTO.
//
// Medido en el Pixel de pruebas: con la hora puesta a las 8:00, el boletín del
// 2026-08-23 quedó sellado a las 08:10. La tarea arrancaba a las 8:00 y tardaba
// diez minutos en leer, traducir y redactar; a las 8:00 no había nada que leer.
// El usuario lo dijo con sus palabras: "si lo necesito a las 7am listo, debería
// empezar a hacerse desde antes".
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';

void main() {
  const schedule = BriefingSchedule(hour: 7, minute: 0);
  final lead = BriefingSchedule.lead;

  group('la generación arranca con anticipación', () {
    test('la anticipación cubre de sobra lo que tarda de verdad', () {
      expect(
        lead,
        greaterThanOrEqualTo(const Duration(minutes: 10)),
        reason: 'el boletín medido tardó 10 minutos',
      );
    });

    test('nextStart va justo una anticipación antes de la hora elegida', () {
      final now = DateTime(2026, 8, 24, 5, 0);
      expect(
        schedule.nextStart(now),
        DateTime(2026, 8, 24, 7, 0).subtract(lead),
      );
    });

    test('a la hora elegida el boletín ya debe existir, no empezar', () {
      // Un minuto antes del arranque todavía no toca...
      final antes = DateTime(2026, 8, 24, 7, 0).subtract(
        lead + const Duration(minutes: 1),
      );
      expect(schedule.shouldRunNow(antes), isFalse);

      // ...y en el instante del arranque, sí.
      final arranque = DateTime(2026, 8, 24, 7, 0).subtract(lead);
      expect(schedule.shouldRunNow(arranque), isTrue);
    });

    test('abrir la app entre el arranque y la hora también lo dispara', () {
      final enMedio = DateTime(2026, 8, 24, 7, 0).subtract(
        Duration(minutes: lead.inMinutes ~/ 2),
      );
      expect(schedule.shouldRunNow(enMedio), isTrue);
    });

    test('si ya se generó hoy, no se vuelve a generar', () {
      final arranque = DateTime(2026, 8, 24, 7, 0).subtract(lead);
      expect(
        schedule.shouldRunNow(
          arranque,
          lastGeneratedAt: DateTime(2026, 8, 24, 6, 0),
        ),
        isFalse,
      );
    });

    test('pasado el arranque de hoy, el siguiente es el de mañana', () {
      final now = DateTime(2026, 8, 24, 7, 30);
      expect(
        schedule.nextStart(now),
        DateTime(2026, 8, 25, 7, 0).subtract(lead),
      );
    });

    test('apagado no arranca nunca', () {
      const off = BriefingSchedule(enabled: false, hour: 7, minute: 0);
      expect(
        off.shouldRunNow(DateTime(2026, 8, 24, 7, 0).subtract(lead)),
        isFalse,
      );
    });

    test('una hora tan temprana que el arranque cae ayer sigue siendo válida', () {
      // 00:05 con anticipación de 15 min ⇒ el arranque es a las 23:50 del día
      // anterior. Debe seguir apuntando al boletín de ESE día siguiente.
      const madrugada = BriefingSchedule(hour: 0, minute: 5);
      final now = DateTime(2026, 8, 24, 23, 0);
      final start = madrugada.nextStart(now);
      expect(start.isAfter(now), isTrue);
      expect(start.add(lead), DateTime(2026, 8, 25, 0, 5));
    });
  });
}

// El sello del boletín es la única evidencia visible de si la generación
// automática ocurrió. Antes se ponía ANTES de descargar nada, así que decía
// cuándo ARRANCÓ la tarea; leído por el usuario, y por mí al diagnosticar,
// parecía la hora en que el boletín quedó hecho.
