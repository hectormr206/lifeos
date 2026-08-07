/// Whether the window should be on screen just after startup.
///
/// "Start hidden" is only safe while there is a tray icon to come back from.
/// A window that never appears AND a tray that never appeared is an app the
/// user cannot reach at all — no icon, no window, just a process holding his
/// data hostage. So the question is not "was `--hidden` passed" but "was
/// `--hidden` passed AND did the tray really come up", and every uncertain
/// answer resolves towards VISIBLE.
///
/// Expressed against `AppWindowHost`, the port the tray already owns, so this
/// is provable on a headless machine and no `window_manager` import comes
/// anywhere near it.
library;

import '../launch/launch_options.dart';
import '../tray/tray_hosts.dart';
import '../tray/tray_status.dart';

/// The whole decision, as a pure function.
///
/// [trayActive] must mean "an icon is genuinely in the tray right now", not
/// "we asked for one" — see [applyLaunchVisibility], which derives it from
/// [TrayActive] and treats [TrayPending] as "not proven".
bool windowShouldBeVisibleAtLaunch({
  required bool startHidden,
  required bool trayActive,
}) =>
    !startHidden || !trayActive;

/// Applies [windowShouldBeVisibleAtLaunch] through the window port.
///
/// A NORMAL launch touches nothing: the desktop runner already showed the
/// window, and calling `show()` again would steal focus from whatever the user
/// was doing while LifeOS was starting.
Future<void> applyLaunchVisibility({
  required AppWindowHost window,
  required LaunchOptions options,
  required TrayStatus trayStatus,
}) async {
  if (!options.startHidden) return;

  if (windowShouldBeVisibleAtLaunch(
    startHidden: true,
    trayActive: trayStatus is TrayActive,
  )) {
    // The loud direction. The tray failed, so the "no system tray icon" notice
    // is already mounted — the user just has to be able to SEE it.
    await window.showAndFocus();
    return;
  }
  await window.hide();
}
