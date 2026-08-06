import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tray/tray_controller.dart';
import 'package:lifeos/core/tray/tray_labels.dart';
import 'package:lifeos/core/tray/tray_service.dart';
import 'package:lifeos/core/tray/tray_status.dart';

const _labels = TrayMenuLabels(
  tooltip: 'LifeOS',
  showWindow: 'Abrir LifeOS',
  quit: 'Salir de LifeOS',
);

/// Records every interaction so a test can assert not just what the tray did,
/// but that it was never even CONSTRUCTED on a platform that has no tray.
class _SpyTrayController implements TrayController {
  _SpyTrayController({this.failWith});

  final Object? failWith;
  final List<String> calls = <String>[];
  TrayMenuLabels? installedLabels;

  @override
  Future<void> install(TrayMenuLabels labels) async {
    calls.add('install');
    installedLabels = labels;
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> applyLabels(TrayMenuLabels labels) async {
    calls.add('applyLabels');
    installedLabels = labels;
  }

  @override
  Future<void> dispose() async => calls.add('dispose');
}

void main() {
  group('platform guard — mobile must be untouched', () {
    for (final os in const ['android', 'ios']) {
      test('$os never constructs a tray controller at all', () async {
        var factoryCalls = 0;
        final service = TrayService(
          operatingSystem: os,
          createController: () {
            factoryCalls++;
            return _SpyTrayController();
          },
        );

        final status = await service.start(_labels);

        // The strongest guarantee this design can give the phone: the factory
        // closure is the ONLY place `tray_manager` / `window_manager` are
        // touched, and on Android it is never invoked — no channel is opened,
        // no listener is registered, no plugin call is made. (That nothing is
        // REGISTERED natively either is asserted separately, against the
        // resolved plugin map, in tray_plugin_isolation_test.dart.)
        expect(factoryCalls, 0);
        expect(status, isA<TrayNotApplicable>());
        expect((status as TrayNotApplicable).operatingSystem, os);
      });

      test('$os stays silent — a missing tray is not an error there', () async {
        // The loud-failure rule applies to a feature that SHOULD work and
        // did not. A phone has no system tray by definition, so reporting one
        // as "unavailable" would be crying wolf on every Android launch.
        final service = TrayService(
          operatingSystem: os,
          createController: _SpyTrayController.new,
        );
        expect(await service.start(_labels), isNot(isA<TrayUnavailable>()));
      });
    }

    test('web never constructs a tray controller either', () async {
      var factoryCalls = 0;
      final service = TrayService(
        operatingSystem: 'web',
        createController: () {
          factoryCalls++;
          return _SpyTrayController();
        },
      );
      expect(await service.start(_labels), isA<TrayNotApplicable>());
      expect(factoryCalls, 0);
    });
  });

  group('desktop happy path', () {
    test('installs the tray with the given labels and reports active', () async {
      final spy = _SpyTrayController();
      final service = TrayService(
        operatingSystem: 'linux',
        createController: () => spy,
      );

      final status = await service.start(_labels);

      expect(status, isA<TrayActive>());
      expect(spy.calls, ['install']);
      expect(spy.installedLabels, _labels);
    });

    test('start is idempotent — a second call re-labels, never re-installs', () async {
      // The app re-applies labels when the user switches language. Installing
      // a second icon instead would leave TWO icons in the top bar.
      final spy = _SpyTrayController();
      final service = TrayService(operatingSystem: 'linux', createController: () => spy);

      await service.start(_labels);
      const other = TrayMenuLabels(
        tooltip: 'LifeOS',
        showWindow: 'Open LifeOS',
        quit: 'Quit LifeOS',
      );
      final status = await service.start(other);

      expect(status, isA<TrayActive>());
      expect(spy.calls, ['install', 'applyLabels']);
      expect(spy.installedLabels, other);
    });

    test('stop disposes the controller so no ghost icon is left behind', () async {
      final spy = _SpyTrayController();
      final service = TrayService(operatingSystem: 'linux', createController: () => spy);

      await service.start(_labels);
      await service.stop();

      expect(spy.calls, ['install', 'dispose']);
      expect(service.status, isA<TrayNotApplicable>());
    });

    test('stop before start is a harmless no-op', () async {
      final spy = _SpyTrayController();
      final service = TrayService(operatingSystem: 'linux', createController: () => spy);
      await service.stop();
      expect(spy.calls, isEmpty);
    });
  });

  group('HOUSE RULE — a tray that cannot start fails loudly', () {
    test('keeps the original error and reports it, never swallows it', () async {
      final cause = TrayUnavailableException(
        'No StatusNotifierHost is registered on this session bus.',
      );
      final service = TrayService(
        operatingSystem: 'linux',
        createController: () => _SpyTrayController(failWith: cause),
        reportError: (_, _) {},
      );

      final status = await service.start(_labels);

      expect(status, isA<TrayUnavailable>());
      final unavailable = status as TrayUnavailable;
      // The exact underlying object survives — a caller (or a crash report)
      // can inspect it. Degrading this to a bare bool would be the quiet
      // failure the house rule exists to prevent.
      expect(unavailable.error, same(cause));
      expect(unavailable.stackTrace, isNotNull);
      expect(unavailable.reason, contains('StatusNotifierHost'));
    });

    test('reports a NON-tray exception the same way (nothing is special-cased)', () async {
      final service = TrayService(
        operatingSystem: 'linux',
        createController: () => _SpyTrayController(
          failWith: MissingPluginException('No implementation found'),
        ),
        reportError: (_, _) {},
      );

      final status = await service.start(_labels);

      expect(status, isA<TrayUnavailable>());
      expect((status as TrayUnavailable).error, isA<MissingPluginException>());
    });

    test('the DEFAULT reporter routes to FlutterError, not to a private log', () {
      // With no reporter injected, the failure must still reach the app's
      // normal error channel. Asserted by intercepting FlutterError.onError
      // rather than by reading the class — a future refactor that quietly
      // dropped this would turn the whole feature into a silent no-op.
      final caught = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = caught.add;
      addTearDown(() => FlutterError.onError = previous);

      final service = TrayService(
        operatingSystem: 'linux',
        createController: () => _SpyTrayController(failWith: StateError('boom')),
      );

      return service.start(_labels).then((status) {
        expect(status, isA<TrayUnavailable>());
        expect(caught, hasLength(1));
        expect(caught.single.exception, isA<StateError>());
        expect(caught.single.library, 'lifeos/core/tray');
      });
    });

    test('hands the failure to the injected reporter, not to /dev/null', () async {
      final reported = <Object>[];
      final service = TrayService(
        operatingSystem: 'linux',
        createController: () => _SpyTrayController(failWith: StateError('boom')),
        reportError: (error, stack) => reported.add(error),
      );

      await service.start(_labels);

      expect(reported, hasLength(1));
      expect(reported.single, isA<StateError>());
    });

    test('a controller that cannot even be BUILT is reported, not thrown', () async {
      // The production factory resolves the icon file while constructing, and
      // raises when none exists. If that escaped `start`, it would take out
      // the post-frame callback that calls it — a missing icon would become a
      // crash instead of a notice.
      final service = TrayService(
        operatingSystem: 'linux',
        createController: () =>
            throw TrayUnavailableException.noIcon(const ['/nowhere.png']),
        reportError: (_, _) {},
      );

      final status = await service.start(_labels);

      expect(status, isA<TrayUnavailable>());
      expect((status as TrayUnavailable).reason, contains('/nowhere.png'));
    });

    test('a failed start still leaves the app usable and re-startable', () async {
      // The app must RUN without a tray. It must also be able to try again —
      // the user may have started their tray host after LifeOS.
      var attempt = 0;
      final good = _SpyTrayController();
      final service = TrayService(
        operatingSystem: 'linux',
        createController: () {
          attempt++;
          return attempt == 1 ? _SpyTrayController(failWith: StateError('no host')) : good;
        },
        reportError: (_, _) {},
      );

      expect(await service.start(_labels), isA<TrayUnavailable>());
      expect(await service.start(_labels), isA<TrayActive>());
      expect(good.calls, ['install']);
    });
  });
}
