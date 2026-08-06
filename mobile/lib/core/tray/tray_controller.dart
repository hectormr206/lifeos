import 'tray_labels.dart';

/// What [TrayService] needs from "a system tray", with no plugin in sight.
///
/// The only production implementation is `DesktopTrayController`
/// (tray_manager + window_manager). Keeping it behind this interface is what
/// lets the platform guard in [TrayService] be a plain closure that is simply
/// never invoked on Android/iOS — no import of the desktop plugins is
/// reachable from the mobile code path, and a host test can prove it.
abstract class TrayController {
  /// Puts the icon in the tray and wires its menu. MUST throw if it cannot —
  /// see [TrayUnavailableException]. Never resolve successfully with no icon.
  Future<void> install(TrayMenuLabels labels);

  /// Rebuilds the menu text (language change) without touching the icon.
  Future<void> applyLabels(TrayMenuLabels labels);

  /// Removes the icon. Called on app teardown so the desktop environment is
  /// not left painting a dead icon that opens nothing.
  Future<void> dispose();
}

/// Raised when the tray genuinely cannot be brought up.
///
/// This exists so the failure is a first-class, message-carrying value instead
/// of a silent no-op. The most common real cause on the target machine is a
/// desktop session with no StatusNotifier host — some Wayland compositors ship
/// without one, and there is nothing the app can do about it except SAY so.
class TrayUnavailableException implements Exception {
  TrayUnavailableException(this.message);

  /// The system tray could not be reached at all.
  factory TrayUnavailableException.noHost(Object cause) =>
      TrayUnavailableException(
        'The desktop session did not accept a tray icon ($cause). Some Wayland '
        'compositors ship without a StatusNotifier host; on Linux the icon '
        'also needs libayatana-appindicator3 installed. LifeOS keeps running '
        'in its window — there is just no icon in the top bar.',
      );

  /// No icon file was found to put in the tray.
  factory TrayUnavailableException.noIcon(List<String> searched) =>
      TrayUnavailableException(
        'No tray icon file was found. A tray icon that renders nothing is '
        'worse than none, so LifeOS refuses to install one. Searched: '
        '${searched.join(", ")}.',
      );

  final String message;

  @override
  String toString() => 'TrayUnavailableException: $message';
}
