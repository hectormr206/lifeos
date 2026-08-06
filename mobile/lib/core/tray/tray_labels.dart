import 'package:flutter/foundation.dart';

/// The user-visible text of the system-tray icon and its menu.
///
/// Passed IN rather than read from a `BuildContext` inside the tray code: the
/// tray lives in `core/`, has no widget tree of its own, and is installed from
/// a post-frame callback in `app.dart` where `AppLocalizations` is available.
/// That also makes every string here assertable in a host test.
///
/// Switching language re-applies these (see `TrayService.start`), so the menu
/// follows the app's language selector instead of freezing at whatever the
/// locale was when the icon was first installed.
@immutable
class TrayMenuLabels {
  const TrayMenuLabels({
    required this.tooltip,
    required this.showWindow,
    required this.quit,
  });

  /// Hover text on the tray icon itself.
  final String tooltip;

  /// Menu item that brings the (possibly hidden) window back and focuses it.
  final String showWindow;

  /// Menu item that really terminates the process. This one is NOT optional:
  /// the window's close button only hides the app, so without a working quit
  /// the user would have an app he cannot close.
  final String quit;

  @override
  bool operator ==(Object other) =>
      other is TrayMenuLabels &&
      other.tooltip == tooltip &&
      other.showWindow == showWindow &&
      other.quit == quit;

  @override
  int get hashCode => Object.hash(tooltip, showWindow, quit);

  @override
  String toString() =>
      'TrayMenuLabels(tooltip: $tooltip, showWindow: $showWindow, quit: $quit)';
}
