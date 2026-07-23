// Proves the Settings hub renders every section, the appearance selector
// changes + persists ThemeMode, and "Acerca de" shows the app version
// (app-shell slice).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/app_update/domain/app_version_info.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/settings/presentation/settings_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/language_preference.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'package:lifeos/theme/theme_mode_preferences.dart';
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
      ],
    );

Widget _app({
  ThemeModePreferences? prefs,
  AppVersionInfo? version,
  FakeLanguagePreferences? languagePrefs,
}) =>
    ProviderScope(
      overrides: [
        themeModePreferencesProvider.overrideWithValue(prefs ?? FakeThemeModePreferences()),
        languagePreferencesProvider.overrideWithValue(languagePrefs ?? FakeLanguagePreferences()),
        appVersionInfoProvider
            .overrideWithValue(version ?? FakeAppVersionInfo(code: 10, name: '1.0.0')),
      ],
      // Pin Spanish so the localized hub renders its es strings deterministically
      // (the test host's device locale would otherwise resolve to English).
      child: MaterialApp.router(
        routerConfig: _router(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );

void main() {
  // The hub is a long scrolling list; give tests a tall viewport so every
  // section is laid out (a ListView only builds visible children).
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

  testWidgets('renders all sections', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Apariencia'), findsOneWidget);
    expect(find.text('Claro'), findsOneWidget);
    expect(find.text('Oscuro'), findsOneWidget);
    // "Sistema" appears in both the appearance and language selectors.
    expect(find.text('Sistema'), findsNWidgets(2));
    // i18n slice: the Región section + language selector.
    expect(find.text('Región'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Modelo local'), findsOneWidget);
    expect(find.text('Actualizaciones'), findsOneWidget);
    expect(find.text('Notificaciones'), findsOneWidget);
    expect(find.text('Voz'), findsOneWidget);
    expect(find.text('Configuración del motor'), findsOneWidget);
    expect(find.text('Acerca de'), findsOneWidget);
    expect(find.text('LifeOS'), findsOneWidget);
  });

  testWidgets('Acerca de shows the version + build', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Subtitle is "Versión 1.0.0 (10) · <tagline>" — match the version prefix.
    expect(find.textContaining('Versión 1.0.0 (10)'), findsOneWidget);
  });

  testWidgets('appearance selector changes and persists ThemeMode', (tester) async {
    final prefs = FakeThemeModePreferences();
    await tester.pumpWidget(_app(prefs: prefs));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.text('Apariencia')));
    expect(container.read(themeModeProvider), ThemeMode.light);

    await tester.tap(find.text('Oscuro'));
    await tester.pumpAndSettle();

    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(prefs.stored, ThemeMode.dark);
  });

  testWidgets('tapping "Modelo local" navigates to the model manager', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Modelo local'));
    await tester.pumpAndSettle();

    expect(find.text('MODEL'), findsOneWidget);
  });

  testWidgets('tapping "Configuración del motor" navigates to the engine editor', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Configuración del motor'));
    await tester.pumpAndSettle();

    expect(find.text('ENGINE'), findsOneWidget);
  });

  testWidgets('Región selector changes and persists the language', (tester) async {
    final languagePrefs = FakeLanguagePreferences();
    await tester.pumpWidget(_app(languagePrefs: languagePrefs));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.text('Región')));
    expect(container.read(languageProvider), AppLanguage.system);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(container.read(languageProvider), AppLanguage.en);
    expect(languagePrefs.stored, AppLanguage.en);
  });
}
