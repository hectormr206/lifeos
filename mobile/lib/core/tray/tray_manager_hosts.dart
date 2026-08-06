import 'dart:io' show Platform;

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_tray_controller.dart';
import 'tray_controller.dart';
import 'tray_hosts.dart';
import 'tray_icon_path.dart';
import 'tray_labels.dart';

/// The two EDGE adapters that actually speak to `tray_manager` and
/// `window_manager`, plus the factory that assembles them.
///
/// Everything interesting — hide-to-tray, the real quit, the no-ghost-icon
/// ordering, the platform guard, the loud failure — lives in
/// `DesktopTrayController` and `TrayService` behind the ports in
/// `tray_hosts.dart`, and is covered by host tests. What is left here is
/// deliberately as close to zero logic as possible, because this is the part
/// that CANNOT be exercised on a headless machine: this file's behaviour is
/// only observable on a real desktop session with a real tray.
///
/// This file is reachable ONLY through [createDesktopTrayController], which
/// `TrayService` invokes only after `trayIsSupportedOn` says yes. On Android
/// and iOS it is never called, and neither plugin registers there at all.

/// `tray_manager` side of the tray.
class TrayManagerIconHost with TrayListener implements TrayIconHost {
  TrayManagerIconHost({String? operatingSystem})
      : _operatingSystem = operatingSystem ?? Platform.operatingSystem;

  final String _operatingSystem;
  void Function(TrayMenuAction action)? _onMenuSelection;

  @override
  set onMenuSelection(void Function(TrayMenuAction action) handler) =>
      _onMenuSelection = handler;

  @override
  Future<void> install(TrayMenuLabels labels, {required String iconPath}) async {
    trayManager.addListener(this);
    try {
      await trayManager.setIcon(iconPath);
      // Linux answers `not_implemented` to setToolTip (see
      // [trayTooltipIsSupportedOn]); calling it there would report a working
      // tray as broken.
      if (trayTooltipIsSupportedOn(_operatingSystem)) {
        await trayManager.setToolTip(labels.tooltip);
      }
      await setMenu(labels);
    } catch (error) {
      // Translate, do not swallow. A raw PlatformException tells the user
      // nothing he can act on; [TrayUnavailableException.noHost] carries the
      // original error AND names the two things he can actually check — a
      // session with no StatusNotifier host, and a missing
      // libayatana-appindicator3. That message is what the in-app notice
      // shows, so it has to be worth reading.
      throw TrayUnavailableException.noHost(error);
    }
  }

  @override
  Future<void> setMenu(TrayMenuLabels labels) => trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(
              key: 'show_window',
              label: labels.showWindow,
              onClick: (_) => _onMenuSelection?.call(TrayMenuAction.showWindow),
            ),
            MenuItem.separator(),
            MenuItem(
              key: 'quit',
              label: labels.quit,
              onClick: (_) => _onMenuSelection?.call(TrayMenuAction.quit),
            ),
          ],
        ),
      );

  @override
  Future<void> destroy() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  /// Left-clicking the icon reopens the window. Never fires on Linux (the
  /// AppIndicator host opens the menu itself), which is why the menu carries
  /// an explicit "show" item rather than relying on this.
  @override
  void onTrayIconMouseDown() => _onMenuSelection?.call(TrayMenuAction.showWindow);

  /// Windows needs the context menu popped explicitly; Linux/macOS do it.
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
}

/// `window_manager` side of the tray.
class WindowManagerAppWindowHost with WindowListener implements AppWindowHost {
  Future<void> Function()? _onCloseRequested;

  @override
  set onCloseRequested(Future<void> Function() handler) {
    _onCloseRequested = handler;
    windowManager.addListener(this);
  }

  @override
  Future<void> ensureInitialized() => windowManager.ensureInitialized();

  @override
  Future<void> setPreventClose(bool prevent) =>
      windowManager.setPreventClose(prevent);

  @override
  Future<void> showAndFocus() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> quit() => windowManager.destroy();

  /// Only reached while prevent-close is armed, i.e. only while the tray icon
  /// really exists — that ordering is enforced in [DesktopTrayController] and
  /// is what stops a failed tray from producing an unclosable window.
  @override
  void onWindowClose() {
    _onCloseRequested?.call();
  }
}

/// Builds the production tray controller. This function is the single
/// construction site of both desktop plugins.
TrayController createDesktopTrayController() => DesktopTrayController(
      icon: TrayManagerIconHost(),
      window: WindowManagerAppWindowHost(),
      // Throws TrayUnavailableException when no icon file is anywhere to be
      // found — TrayService turns that into the visible notice.
      iconPath: resolveTrayIconPathForHost(),
    );
