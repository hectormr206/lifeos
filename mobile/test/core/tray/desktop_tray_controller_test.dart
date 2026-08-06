import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tray/desktop_tray_controller.dart';
import 'package:lifeos/core/tray/tray_controller.dart';
import 'package:lifeos/core/tray/tray_hosts.dart';
import 'package:lifeos/core/tray/tray_labels.dart';

const _labels = TrayMenuLabels(
  tooltip: 'LifeOS',
  showWindow: 'Abrir LifeOS',
  quit: 'Salir de LifeOS',
);

class _FakeTrayIconHost implements TrayIconHost {
  final List<String> calls = <String>[];
  TrayMenuLabels? labels;
  String? iconPath;
  void Function(TrayMenuAction)? _onSelection;
  Object? failInstallWith;
  Object? failDestroyWith;

  void select(TrayMenuAction action) => _onSelection!(action);

  @override
  set onMenuSelection(void Function(TrayMenuAction action) handler) =>
      _onSelection = handler;

  @override
  Future<void> install(TrayMenuLabels newLabels, {required String iconPath}) async {
    calls.add('install');
    labels = newLabels;
    this.iconPath = iconPath;
    if (failInstallWith != null) throw failInstallWith!;
  }

  @override
  Future<void> setMenu(TrayMenuLabels newLabels) async {
    calls.add('setMenu');
    labels = newLabels;
  }

  @override
  Future<void> destroy() async {
    calls.add('destroy');
    if (failDestroyWith != null) throw failDestroyWith!;
  }
}

class _FakeAppWindowHost implements AppWindowHost {
  final List<String> calls = <String>[];
  bool preventClose = false;
  Future<void> Function()? _onClose;

  Future<void> userClickedTheWindowCloseButton() => _onClose!();

  @override
  set onCloseRequested(Future<void> Function() handler) => _onClose = handler;

  @override
  Future<void> ensureInitialized() async => calls.add('ensureInitialized');

  @override
  Future<void> setPreventClose(bool prevent) async {
    calls.add('setPreventClose($prevent)');
    preventClose = prevent;
  }

  @override
  Future<void> showAndFocus() async => calls.add('showAndFocus');

  @override
  Future<void> hide() async => calls.add('hide');

  @override
  Future<void> quit() async => calls.add('quit');
}

/// The desktop tray behaviour itself, driven entirely through the two ports so
/// it is provable on a HEADLESS host with no display and no system tray.
///
/// CHOSEN BEHAVIOUR: hide-to-tray. Closing the window hides it and leaves
/// LifeOS running behind the tray icon, matching the user's Axi tray. That is
/// only safe because two invariants hold, and both are asserted below:
///
///   1. the tray menu always carries a REAL quit, and
///   2. close-to-hide is armed only AFTER the tray icon genuinely exists —
///      so a failed tray can never produce a window that will not close.
void main() {
  late _FakeTrayIconHost icon;
  late _FakeAppWindowHost window;
  late DesktopTrayController controller;

  setUp(() {
    icon = _FakeTrayIconHost();
    window = _FakeAppWindowHost();
    controller = DesktopTrayController(
      icon: icon,
      window: window,
      iconPath: '/usr/share/icons/hicolor/512x512/apps/lifeos.png',
    );
  });

  group('install', () {
    test('initializes the window, installs the icon, THEN arms hide-to-tray', () async {
      await controller.install(_labels);

      expect(
        window.calls + icon.calls,
        containsAllInOrder(<String>['ensureInitialized']),
      );
      // Ordering is the safety property, not a style preference: prevent-close
      // must be the LAST step, after the icon is on screen.
      expect(icon.calls, ['install']);
      expect(window.calls.last, 'setPreventClose(true)');
      expect(window.preventClose, isTrue);
    });

    test('reuses the .desktop entry icon rather than a new asset', () async {
      await controller.install(_labels);
      expect(icon.iconPath, '/usr/share/icons/hicolor/512x512/apps/lifeos.png');
    });

    test('NEVER arms hide-to-tray when the icon fails to install', () async {
      // Without this the user gets an app he cannot close: no tray icon to
      // reach the quit item from, and a close button that only hides.
      icon.failInstallWith = StateError('no StatusNotifierHost on the bus');

      await expectLater(() => controller.install(_labels), throwsA(isA<StateError>()));

      expect(window.preventClose, isFalse);
      expect(window.calls, isNot(contains('setPreventClose(true)')));
    });

    test('cleans up the half-installed icon before rethrowing', () async {
      // `tray_manager` is a process-wide singleton and the icon host registers
      // itself as a listener on it. TrayService drops a controller that failed
      // to install and builds a fresh one on the next attempt, so without this
      // every retry would leave another orphaned listener attached to the
      // singleton, each one still reacting to menu clicks.
      icon.failInstallWith = StateError('no StatusNotifierHost on the bus');

      await expectLater(() => controller.install(_labels), throwsA(isA<StateError>()));

      expect(icon.calls, ['install', 'destroy']);
    });

    test('a cleanup failure never masks the ORIGINAL error', () async {
      // The reason the tray failed is what the user needs to see. A secondary
      // "destroy also failed" would replace it with noise about the cleanup.
      icon.failInstallWith = StateError('no StatusNotifierHost on the bus');
      icon.failDestroyWith = ArgumentError('destroy blew up too');

      await expectLater(
        () => controller.install(_labels),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('StatusNotifierHost'),
          ),
        ),
      );
    });
  });

  group('the window close button', () {
    test('hides the window and keeps the app alive once the tray is up', () async {
      await controller.install(_labels);
      window.calls.clear();

      await window.userClickedTheWindowCloseButton();

      expect(window.calls, ['hide']);
      expect(window.calls, isNot(contains('quit')));
    });
  });

  group('the tray menu', () {
    test('show/focus brings the hidden window back', () async {
      await controller.install(_labels);
      window.calls.clear();

      icon.select(TrayMenuAction.showWindow);
      await pumpEventQueue();

      expect(window.calls, ['showAndFocus']);
    });

    test('quit destroys the icon BEFORE exiting, so no ghost is left', () async {
      await controller.install(_labels);
      icon.calls.clear();
      window.calls.clear();

      icon.select(TrayMenuAction.quit);
      await pumpEventQueue();

      expect(icon.calls, ['destroy']);
      // Prevent-close is lifted first — otherwise the quit path would be
      // fighting the very handler that turns a close into a hide.
      expect(window.calls, ['setPreventClose(false)', 'quit']);
    });

    test('quit still quits even if removing the icon fails', () async {
      // The single most dangerous failure in this file. The window close
      // button only hides, so the menu's quit is the user's ONLY way out. If a
      // failing `destroy()` short-circuited it, hide-to-tray would have turned
      // LifeOS into an app that cannot be closed — a leftover icon is a far
      // cheaper bug than that.
      await controller.install(_labels);
      icon.failDestroyWith = StateError('the tray host went away');
      window.calls.clear();

      icon.select(TrayMenuAction.quit);
      await pumpEventQueue();

      expect(window.calls, ['setPreventClose(false)', 'quit']);
    });

    test('quit really quits — it is not another hide', () async {
      await controller.install(_labels);
      window.calls.clear();

      icon.select(TrayMenuAction.quit);
      await pumpEventQueue();

      expect(window.calls, contains('quit'));
      expect(window.calls, isNot(contains('hide')));
    });
  });

  group('applyLabels', () {
    test('rebuilds the menu without installing a second icon', () async {
      await controller.install(_labels);
      icon.calls.clear();

      const english = TrayMenuLabels(
        tooltip: 'LifeOS',
        showWindow: 'Open LifeOS',
        quit: 'Quit LifeOS',
      );
      await controller.applyLabels(english);

      expect(icon.calls, ['setMenu']);
      expect(icon.labels, english);
    });
  });

  group('dispose', () {
    test('removes the icon and disarms hide-to-tray', () async {
      await controller.install(_labels);
      icon.calls.clear();
      window.calls.clear();

      await controller.dispose();

      expect(icon.calls, ['destroy']);
      expect(window.preventClose, isFalse);
    });

    test('is safe to call twice', () async {
      await controller.install(_labels);
      await controller.dispose();
      icon.calls.clear();
      await controller.dispose();
      expect(icon.calls, isEmpty);
    });
  });

  test('is a TrayController, so TrayService can drive it unchanged', () {
    expect(controller, isA<TrayController>());
  });
}
