// "La actualización no me llegó" — cuando sí llegó.
//
// Measured on the user's own laptop:
//
//   /opt/lifeos/current -> releases/889      instalado 07:03
//   proceso /opt/lifeos/current/bundle/lifeos  arrancado 00:23
//
// The update had downloaded and installed correctly six hours before he
// looked. What he had open was the process he started at midnight, and
// replacing a binary on disk does not change a process already running.
//
// So the OTA was fine and the PRODUCT was not: there was no way for him to
// know. He concluded the update had not arrived, which is the reasonable
// conclusion from what the app showed him.
//
// On Android this never happens — installing an APK restarts the app. It is a
// desktop-only situation, and this is the desktop-only answer.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/restart_pending.dart';

void main() {
  group('when to ask for a restart', () {
    test('a newer build on disk means the running one is stale', () {
      expect(needsRestart(running: 888, installed: 889), isTrue);
    });

    test('the same build asks for nothing', () {
      expect(needsRestart(running: 889, installed: 889), isFalse);
    });

    test('an OLDER build on disk is not a restart prompt', () {
      // A rollback, or a stale file. Telling someone to restart INTO an older
      // version is worse than saying nothing.
      expect(needsRestart(running: 889, installed: 888), isFalse);
    });

    test('unknown values never prompt', () {
      // package_info can fail, and /opt may not exist at all (Android, a dev
      // run). Silence is the only safe answer: a restart prompt that appears
      // for no reason trains people to ignore it.
      expect(needsRestart(running: null, installed: 889), isFalse);
      expect(needsRestart(running: 888, installed: null), isFalse);
      expect(needsRestart(running: null, installed: null), isFalse);
    });
  });

  group('reading the installed manifest', () {
    test('it reads the version out of what the installer left', () {
      expect(
        installedVersionFrom(
            '{"versionCode": 889, "versionName": "0.10.1"}'),
        889,
      );
    });

    test('junk on disk is not a version', () {
      // A half-written file during an update must not be read as a number.
      for (final broken in const ['', 'not json', '{}', '{"versionCode": "x"}']) {
        expect(installedVersionFrom(broken), isNull, reason: broken);
      }
    });
  });

  group('what it says', () {
    test('it names the version and what to do about it', () {
      final message = restartMessage(installedName: '0.10.1');

      expect(message, contains('0.10.1'));
      expect(message.toLowerCase(), contains('cierra'));
    });

    test('it does not blame the user or the network', () {
      final message = restartMessage(installedName: '0.10.1').toLowerCase();

      for (final wrong in ['error', 'falló', 'revisa tu conexión']) {
        expect(message, isNot(contains(wrong)));
      }
    });
  });
}
