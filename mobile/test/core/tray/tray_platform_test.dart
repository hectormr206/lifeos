import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tray/tray_platform.dart';

/// The platform seam for the system-tray icon.
///
/// Mirrors `graph_database_backend.dart`'s `graphDatabaseBackendFor`: the
/// routing takes the operating-system NAME as a parameter instead of reading
/// `Platform` inline, which is the only reason a Linux CI box can assert what
/// happens on Android. That assertion is the point — Android carries the
/// user's real data, and `tray_manager`/`window_manager` have no Android
/// implementation at all, so every tray code path must be provably dead there.
void main() {
  group('trayIsSupportedOn', () {
    test('supports the three desktop platforms tray_manager implements', () {
      // tray_manager AND window_manager both declare exactly
      // `linux macos windows` in their pubspec plugin platforms (asserted for
      // real against .flutter-plugins-dependencies in
      // tray_plugin_isolation_test.dart). Windows/macOS runners do not exist
      // in this repo yet; listing them here is what lets `flutter create
      // --platforms=windows` be a build step and not a code change.
      expect(trayIsSupportedOn('linux'), isTrue);
      expect(trayIsSupportedOn('windows'), isTrue);
      expect(trayIsSupportedOn('macos'), isTrue);
    });

    test('never supports the mobile platforms', () {
      expect(trayIsSupportedOn('android'), isFalse);
      expect(trayIsSupportedOn('ios'), isFalse);
    });

    test('never supports web', () {
      // `currentTrayPlatform()` reports 'web' from the browser build (there is
      // no dart:io `Platform` there), and a browser tab has no system tray.
      expect(trayIsSupportedOn('web'), isFalse);
    });

    test('an unknown platform is unsupported, not an error', () {
      // Unlike the graph backend — where an unknown OS MUST throw, because
      // there is no safe plaintext fallback for user data — an unknown OS here
      // simply has no tray. The app is fully usable without one, so refusing
      // to start over a missing convenience would be the wrong trade.
      expect(trayIsSupportedOn('fuchsia'), isFalse);
      expect(trayIsSupportedOn(''), isFalse);
    });
  });

  group('currentTrayPlatform', () {
    test('reports the running host, and the host tests run on an OS name', () {
      // Host tests run on the Dart VM (dart:io available), so this must be a
      // real operating-system name and never the 'web' sentinel.
      expect(currentTrayPlatform(), isNot('web'));
      expect(currentTrayPlatform(), isNotEmpty);
    });
  });
}
