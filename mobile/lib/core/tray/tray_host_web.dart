/// Web half of the tray platform probe. `dart:io`'s `Platform` does not exist
/// in a browser build, so there is no OS name to report — and a browser tab
/// has no system tray to put an icon in either. The `'web'` sentinel routes to
/// "unsupported" in [trayIsSupportedOn].
String currentOperatingSystem() => 'web';

/// There is no `flutter test` harness in a browser build of the app, and the
/// answer is moot anyway: `trayIsSupportedOn('web')` is already false.
bool runningUnderFlutterTest() => false;
