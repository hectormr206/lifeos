import 'dart:io' show Platform;

/// IO (Android, iOS, Linux, macOS, Windows) half of the tray platform probe.
/// Reports the real OS name so [trayIsSupportedOn] can route it.
String currentOperatingSystem() => Platform.operatingSystem;

/// Whether this process is a `flutter test` run.
///
/// `flutter test` sets `FLUTTER_TEST=true` in the child environment (verified
/// by running a probe test, not assumed). The tray needs to know because the
/// widget-test suite runs on a real Linux host: without this, every test that
/// pumps `LifeOSApp` would install a real system tray icon on the machine
/// running the tests.
bool runningUnderFlutterTest() =>
    Platform.environment.containsKey('FLUTTER_TEST');
