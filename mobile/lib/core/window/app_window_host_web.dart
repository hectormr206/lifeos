import '../tray/tray_controller.dart';
import '../tray/tray_hosts.dart';

/// Web half of the window-host seam.
///
/// `window_manager` imports `dart:io`, so merely referencing it from a library
/// the web build compiles would break `flutter build web` — and this app ships
/// a web target. A browser tab also has no window to hide and no tray to hide
/// into, so this throws rather than returning a do-nothing host: a silent
/// no-op is exactly the degradation this feature forbids.
AppWindowHost createAppWindowHost() => throw TrayUnavailableException(
      'A browser tab has no application window to show or hide. This should '
      'be unreachable: the caller checks trayShouldAutoStart() first.',
    );
