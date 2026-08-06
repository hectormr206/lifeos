import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tray/tray_platform.dart';

/// Whether the app should install a tray icon on its own at startup.
///
/// Two conditions, and the second one is not cosmetic. The widget-test suite
/// runs on a LINUX HOST, which `trayIsSupportedOn` correctly calls a tray
/// platform — so without this guard every test that pumps `LifeOSApp` would
/// try to install a REAL system tray icon on the machine running the tests,
/// and (on a headless box) would then report a real, loud tray failure into
/// roughly 1 700 unrelated tests.
///
/// Suppressing the loud failure instead would have been the wrong fix: the
/// point is not to start the tray at all under `flutter test`, so the
/// loud-failure path stays exactly as loud as it is in production.
void main() {
  group('trayShouldAutoStart', () {
    test('is false under `flutter test`, whatever the host OS is', () {
      // This process IS a flutter test, and it is running on a desktop OS.
      expect(trayIsSupportedOn(currentTrayPlatform()), isTrue,
          reason: 'the suite runs on a desktop host, which is the whole risk');
      expect(runningUnderFlutterTest(), isTrue);
      expect(trayShouldAutoStart(), isFalse);
    });
  });

  group('trayAutoStartDecision — the same rule, without the ambient process', () {
    test('starts on a desktop platform outside the test harness', () {
      expect(
        trayAutoStartDecision(operatingSystem: 'linux', underTest: false),
        isTrue,
      );
    });

    test('never starts on a mobile platform, test harness or not', () {
      for (final underTest in [true, false]) {
        expect(
          trayAutoStartDecision(operatingSystem: 'android', underTest: underTest),
          isFalse,
        );
        expect(
          trayAutoStartDecision(operatingSystem: 'ios', underTest: underTest),
          isFalse,
        );
      }
    });

    test('never starts under the test harness, even on desktop', () {
      expect(
        trayAutoStartDecision(operatingSystem: 'linux', underTest: true),
        isFalse,
      );
    });
  });
}
