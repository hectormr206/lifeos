// Widget test for the model-manager screen. It is now JUST the unified
// required-models manager plus the brain-model OTA "hay un nuevo modelo
// disponible" banner. The legacy single-brain controls — the "Usar modelo
// local" toggle, the "Modelo instalado" status line, the "Descargar modelo"
// button, the notification-permission notice, "Ir al chat", and "Eliminar
// modelo" — were removed now that LifeOS is on-device-first (local mode always
// on) and the manager covers install/progress/retry. Fakes the engine + OTA
// gateways so nothing real is downloaded.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/embedding/embedding_providers.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/local_model_screen.dart';
import 'package:lifeos/features/local_model/presentation/required_models_manager.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../embedding/embed_model_warmup_test.dart' show FakeEmbedModelGateway;
import '../../stt/support/fake_stt.dart';
import '../../tts/support/fake_tts.dart';
import '../support/fake_brain_model_ota.dart';
import '../support/fake_local_llm_engine.dart';
import 'local_model_backend_notifier_test.dart' show FakeLocalModelBackendPreference;

Future<void> _pump(
  WidgetTester tester, {
  required bool installed,
  FakeLocalLlmEngine? engine,
  FakeBrainModelUpdateGateway? brainGateway,
  FakeBrainModelVersionStore? versionStore,
  FakeLocalModelBackendPreference? backendPreference,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const LocalModelScreen()),
      GoRoute(path: '/chat', builder: (context, state) => const Scaffold(body: Text('CHAT'))),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localLlmEngineProvider.overrideWithValue(engine ?? FakeLocalLlmEngine(installed: installed)),
        // In-memory OTA fakes: the real gateway/store would hit
        // path_provider / shared_preferences platform channels in a widget
        // test (unconfigured by default) and hang pumpAndSettle.
        brainModelUpdateGatewayProvider
            .overrideWithValue(brainGateway ?? FakeBrainModelUpdateGateway(configured: false)),
        brainModelVersionStoreProvider
            .overrideWithValue(versionStore ?? FakeBrainModelVersionStore()),
        // download() requests the notification permission first — fake it so no
        // real permission_handler channel is touched.
        notificationPermissionGatewayProvider.overrideWithValue(FakeNotificationPermissionGateway()),
        // The unified model manager on this screen composes the STT/TTS/embed
        // download providers — fake their gateways so no real background
        // downloader / path_provider channel is touched.
        sttModelGatewayProvider.overrideWithValue(FakeSttModelGateway(installed: null)),
        ttsVoiceGatewayProvider.overrideWithValue(FakeTtsVoiceGateway()),
        appLanguageCodeProvider.overrideWithValue('es'),
        embedModelGatewayProvider.overrideWithValue(FakeEmbedModelGateway(installed: null)),
        // The forced-backend developer control persists through
        // shared_preferences — fake it so no platform channel is touched.
        localModelBackendPreferenceProvider
            .overrideWithValue(backendPreference ?? FakeLocalModelBackendPreference()),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // The screen is a scrolling ListView led by the unified model manager; give
  // tests a tall viewport so every section below the fold is laid out.
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

  testWidgets('renders the unified required-models manager', (tester) async {
    await _pump(tester, installed: false);
    expect(find.byType(RequiredModelsManager), findsOneWidget);
  });

  testWidgets('no longer shows the removed legacy single-brain controls', (tester) async {
    // Installed: the legacy screen would have shown the status line, the "Ir al
    // chat" button and the "Eliminar modelo" button here. None must remain.
    await _pump(tester, installed: true);

    expect(find.text('Usar modelo local'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('Modelo instalado'), findsNothing);
    expect(find.text('Modelo no descargado'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Ir al chat'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Eliminar modelo'), findsNothing);
  });

  testWidgets('shows the "nuevo modelo disponible" banner when the manifest is newer', (tester) async {
    await _pump(
      tester,
      installed: true,
      brainGateway: FakeBrainModelUpdateGateway(
        manifest: brainManifest(versionCode: 2, notes: 'Recipe re-tuned'),
      ),
      versionStore: FakeBrainModelVersionStore(),
    );

    expect(find.text('Hay un nuevo modelo disponible'), findsOneWidget);
    expect(find.text('Recipe re-tuned'), findsOneWidget);
    expect(find.textContaining('Actualizar modelo'), findsOneWidget);
  });

  testWidgets('no update banner when the installed model is current', (tester) async {
    await _pump(
      tester,
      installed: true,
      brainGateway: FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 1)),
      versionStore: FakeBrainModelVersionStore(),
    );

    expect(find.text('Hay un nuevo modelo disponible'), findsNothing);
  });

  testWidgets('tapping "Actualizar modelo" runs the update through the gateway', (tester) async {
    final engine = FakeLocalLlmEngine(installed: true);
    final brainGateway = FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 2));
    final versionStore = FakeBrainModelVersionStore();
    await _pump(
      tester,
      installed: true,
      engine: engine,
      brainGateway: brainGateway,
      versionStore: versionStore,
    );
    expect(find.text('Hay un nuevo modelo disponible'), findsOneWidget);

    await tester.tap(find.textContaining('Actualizar modelo'));
    await tester.pumpAndSettle();

    expect(brainGateway.downloadCount, 1);
    expect(engine.installedFromFilePaths, hasLength(1));
    expect(versionStore.value?.versionCode, 2);
    expect(find.text('Hay un nuevo modelo disponible'), findsNothing);
  });

  // ── Forced backend (developer / benchmark affordance) ────────────────────
  testWidgets('picking CPU persists the choice and releases the loaded model',
      (tester) async {
    final engine = FakeLocalLlmEngine(installed: true);
    final prefs = FakeLocalModelBackendPreference();
    await _pump(tester, installed: true, engine: engine, backendPreference: prefs);
    await engine.load();

    expect(find.text('Backend de inferencia'), findsOneWidget);
    await tester.tap(find.text('CPU'));
    await tester.pumpAndSettle();

    expect(prefs.stored, LocalLlmBackend.cpu);
    expect(engine.disposeCount, 1);
  });

  testWidgets('a stored forced backend comes back selected', (tester) async {
    await _pump(
      tester,
      installed: true,
      backendPreference: FakeLocalModelBackendPreference(LocalLlmBackend.cpu),
    );

    final segmented = tester.widget<SegmentedButton<LocalLlmBackend?>>(
      find.byType(SegmentedButton<LocalLlmBackend?>),
    );
    expect(segmented.selected, {LocalLlmBackend.cpu});
  });
}
