// Proves the Settings hub renders every section, the appearance selector
// changes + persists ThemeMode, and "Acerca de" shows the app version
// (app-shell slice).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/app_update/domain/app_version_info.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/assistant/domain/assistant_gateway.dart';
import 'package:lifeos/features/assistant/presentation/assistant_providers.dart';
import 'package:lifeos/features/settings/presentation/settings_hub_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/language_preference.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'package:lifeos/theme/theme_mode_preferences.dart';
import 'package:lifeos/theme/theme_providers.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

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
        GoRoute(
            path: '/settings/danger-zone',
            builder: (c, s) => const Scaffold(body: Text('DANGER MENU'))),
      ],
    );

Widget _app({
  ThemeModePreferences? prefs,
  AppVersionInfo? version,
  FakeLanguagePreferences? languagePrefs,
  AssistantGateway? assistantGateway,
  Locale locale = const Locale('es'),
}) =>
    ProviderScope(
      overrides: [
        themeModePreferencesProvider.overrideWithValue(prefs ?? FakeThemeModePreferences()),
        languagePreferencesProvider.overrideWithValue(languagePrefs ?? FakeLanguagePreferences()),
        appVersionInfoProvider
            .overrideWithValue(version ?? FakeAppVersionInfo(code: 10, name: '1.0.0')),
        assistantGatewayProvider.overrideWithValue(assistantGateway ?? _FakeAssistantGateway()),
      ],
      // Pin Spanish so the localized hub renders its es strings deterministically
      // (the test host's device locale would otherwise resolve to English).
      child: MaterialApp.router(
        routerConfig: _router(),
        locale: locale,
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
    // i18n slice: the language section + selector (renamed "Región" → "Idioma").
    expect(find.text('Idioma'), findsOneWidget);
    // The danger zone is now a tile that pushes its own screen (not inline).
    expect(find.text('Zona de peligro'), findsOneWidget);
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

    // Version line still shows "Versión 1.0.0 (10)".
    expect(find.textContaining('Versión 1.0.0 (10)'), findsOneWidget);
  });

  testWidgets('Acerca de shows the landing slogan, author credit and a link', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Tu vida, tu máquina, no su nube.'), findsOneWidget);
    expect(find.text('Creado por Héctor Martínez'), findsOneWidget);
    expect(find.text('lifeos.hectormr.com'), findsOneWidget);
  });

  testWidgets('tapping the landing link opens lifeos.hectormr.com externally', (tester) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('lifeos.hectormr.com'));
    await tester.pumpAndSettle();

    expect(launcher.launched, ['https://lifeos.hectormr.com']);
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

  testWidgets('tapping "Voz" pushes the voice settings screen', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Voz'));
    await tester.pumpAndSettle();

    expect(find.text('VOICE'), findsOneWidget);
  });

  testWidgets('tapping "Configuración del motor" navigates to the engine editor', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Configuración del motor'));
    await tester.pumpAndSettle();

    expect(find.text('ENGINE'), findsOneWidget);
  });

  testWidgets('tapping "Zona de peligro" pushes the danger-zone MENU', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zona de peligro'));
    await tester.pumpAndSettle();

    expect(find.text('DANGER MENU'), findsOneWidget);
  });

  testWidgets('Idioma selector changes and persists the language', (tester) async {
    final languagePrefs = FakeLanguagePreferences();
    await tester.pumpWidget(_app(languagePrefs: languagePrefs));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.text('Idioma')));
    expect(container.read(languageProvider), AppLanguage.system);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(container.read(languageProvider), AppLanguage.en);
    expect(languagePrefs.stored, AppLanguage.en);
  });

  testWidgets('opens Android default assistant settings from the localized affordance', (tester) async {
    final assistantGateway = _FakeAssistantGateway(openSettingsResult: true);
    await tester.pumpWidget(_app(assistantGateway: assistantGateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Asistente predeterminado'));
    await tester.pumpAndSettle();

    expect(assistantGateway.openSettingsCalls, 1);
    expect(find.text('No se pudo abrir la configuración del asistente.'), findsNothing);
  });

  testWidgets('reports default assistant settings failures without leaving Settings', (tester) async {
    final assistantGateway = _FakeAssistantGateway(openSettingsResult: false);
    await tester.pumpWidget(_app(assistantGateway: assistantGateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Asistente predeterminado'));
    await tester.pumpAndSettle();

    expect(assistantGateway.openSettingsCalls, 1);
    expect(find.text('No se pudo abrir la configuración del asistente.'), findsOneWidget);
    expect(find.text('Ajustes'), findsOneWidget);
  });

  testWidgets('contains platform errors from default assistant settings', (tester) async {
    final assistantGateway = _FakeAssistantGateway(throwsOnOpen: true);
    await tester.pumpWidget(_app(assistantGateway: assistantGateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Asistente predeterminado'));
    await tester.pumpAndSettle();

    expect(assistantGateway.openSettingsCalls, 1);
    expect(find.text('No se pudo abrir la configuración del asistente.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the English default assistant copy', (tester) async {
    await tester.pumpWidget(_app(locale: const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('Default assistant'), findsOneWidget);
    expect(find.text('Choose LifeOS as your Android assistant.'), findsOneWidget);
  });

  testWidgets('does not show the default assistant affordance on non-Android platforms', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Asistente predeterminado'), findsNothing);
  });
}

class _FakeAssistantGateway implements AssistantGateway {
  _FakeAssistantGateway({this.openSettingsResult = true, this.throwsOnOpen = false});

  final bool openSettingsResult;
  final bool throwsOnOpen;
  int openSettingsCalls = 0;

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> openAssistantSettings() async {
    openSettingsCalls++;
    if (throwsOnOpen) throw StateError('unavailable');
    return openSettingsResult;
  }

  @override
  Future<void> start(void Function(AssistantActivation activation) onActivation) async {}
}

/// Records launched URLs so the "Acerca de" link can be verified without a
/// platform channel (no real browser).
class _FakeUrlLauncher extends Fake with MockPlatformInterfaceMixin implements UrlLauncherPlatform {
  final List<String> launched = [];

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> supportsCloseForMode(PreferredLaunchMode mode) async => false;
}
