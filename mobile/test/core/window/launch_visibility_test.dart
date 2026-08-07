import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/launch/launch_options.dart';
import 'package:lifeos/core/tray/tray_hosts.dart';
import 'package:lifeos/core/tray/tray_status.dart';
import 'package:lifeos/core/window/launch_visibility.dart';

/// "Start hidden" is only safe while there is a tray icon to get back from.
///
/// A window that never appears AND a tray that never appeared is an app the
/// user cannot reach at all — no icon, no window, just a process. So the
/// decision is not "was --hidden passed" but "was --hidden passed AND did the
/// tray really come up", and the failure direction is always towards visible.
///
/// Asserted through the existing `AppWindowHost` tray seam, so no real window
/// is ever created.
class _RecordingWindow implements AppWindowHost {
  final List<String> calls = [];

  @override
  set onCloseRequested(Future<void> Function() handler) {}

  @override
  Future<void> ensureInitialized() async => calls.add('ensureInitialized');

  @override
  Future<void> setPreventClose(bool prevent) async =>
      calls.add('setPreventClose($prevent)');

  @override
  Future<void> showAndFocus() async => calls.add('showAndFocus');

  @override
  Future<void> hide() async => calls.add('hide');

  @override
  Future<void> quit() async => calls.add('quit');
}

TrayUnavailable _unavailable() => TrayUnavailable(
      reason: 'no StatusNotifier host',
      error: StateError('x'),
      stackTrace: StackTrace.empty,
    );

void main() {
  group('windowShouldBeVisibleAtLaunch', () {
    test('a normal launch is visible, tray or no tray', () {
      expect(
        windowShouldBeVisibleAtLaunch(startHidden: false, trayActive: true),
        isTrue,
      );
      expect(
        windowShouldBeVisibleAtLaunch(startHidden: false, trayActive: false),
        isTrue,
      );
    });

    test('--hidden with a working tray hides the window', () {
      expect(
        windowShouldBeVisibleAtLaunch(startHidden: true, trayActive: true),
        isFalse,
      );
    });

    test('--hidden with NO tray still shows the window', () {
      // The loud-failure direction. The tray notice is already rendered by the
      // app, but the user has to be able to SEE it.
      expect(
        windowShouldBeVisibleAtLaunch(startHidden: true, trayActive: false),
        isTrue,
      );
    });
  });

  group('applyLaunchVisibility', () {
    test('hides when launched hidden and the tray is up', () async {
      final window = _RecordingWindow();
      await applyLaunchVisibility(
        window: window,
        options: const LaunchOptions(startHidden: true),
        trayStatus: const TrayActive(),
      );
      expect(window.calls, ['hide']);
    });

    test('shows when launched hidden but the tray failed', () async {
      final window = _RecordingWindow();
      await applyLaunchVisibility(
        window: window,
        options: const LaunchOptions(startHidden: true),
        trayStatus: _unavailable(),
      );
      expect(window.calls, ['showAndFocus']);
    });

    test('a pending tray is not an active tray', () async {
      // start() has not resolved, so nothing has been proven. Visible.
      final window = _RecordingWindow();
      await applyLaunchVisibility(
        window: window,
        options: const LaunchOptions(startHidden: true),
        trayStatus: const TrayPending(),
      );
      expect(window.calls, ['showAndFocus']);
    });

    test('a normal launch does not touch the window at all', () async {
      // Nothing to correct: the runner already showed it. Calling show() here
      // would steal focus from whatever the user was doing.
      final window = _RecordingWindow();
      await applyLaunchVisibility(
        window: window,
        options: LaunchOptions.visible,
        trayStatus: const TrayActive(),
      );
      expect(window.calls, isEmpty);
    });
  });
}
