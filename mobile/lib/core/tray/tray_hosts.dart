import 'tray_labels.dart';

/// Which tray menu item the user picked.
///
/// A closed enum rather than raw menu-item keys so the plugin's string ids
/// never leak past the adapter and `DesktopTrayController`'s decision table
/// stays exhaustively checkable.
enum TrayMenuAction {
  /// Bring the (possibly hidden) window back and focus it.
  showWindow,

  /// Really terminate the process — see `TrayMenuLabels.quit`.
  quit,
}

/// The tray-icon port (`tray_manager` in production).
///
/// Exists so the whole hide-to-tray / real-quit / no-ghost-icon behaviour is
/// provable on a HEADLESS machine: this repo's CI, and the box this feature
/// was written on, have no display and no system tray at all.
abstract class TrayIconHost {
  /// Called with the user's menu choice. Set before [install].
  set onMenuSelection(void Function(TrayMenuAction action) handler);

  /// Puts the icon in the tray with its menu. Throws if the session refuses.
  Future<void> install(TrayMenuLabels labels, {required String iconPath});

  /// Rebuilds only the menu text (language change).
  Future<void> setMenu(TrayMenuLabels labels);

  /// Removes the icon from the tray.
  Future<void> destroy();
}

/// The app-window port (`window_manager` in production).
abstract class AppWindowHost {
  /// Called when the user clicks the window's close button, but only while
  /// prevent-close is armed. Set before [setPreventClose].
  set onCloseRequested(Future<void> Function() handler);

  /// Binds the plugin's method channel. Must run before anything else here.
  Future<void> ensureInitialized();

  /// When true, the close button fires [onCloseRequested] instead of
  /// destroying the window.
  Future<void> setPreventClose(bool prevent);

  /// Restore + raise + focus.
  Future<void> showAndFocus();

  /// Hide the window without ending the process.
  Future<void> hide();

  /// Really terminate.
  Future<void> quit();
}
