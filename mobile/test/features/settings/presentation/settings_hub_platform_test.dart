// Proves the Settings hub is PLATFORM-HONEST: rows for capabilities the host
// does not have are ABSENT, not greyed out and not reworded.
//
// Both directions are asserted for every row, because "hidden on Linux" is only
// half the contract — the other half is that Android, which carries the user's
// real data on his Pixel, still shows exactly what it showed before.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/settings/presentation/settings_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'package:lifeos/theme/theme_providers.dart';

import '../../../support/fake_language_preferences.dart';
import '../../../support/fake_theme_mode_preferences.dart';
import '../../app_update/support/fakes.dart';

GoRouter _router() => GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/settings', builder: (c, s) => const SettingsHubScreen()),
        GoRoute(path: '/settings/local-model', builder: (c, s) => const Scaffold(body: Text('MODEL'))),
        GoRoute(path: '/settings/updates', builder: (c, s) => const Scaffold(body: Text('UPDATES'))),
        GoRoute(path: '/settings/engine', builder: (c, s) => const Scaffold(body: Text('ENGINE'))),
        GoRoute(path: '/settings/voice', builder: (c, s) => const Scaffold(body: Text('VOICE'))),
        GoRoute(path: '/settings/permissions', builder: (c, s) => const Scaffold(body: Text('PERMS'))),
        GoRoute(path: '/settings/graph', builder: (c, s) => const Scaffold(body: Text('GRAPH'))),
        GoRoute(path: '/settings/backups', builder: (c, s) => const Scaffold(body: Text('BACKUPS'))),
        GoRoute(path: '/settings/briefing', builder: (c, s) => const Scaffold(body: Text('BRIEF'))),
        GoRoute(path: '/settings/web-search', builder: (c, s) => const Scaffold(body: Text('WEB'))),
        GoRoute(path: '/settings/timezone', builder: (c, s) => const Scaffold(body: Text('TZ'))),
        GoRoute(path: '/settings/danger-zone', builder: (c, s) => const Scaffold(body: Text('DANGER MENU'))),
      ],
    );

Widget _app({required String operatingSystem}) => ProviderScope(
      overrides: [
        hostOperatingSystemProvider.overrideWithValue(operatingSystem),
        themeModePreferencesProvider.overrideWithValue(FakeThemeModePreferences()),
        languagePreferencesProvider.overrideWithValue(FakeLanguagePreferences()),
        appVersionInfoProvider
            .overrideWithValue(FakeAppVersionInfo(code: 10, name: '1.0.0')),
      ],
      child: MaterialApp.router(
        routerConfig: _router(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.physicalSize = const Size(1000, 3200);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  group('Asistente digital (Android ACTION_ASSIST role)', () {
    testWidgets('is shown on Android — the Pixel build must not lose it',
        (tester) async {
      await tester.pumpWidget(_app(operatingSystem: 'android'));
      await tester.pumpAndSettle();

      expect(find.text('Asistente digital'), findsOneWidget);
    });

    testWidgets('is ABSENT on Linux — there is no default-assistant concept',
        (tester) async {
      await tester.pumpWidget(_app(operatingSystem: 'linux'));
      await tester.pumpAndSettle();

      // Absent, not merely disabled: no row, and no leftover subtitle either.
      expect(find.text('Asistente digital'), findsNothing);
      expect(find.textContaining('asistente predeterminado'), findsNothing);
    });
  });

  group('Permisos (runtime permission prompts)', () {
    testWidgets('is shown on Android', (tester) async {
      await tester.pumpWidget(_app(operatingSystem: 'android'));
      await tester.pumpAndSettle();

      expect(find.text('Permisos'), findsOneWidget);
    });

    testWidgets(
        'is ABSENT on Linux — permission_handler has no Linux implementation, '
        'so every row there would read "No disponible"', (tester) async {
      await tester.pumpWidget(_app(operatingSystem: 'linux'));
      await tester.pumpAndSettle();

      expect(find.text('Permisos'), findsNothing);
    });
  });

  group('rows that are true on every platform stay put', () {
    // Guards against over-hiding: the point is honesty, not a smaller desktop
    // app. These capabilities genuinely exist on both, so both must show them.
    for (final os in ['android', 'linux']) {
      testWidgets('$os keeps the device-neutral rows', (tester) async {
        await tester.pumpWidget(_app(operatingSystem: os));
        await tester.pumpAndSettle();

        expect(find.text('Modelo local'), findsOneWidget);
        expect(find.text('Actualizaciones'), findsOneWidget);
        // The duplicate "Notificaciones" row is gone on EVERY platform — it
        // pushed the identical route as "Actualizaciones". Pinned here too so
        // a platform-conditional edit cannot quietly bring it back on one.
        expect(find.text('Notificaciones'), findsNothing);
        expect(find.text('Voz'), findsOneWidget);
        // "Configuración del motor" is NOT device-neutral — it edits the remote
        // engine's config, so it is a window onto the other machine and is gone
        // on every platform. Pinned as a negative here, next to the positives,
        // so a platform-conditional edit cannot bring it back on just one.
        expect(find.text('Configuración del motor'), findsNothing);
        expect(find.text('Zona de peligro'), findsOneWidget);
        expect(find.text('Acerca de'), findsOneWidget);
      });
    }
  });
}
