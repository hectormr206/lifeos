import 'dart:async';

import 'tray_controller.dart';
import 'tray_hosts.dart';
import 'tray_labels.dart';

/// The tray behaviour itself, expressed only in terms of [TrayIconHost] and
/// [AppWindowHost] so every rule below is provable on a headless host.
///
/// ── CHOSEN BEHAVIOUR: HIDE TO TRAY ───────────────────────────────────────
/// Closing the window HIDES it; LifeOS keeps running behind the tray icon,
/// which is what makes the icon mean "the thing is alive" the way the user's
/// Axi tray does. An app that dies on close would make the icon pointless —
/// it could only ever be visible while the window already was.
///
/// That is only defensible because of two invariants, both asserted in
/// `desktop_tray_controller_test.dart`:
///
///   1. the menu always carries a REAL quit ([TrayMenuAction.quit] lifts
///      prevent-close and terminates — it is not another hide), and
///   2. prevent-close is armed LAST, only after the icon is genuinely
///      installed. If the tray fails, the close button keeps its normal
///      meaning and the user is never trapped in a window that will not close.
///
/// Invariant 2 is why [install] arms prevent-close after the icon rather than
/// before: the ordering is the safety property.
class DesktopTrayController implements TrayController {
  DesktopTrayController({
    required this._icon,
    required this._window,
    required this._iconPath,
  });

  final TrayIconHost _icon;
  final AppWindowHost _window;
  final String _iconPath;

  bool _installed = false;

  @override
  Future<void> install(TrayMenuLabels labels) async {
    await _window.ensureInitialized();

    // Wired before the icon exists so no click can arrive unhandled.
    _icon.onMenuSelection = _onMenuSelection;

    // Throws on a session with no tray host. Deliberately NOT swallowed:
    // TrayService turns it into a visible "tray unavailable" notice, and
    // hiding it here is what would make the failure quiet.
    try {
      await _icon.install(labels, iconPath: _iconPath);
    } catch (_) {
      // `tray_manager` is a process-wide singleton the icon host registers
      // itself on. TrayService drops a controller that failed and builds a
      // fresh one on the next attempt, so without this each retry would leave
      // another orphaned listener attached to that singleton.
      //
      // The cleanup is best-effort BY DESIGN: if destroy() also fails, that
      // secondary error must not replace the real reason the tray did not
      // come up, which is the only part the user can act on.
      try {
        await _icon.destroy();
      } catch (_) {
        // Intentionally discarded — see above. The original error rethrows.
      }
      rethrow;
    }
    _installed = true;

    // LAST. Everything above must have succeeded before the close button is
    // allowed to stop meaning "close" — see invariant 2 in the class doc.
    _window.onCloseRequested = _onCloseRequested;
    await _window.setPreventClose(true);
  }

  @override
  Future<void> applyLabels(TrayMenuLabels labels) => _icon.setMenu(labels);

  @override
  Future<void> dispose() async {
    if (!_installed) return;
    _installed = false;
    // Icon first: the desktop environment must not be left painting an icon
    // whose process is on its way out — that is the ghost icon.
    await _icon.destroy();
    await _window.setPreventClose(false);
  }

  /// The window's close button while hide-to-tray is armed.
  Future<void> _onCloseRequested() => _window.hide();

  void _onMenuSelection(TrayMenuAction action) {
    // Fire-and-forget: the plugin's click callback is synchronous.
    unawaited(_handle(action));
  }

  Future<void> _handle(TrayMenuAction action) async {
    switch (action) {
      case TrayMenuAction.showWindow:
        await _window.showAndFocus();
      case TrayMenuAction.quit:
        // Order matters. Remove the icon while the process is still alive
        // (no ghost), then disarm prevent-close so the quit is not intercepted
        // by the very handler that turns a close into a hide, then exit.
        _installed = false;
        try {
          await _icon.destroy();
        } catch (_) {
          // Removing the icon is best-effort HERE and nowhere else. Because
          // the window's close button only hides, this menu item is the user's
          // only way out of LifeOS — letting a failed destroy() short-circuit
          // the quit would turn hide-to-tray into an app that cannot be
          // closed. A leftover icon is a far cheaper bug than that.
        }
        await _window.setPreventClose(false);
        await _window.quit();
    }
  }
}
