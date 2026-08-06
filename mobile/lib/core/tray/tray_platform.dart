import 'tray_host_io.dart' if (dart.library.html) 'tray_host_web.dart' as host;

/// The platform seam for the system-tray icon (desktop shell slice).
///
/// Same shape as `core/graph/graph_database_backend.dart`'s
/// `graphDatabaseBackendFor`: the decision takes the operating-system NAME as
/// a parameter instead of reading `Platform` inline, so a Linux host test can
/// assert what the ANDROID build does. That is not a stylistic preference —
/// Android carries the user's real data, and the whole tray feature must be
/// provably inert there.
///
/// `tray_manager` and `window_manager` each declare exactly
/// `linux macos windows` in their pubspec `flutter.plugin.platforms`. There is
/// no Android or iOS implementation to register, no method channel to answer,
/// and nothing for the Gradle/CocoaPods side to build — see
/// `test/core/tray/tray_plugin_isolation_test.dart`, which asserts that
/// against the resolved plugin map rather than trusting this comment.
///
/// Windows and macOS return true even though this repo has no `windows/` or
/// `macos/` runner yet. That is deliberate: adding one is then a
/// `flutter create --platforms=windows` away and not a code change.
bool trayIsSupportedOn(String operatingSystem) {
  switch (operatingSystem) {
    case 'linux':
    case 'macos':
    case 'windows':
      return true;
    default:
      // android, ios, web, fuchsia, anything unknown. Unlike the encrypted
      // graph backend — which MUST throw on an unknown platform, because the
      // alternative is silently writing user data in plaintext — an absent
      // tray costs the user nothing but a convenience. Refusing to start the
      // app over it would be the wrong trade, so this is a plain `false` and
      // the caller reports "no tray on this platform" rather than an error.
      return false;
  }
}

/// Whether the app should install a tray icon on its own at startup.
///
/// Two conditions, and the second is not cosmetic. The widget-test suite runs
/// on a LINUX HOST, which [trayIsSupportedOn] correctly calls a tray platform —
/// so without this guard every test that pumps `LifeOSApp` would try to
/// install a REAL system tray icon on the machine running the tests, and on a
/// headless box would then report a real, loud tray failure into ~1 700
/// unrelated tests.
///
/// Note what this does NOT do: it does not soften the loud-failure path. The
/// tray simply is not started under `flutter test`; when it IS started, a
/// failure is exactly as loud as in production.
bool trayAutoStartDecision({
  required String operatingSystem,
  required bool underTest,
}) =>
    trayIsSupportedOn(operatingSystem) && !underTest;

/// [trayAutoStartDecision] for the running process.
bool trayShouldAutoStart() => trayAutoStartDecision(
      operatingSystem: currentTrayPlatform(),
      underTest: runningUnderFlutterTest(),
    );

/// Whether this process is a `flutter test` run — see [trayAutoStartDecision].
bool runningUnderFlutterTest() => host.runningUnderFlutterTest();

/// The operating-system name of the host this process is running on, with
/// `'web'` as the sentinel for a browser build (where `dart:io`'s `Platform`
/// does not exist at all). Resolved through the same conditional-import
/// pattern `core/tls/tls_adapter_factory.dart` already uses.
String currentTrayPlatform() => host.currentOperatingSystem();
