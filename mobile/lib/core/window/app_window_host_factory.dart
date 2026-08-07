import '../tray/tray_hosts.dart';
import 'app_window_host_io.dart'
    if (dart.library.html) 'app_window_host_web.dart' as impl;

/// The one function outside the tray that reaches `window_manager`, behind the
/// same conditional-import seam `core/tray/tray_controller_factory.dart` uses.
///
/// It exists because "start hidden" has to be able to REVEAL the window on the
/// path where the tray failed — and on that path there is no tray controller
/// to ask, by construction (`TrayService` drops a controller that failed to
/// install). Reusing the tray's `AppWindowHost` port keeps that one extra
/// call testable without adding a second window abstraction.
AppWindowHost createAppWindowHost() => impl.createAppWindowHost();
