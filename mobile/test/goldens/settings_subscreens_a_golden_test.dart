// Settings sub-screens, batch A (local model, dictation, updates, permissions,
// timezone, web search, voice). Every screen is pumped against fakes: no
// platform channel, no network, no download. The voice catalog keeps its own
// golden (voice_catalog_screen_golden_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/core/timezone/device_timezone.dart';
import 'package:lifeos/core/timezone/timezone_preference.dart';
import 'package:lifeos/core/timezone/timezone_providers.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/app_update/presentation/app_updates_screen.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/dictation/data/dictation_channel.dart';
import 'package:lifeos/features/dictation/presentation/dictation_hotkey_tile.dart';
import 'package:lifeos/features/dictation/presentation/dictation_providers.dart';
import 'package:lifeos/features/dictation/presentation/dictation_setup_screen.dart';
import 'package:lifeos/features/embedding/embedding_providers.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/local_model_screen.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';
import 'package:lifeos/features/permissions/domain/permissions_gateway.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';
import 'package:lifeos/features/permissions/presentation/permissions_screen.dart';
import 'package:lifeos/features/settings/presentation/timezone_settings_screen.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/domain/stt_model_gateway.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_settings_screen.dart';
import 'package:lifeos/features/web_search/domain/web_search_settings.dart';
import 'package:lifeos/features/web_search/presentation/web_search_providers.dart';
import 'package:lifeos/features/web_search/presentation/web_search_settings_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/language_preference.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'package:lifeos/theme/lifeos_tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/app_update/support/fakes.dart';
import '../features/chat/support/fake_chat_gateways.dart'
    show FakeVoiceReplyPreferences;
import '../features/embedding/embed_model_warmup_test.dart' show FakeEmbedModelGateway;
import '../features/local_model/presentation/local_model_backend_notifier_test.dart'
    show FakeLocalModelBackendPreference;
import '../features/local_model/presentation/local_model_speculative_decoding_notifier_test.dart'
    show FakeSpeculativeDecodingPreference;
import '../features/local_model/support/fake_brain_model_ota.dart';
import '../features/local_model/support/fake_local_llm_engine.dart';
import '../features/stt/support/fake_stt.dart';
import '../features/tts/support/fake_tts.dart' hide FakeTextToSpeechGateway;
import '../features/tts/support/fake_tts.dart' as tts_fakes show FakeTextToSpeechGateway;
import '../support/fake_language_preferences.dart';
import 'support/golden_harness.dart';

class _DictationChannel extends DictationChannel {
  @override
  Future<bool> isImeEnabled() async => true;
  @override
  Future<bool> isImeSelected() async => false;
}

class _SttGateway implements SttModelGateway {
  @override
  Future<SttModelPaths?> installedModel() async => null;
  @override
  Future<SttModelPaths> download({void Function(double progress)? onProgress}) async =>
      const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't');
}

class _PermissionsGateway implements PermissionsGateway {
  static const _states = {
    AppPermission.notifications: PermissionState.granted,
    AppPermission.microphone: PermissionState.denied,
    AppPermission.camera: PermissionState.permanentlyDenied,
  };
  @override
  Future<PermissionState> status(AppPermission permission) async =>
      _states[permission] ?? PermissionState.granted;
  @override
  Future<PermissionState> request(AppPermission permission) async => PermissionState.granted;
  @override
  Future<bool> openSettings() async => true;
}

class _TimezonePrefs implements TimezonePreferences {
  TimezonePreference pref = const TimezonePreference.override('America/Mexico_City');
  @override
  Future<TimezonePreference> load() async => pref;
  @override
  Future<void> save(TimezonePreference preference) async => pref = preference;
}

class _TimezoneDetector implements DeviceTimezoneDetector {
  @override
  Future<String?> currentZoneId() async => 'America/Mexico_City';
}

class _WebPrefs implements WebSearchPreferences {
  WebSearchSettings settings = const WebSearchSettings(
    provider: WebSearchProvider.searxng,
    searxngBaseUrl: 'https://searx.example.com',
  );
  @override
  Future<WebSearchSettings> load() async => settings;
  @override
  Future<void> save(WebSearchSettings s) async => settings = s;
}

class _NoFetcher implements SourceFetcher {
  @override
  Future<String> fetch(String url, {Map<String, String>? headers}) async => '{}';
}

const _manifest = AppManifest(
  versionCode: 12,
  versionName: '1.4.0',
  apkFilename: 'lifeos-1.4.0-12.apk',
  sha256: 'abc',
  sizeBytes: 150000000,
  notes: 'Mejoras de rendimiento',
  publishedAt: '2026-07-20T00:00:00+00:00',
);

Widget _app(Widget screen, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        theme: goldenTheme(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child ?? const SizedBox.shrink(),
        ),
        routerConfig: GoRouter(routes: [
          GoRoute(path: '/', builder: (context, state) => screen),
        ]),
      ),
    );

final _localModel = <Override>[
  localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: false)),
  brainModelUpdateGatewayProvider
      .overrideWithValue(FakeBrainModelUpdateGateway(configured: false)),
  brainModelVersionStoreProvider.overrideWithValue(FakeBrainModelVersionStore()),
  notificationPermissionGatewayProvider.overrideWithValue(FakeNotificationPermissionGateway()),
  sttModelGatewayProvider.overrideWithValue(FakeSttModelGateway(installed: null)),
  ttsVoiceGatewayProvider.overrideWithValue(FakeTtsVoiceGateway()),
  appLanguageCodeProvider.overrideWithValue('es'),
  embedModelGatewayProvider.overrideWithValue(FakeEmbedModelGateway(installed: null)),
  localModelBackendPreferenceProvider.overrideWithValue(FakeLocalModelBackendPreference()),
  localModelSpeculativeDecodingPreferenceProvider
      .overrideWithValue(FakeSpeculativeDecodingPreference()),
];

final _dictation = <Override>[
  dictationChannelProvider.overrideWithValue(_DictationChannel()),
  sttModelGatewayProvider.overrideWithValue(_SttGateway()),
];

final _updates = <Override>[
  hostOperatingSystemProvider.overrideWithValue('android'),
  appUpdateInitialStatusProvider.overrideWithValue(const UpdateAvailable(manifest: _manifest)),
  appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo(code: 10, name: '1.0.0')),
  appUpdatePreferencesProvider.overrideWithValue(FakeAppUpdatePreferences()),
  updateNotificationsProvider.overrideWithValue(FakeUpdateNotifications()),
];

final _permissions = <Override>[
  hostOperatingSystemProvider.overrideWithValue('android'),
  permissionsGatewayProvider.overrideWithValue(_PermissionsGateway()),
];

final _timezone = <Override>[
  timezonePreferencesProvider.overrideWithValue(_TimezonePrefs()),
  deviceTimezoneDetectorProvider.overrideWithValue(_TimezoneDetector()),
];

final _webSearch = <Override>[
  webSearchPreferencesProvider.overrideWithValue(_WebPrefs()),
  webSearchFetcherProvider.overrideWithValue(_NoFetcher()),
];

List<Override> _voice(String os) => <Override>[
  hostOperatingSystemProvider.overrideWithValue(os),
  textToSpeechGatewayProvider.overrideWithValue(tts_fakes.FakeTextToSpeechGateway()),
  voiceReplyPreferencesProvider.overrideWithValue(FakeVoiceReplyPreferences(enabled: true)),
  ttsVoiceGatewayProvider.overrideWithValue(FakeTtsVoiceGateway()),
  languagePreferencesProvider.overrideWithValue(FakeLanguagePreferences(initial: AppLanguage.es)),
];

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(
    WidgetTester tester,
    Widget screen,
    List<Override> overrides, {
    bool wide = false,
    bool tall = false,
  }) async {
    useGoldenSurface(tester);
    if (wide) tester.view.physicalSize = const Size(1280, 900) * kGoldenDpr;
    if (tall) tester.view.physicalSize = const Size(390, 1500) * kGoldenDpr;
    await tester.pumpWidget(_app(screen, overrides));
    await _settle(tester);
  }

  double contentWidth(WidgetTester tester) =>
      tester.getSize(find.byType(GroupedList).first).width;

  testWidgets('local model: engine options sit in a group, content stays in the column',
      (tester) async {
    await pump(tester, const LocalModelScreen(), _localModel, wide: true);
    expect(find.widgetWithText(SectionHeader, 'Backend de inferencia'), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Decodificación especulativa'), findsOneWidget);
    expect(find.ancestor(of: find.byType(SegmentedButton<bool?>), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(contentWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('dictation: steps sit in groups, no Card, no hardcoded colors', (tester) async {
    await pump(tester, const DictationSetupScreen(), _dictation, wide: true);
    expect(find.byType(Card), findsNothing);
    expect(find.ancestor(of: find.text('Abrir ajustes de teclado'), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(find.ancestor(of: find.text('Descargar modelo de voz'), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(contentWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('updates: version rows and preferences sit in named groups', (tester) async {
    await pump(tester, const AppUpdatesScreen(), _updates, wide: true);
    expect(find.widgetWithText(SectionHeader, 'Preferencias'), findsOneWidget);
    expect(find.ancestor(of: find.byType(SwitchListTile).first, matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(find.ancestor(of: find.text('Versión instalada'), matching: find.byType(GroupedList)),
        findsOneWidget);
    for (final divider in tester.widgetList<Divider>(find.byType(Divider))) {
      expect(find.ancestor(of: find.byWidget(divider), matching: find.byType(GroupedList)),
          findsOneWidget);
    }
    expect(contentWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('permissions: every permission row is in one group', (tester) async {
    await pump(tester, const PermissionsScreen(), _permissions, wide: true);
    expect(find.byType(GroupedList), findsOneWidget);
    expect(find.descendant(of: find.byType(GroupedList), matching: find.byType(ListTile)),
        findsNWidgets(permissionsForPlatform('android').length));
    expect(contentWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('timezone: switch and zone list are inside grouped surfaces', (tester) async {
    await pump(tester, const TimezoneSettingsScreen(), _timezone, wide: true);
    expect(find.ancestor(of: find.byType(SwitchListTile), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(tester.getSize(find.byType(SwitchListTile)).width, lessThanOrEqualTo(kContentMaxWidth));
    expect(tester.getSize(find.byType(TextField)).width, lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('web search: provider options are one group; searxng config stays with it',
      (tester) async {
    await pump(tester, const WebSearchSettingsScreen(), _webSearch, wide: true);
    expect(find.ancestor(of: find.byType(RadioListTile<WebSearchProvider>).first,
        matching: find.byType(GroupedList)), findsOneWidget);
    expect(find.descendant(of: find.byType(GroupedList),
        matching: find.byType(RadioListTile<WebSearchProvider>)), findsNWidgets(3));
    expect(contentWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  testWidgets('voice: switch, status and catalog link are grouped; rate has a header',
      (tester) async {
    await pump(tester, const VoiceSettingsScreen(), _voice('linux'), wide: true);
    expect(find.ancestor(of: find.byType(SwitchListTile), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(find.ancestor(of: find.text('Elegir voz'), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(find.ancestor(of: find.byType(DictationHotkeyTile), matching: find.byType(GroupedList)),
        findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(contentWidth(tester), lessThanOrEqualTo(kContentMaxWidth));
  });

  for (final (name, screen, overrides) in [
    ('settings_a_local_model.png', const LocalModelScreen(), _localModel),
    ('settings_a_dictation.png', const DictationSetupScreen(), _dictation),
    ('settings_a_updates.png', const AppUpdatesScreen(), _updates),
    ('settings_a_permissions.png', const PermissionsScreen(), _permissions),
    ('settings_a_timezone.png', const TimezoneSettingsScreen(), _timezone),
    ('settings_a_web_search.png', const WebSearchSettingsScreen(), _webSearch),
    ('settings_a_voice.png', const VoiceSettingsScreen(), _voice('android')),
  ]) {
    testWidgets('golden: $name', (tester) async {
      await pump(tester, screen, overrides, tall: name == 'settings_a_local_model.png');
      await expectLater(find.byWidget(screen), matchesGoldenFile('images/$name'));
    });
  }
}
