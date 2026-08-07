// Where the toggle lives. The requirement is not "the app can do it" but
// "the user can do it FROM the app", so the tile has to actually be mounted in
// the Settings hub — a control nobody can reach is not a feature.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/autostart/presentation/login_autostart_providers.dart';
import 'package:lifeos/features/autostart/presentation/login_autostart_tile.dart';
import 'package:lifeos/features/settings/presentation/settings_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'package:lifeos/theme/theme_providers.dart';

import '../../../support/fake_language_preferences.dart';
import '../../../support/fake_theme_mode_preferences.dart';
import '../../app_update/support/fakes.dart';

Widget _app({required String operatingSystem}) => ProviderScope(
      overrides: [
        hostOperatingSystemProvider.overrideWithValue(operatingSystem),
        themeModePreferencesProvider.overrideWithValue(FakeThemeModePreferences()),
        languagePreferencesProvider.overrideWithValue(FakeLanguagePreferences()),
        appVersionInfoProvider
            .overrideWithValue(FakeAppVersionInfo(code: 10, name: '1.0.0')),
        // No real mechanism is reachable in a test; the tile renders from state.
        loginAutostartPortProvider.overrideWithValue(null),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/settings',
          routes: [
            GoRoute(
              path: '/settings',
              builder: (c, s) => const SettingsHubScreen(),
            ),
          ],
        ),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1000, 3200);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('the Settings hub carries the start-at-login tile on desktop',
      (tester) async {
    await tester.pumpWidget(_app(operatingSystem: 'linux'));
    await tester.pump();

    expect(find.byType(LoginAutostartTile), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LoginAutostartTile),
        matching: find.byType(SwitchListTile),
      ),
      findsOneWidget,
    );
  });

  testWidgets('and renders nothing at all on the phone', (tester) async {
    await tester.pumpWidget(_app(operatingSystem: 'android'));
    await tester.pump();

    expect(find.byType(LoginAutostartTile), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LoginAutostartTile),
        matching: find.byType(SwitchListTile),
      ),
      findsNothing,
      reason: 'a control that is shown is a control that works',
    );
  });
}
