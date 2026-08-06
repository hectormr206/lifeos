import 'tray_controller.dart';

/// Web half of the tray factory seam.
///
/// `tray_manager` and `window_manager` both import `dart:io`, so they cannot
/// exist in a browser build at all — and a browser tab has no system tray to
/// put an icon in. `trayIsSupportedOn('web')` is false, so `TrayService` never
/// reaches this; it throws rather than returning a do-nothing controller,
/// because a silent no-op is exactly the degradation this feature forbids.
TrayController createDesktopTrayController() => throw TrayUnavailableException(
      'A browser tab has no system tray. This should be unreachable: '
      'TrayService checks trayIsSupportedOn() first.',
    );
