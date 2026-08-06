import 'tray_controller.dart';
import 'tray_manager_hosts.dart'
    if (dart.library.html) 'tray_controller_factory_web.dart' as impl;

/// The one function that reaches the desktop tray plugins, behind the same
/// conditional-import seam `core/tls/tls_adapter_factory.dart` already uses.
///
/// Web needs the seam for a hard reason: `tray_manager` and `window_manager`
/// both import `dart:io`, so merely REFERENCING them from a library the web
/// build compiles would break `flutter build web` — and this app ships a web
/// target. The web stub therefore replaces them outright.
///
/// Android/iOS need no such trick and get something stronger: `TrayService`
/// only calls this after `trayIsSupportedOn` says the platform has a tray, so
/// on a phone it is never invoked, and neither plugin registers there anyway
/// (`tray_plugin_isolation_test.dart`).
TrayController createTrayController() => impl.createDesktopTrayController();
