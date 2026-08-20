// El respaldo que sí ocurre.
//
// Ya existe todo: respaldo cifrado manual, respaldo automático al servidor por
// VPN, y exportación. Nada de eso protege a nadie, porque "las copias existen
// pero hay que activarlas antes, y nadie activa copias antes de necesitarlas".
// Lo que falta no es mecanismo: es que la pregunta se haga, y que se vuelva a
// hacer mientras la respuesta siga siendo "todavía no".
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/first_day/domain/backup_nag.dart';

void main() {
  final hoy = DateTime(2026, 8, 20, 10);

  group('cuándo volver a preguntar por el respaldo', () {
    test('el primer día no se pregunta: no hay nada que perder todavía', () {
      // Respaldar una app vacía no protege a nadie y gasta la única vez que la
      // persona iba a leer el aviso con atención. La pregunta tiene sentido
      // cuando ya hay vida dentro.
      expect(
        shouldAskForBackup(
          const BackupState(
            hasBackup: false,
            postponedAt: null,
            askedTimes: 0,
            entriesStored: 0,
          ),
          now: hoy,
        ),
        isFalse,
      );
    });

    test('con unas pocas cosas guardadas ya hay algo que perder', () {
      expect(
        shouldAskForBackup(
          const BackupState(
            hasBackup: false,
            postponedAt: null,
            askedTimes: 0,
            entriesStored: kEntriesWorthProtecting,
          ),
          now: hoy,
        ),
        isTrue,
      );
    });

    test('con una copia hecha, nunca más', () {
      // Recordarle una copia a quien ya la tiene es la clase de aviso que
      // enseña a la gente a ignorar los avisos.
      expect(
        shouldAskForBackup(
          const BackupState(hasBackup: true, postponedAt: null, askedTimes: 0, entriesStored: 500),
          now: hoy,
        ),
        isFalse,
      );
    });

    test('sin copia y sin haber preguntado nunca, sí', () {
      expect(
        shouldAskForBackup(
          const BackupState(hasBackup: false, postponedAt: null, askedTimes: 0, entriesStored: 500),
          now: hoy,
        ),
        isTrue,
      );
    });

    test('si dijo "luego" hoy, hoy no se le vuelve a preguntar', () {
      expect(
        shouldAskForBackup(
          BackupState(
            hasBackup: false,
            postponedAt: hoy.subtract(const Duration(hours: 3)),
            askedTimes: 1,
            entriesStored: 500,
          ),
          now: hoy,
        ),
        isFalse,
      );
    });

    test('a la semana se vuelve a preguntar', () {
      expect(
        shouldAskForBackup(
          BackupState(
            hasBackup: false,
            postponedAt: hoy.subtract(const Duration(days: 8)),
            askedTimes: 1,
            entriesStored: 500,
          ),
          now: hoy,
        ),
        isTrue,
      );
    });

    test('cada vez que lo pospone, tarda más en volver', () {
      // Preguntar siempre igual de seguido es acoso; dejar de preguntar es
      // abandonarlo. El intervalo crece, pero la pregunta no desaparece.
      final unaVez = BackupState(
        hasBackup: false,
        postponedAt: hoy.subtract(const Duration(days: 8)),
        askedTimes: 1,
        entriesStored: 500,
      );
      final cuatroVeces = BackupState(
        hasBackup: false,
        postponedAt: hoy.subtract(const Duration(days: 8)),
        askedTimes: 4,
        entriesStored: 500,
      );

      expect(shouldAskForBackup(unaVez, now: hoy), isTrue);
      expect(shouldAskForBackup(cuatroVeces, now: hoy), isFalse);
    });

    test('por mucho que lo posponga, no se le deja de preguntar', () {
      // Sin tope, alguien que dijo "luego" veinte veces se quedaría sin
      // respaldo y sin nadie que se lo recuerde nunca más.
      expect(
        shouldAskForBackup(
          BackupState(
            hasBackup: false,
            postponedAt: hoy.subtract(const Duration(days: 400)),
            askedTimes: 99,
            entriesStored: 500,
          ),
          now: hoy,
        ),
        isTrue,
      );
    });

    test('el tope de espera son ocho semanas', () {
      expect(backupNagDelay(99), const Duration(days: 56));
    });

    test('un reloj que va para atrás no dispara la pregunta', () {
      // Cambiar la zona horaria o corregir la hora no debe convertirse en un
      // aviso inmediato.
      expect(
        shouldAskForBackup(
          BackupState(
            hasBackup: false,
            postponedAt: hoy.add(const Duration(days: 2)),
            askedTimes: 1,
            entriesStored: 500,
          ),
          now: hoy,
        ),
        isFalse,
      );
    });
  });
}
