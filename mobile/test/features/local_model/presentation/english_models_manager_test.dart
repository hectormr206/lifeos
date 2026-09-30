import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/embedding/embedding_providers.dart';
import 'package:lifeos/features/english/data/pron_model.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/local_model_screen.dart';
import 'package:lifeos/features/local_model/presentation/required_models.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/features/voice_settings/domain/voice_catalog.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_catalog_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../embedding/embed_model_warmup_test.dart'
    show FakeEmbedModelGateway;
import '../../stt/support/fake_stt.dart';
import '../../tts/support/fake_tts.dart';
import '../../voice_settings/presentation/voice_catalog_providers_test.dart'
    show FakeSelectedVoicePreferences;
import '../support/fake_brain_model_ota.dart';
import '../support/fake_local_llm_engine.dart';
import 'local_model_backend_notifier_test.dart'
    show FakeLocalModelBackendPreference;
import 'local_model_speculative_decoding_notifier_test.dart'
    show FakeSpeculativeDecodingPreference;

class _PronGateway implements PronModelGateway {
  _PronGateway({this.installed = false, this.error = false});

  bool installed;
  bool error;
  int downloads = 0;
  Completer<void>? gate;
  Completer<void>? probeGate;
  void Function(double)? progress;

  static const paths = PronModelPaths(
    model: 'zipa.onnx',
    tokens: 'zipa.tokens',
  );

  @override
  Future<PronModelPaths?> installedModel() async {
    if (probeGate case final pending?) await pending.future;
    return installed ? paths : null;
  }

  @override
  Future<PronModelPaths> download({void Function(double)? onProgress}) async {
    downloads++;
    progress = onProgress;
    if (error) throw StateError('offline');
    if (gate case final pending?) await pending.future;
    installed = true;
    return paths;
  }
}

class _VoiceGateway extends FakeTtsVoiceGateway {
  _VoiceGateway({super.installed});

  bool fail = false;
  Completer<void>? probeGate;

  @override
  Future<TtsVoicePaths?> installedVoice(String voiceId) async {
    if (voiceId == kPracticeVoiceId) {
      final pending = probeGate;
      if (pending != null) await pending.future;
    }
    return super.installedVoice(voiceId);
  }

  @override
  Future<TtsVoicePaths> download(
    String voiceId, {
    void Function(double)? onProgress,
  }) {
    if (fail) {
      downloadCalls.add(voiceId);
      throw StateError('offline');
    }
    return super.download(voiceId, onProgress: onProgress);
  }
}

Finder _row(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(ListTile)).first;

Finder _action(String name) =>
    find.descendant(of: _row(name), matching: find.byType(TextButton));

Finder _rowStatus(String name, String status) =>
    find.descendant(of: _row(name), matching: find.text(status));

Future<ProviderContainer> _show(
  WidgetTester tester, {
  required _PronGateway pron,
  required FakeTtsVoiceGateway voice,
  required FakeSelectedVoicePreferences preferences,
  Locale locale = const Locale('en'),
}) async {
  final container = ProviderContainer(
    overrides: [
      localLlmEngineProvider.overrideWithValue(
        FakeLocalLlmEngine(installed: true),
      ),
      brainModelUpdateGatewayProvider.overrideWithValue(
        FakeBrainModelUpdateGateway(configured: false),
      ),
      brainModelVersionStoreProvider.overrideWithValue(
        FakeBrainModelVersionStore(),
      ),
      notificationPermissionGatewayProvider.overrideWithValue(
        FakeNotificationPermissionGateway(),
      ),
      sttModelGatewayProvider.overrideWithValue(
        FakeSttModelGateway(installed: null),
      ),
      ttsVoiceGatewayProvider.overrideWithValue(voice),
      selectedVoicePreferencesProvider.overrideWithValue(preferences),
      embedModelGatewayProvider.overrideWithValue(
        FakeEmbedModelGateway(installed: null),
      ),
      pronModelGatewayProvider.overrideWithValue(pron),
      localModelBackendPreferenceProvider.overrideWithValue(
        FakeLocalModelBackendPreference(),
      ),
      localModelSpeculativeDecodingPreferenceProvider.overrideWithValue(
        FakeSpeculativeDecodingPreference(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LocalModelScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1000, 3200);
    view.devicePixelRatio = 1;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets(
    'Local Model displays both optional resources without downloading on entry',
    (tester) async {
      final pron = _PronGateway();
      final voice = FakeTtsVoiceGateway();
      await _show(
        tester,
        pron: pron,
        voice: voice,
        preferences: FakeSelectedVoicePreferences(),
      );
      expect(find.text('English resources (optional)'), findsOneWidget);
      expect(find.textContaining('ZIPA'), findsOneWidget);
      expect(find.textContaining('Lessac'), findsOneWidget);
      expect(pron.downloads, 0);
      expect(voice.downloadCalls, isEmpty);
      expect(_action('ZIPA pronunciation'), findsOneWidget);
      expect(_action('Lessac (US) practice voice'), findsOneWidget);
    },
  );

  testWidgets(
    'Spanish labels, installed Lessac and ZIPA are ready without selecting or downloading',
    (tester) async {
      final pron = _PronGateway(installed: true);
      final voice = _VoiceGateway(
        installed: {
          kPracticeVoiceId: const TtsVoicePaths(
            model: 'lessac.onnx',
            tokens: 'tokens',
            dataDir: 'espeak',
          ),
        },
      );
      final prefs = FakeSelectedVoicePreferences(
        initial: VoiceCatalog.systemVoiceId,
      );
      final container = await _show(
        tester,
        pron: pron,
        voice: voice,
        preferences: prefs,
        locale: const Locale('es'),
      );
      expect(find.text('Recursos de inglés (opcionales)'), findsOneWidget);
      expect(find.text('Pronunciación ZIPA'), findsOneWidget);
      expect(find.text('Voz Lessac (EE. UU.) para practicar'), findsOneWidget);
      expect(_rowStatus('Pronunciación ZIPA', 'Instalado'), findsOneWidget);
      expect(
        _rowStatus('Voz Lessac (EE. UU.) para practicar', 'Instalado'),
        findsOneWidget,
      );
      expect(_action('Pronunciación ZIPA'), findsNothing);
      expect(_action('Voz Lessac (EE. UU.) para practicar'), findsNothing);
      expect(pron.downloads, 0);
      expect(voice.downloadCalls, isEmpty);
      expect(container.read(selectedVoiceProvider), VoiceCatalog.systemVoiceId);
      expect(prefs.writes, 0);
    },
  );

  testWidgets('checks disk before offering downloads', (tester) async {
    final pron = _PronGateway()..probeGate = Completer<void>();
    final voice = _VoiceGateway()..probeGate = Completer<void>();
    await _show(
      tester,
      pron: pron,
      voice: voice,
      preferences: FakeSelectedVoicePreferences(),
    );
    expect(find.text('Checking on this device…'), findsNWidgets(2));
    expect(_action('ZIPA pronunciation'), findsNothing);
    expect(_action('Lessac (US) practice voice'), findsNothing);
    pron.probeGate!.complete();
    voice.probeGate!.complete();
    await tester.pumpAndSettle();
    expect(_action('ZIPA pronunciation'), findsOneWidget);
    expect(_action('Lessac (US) practice voice'), findsOneWidget);
  });

  testWidgets(
    'independent progress, single-flight and shared state after remount',
    (tester) async {
      final pron = _PronGateway()..gate = Completer<void>();
      final voice = _VoiceGateway()..downloadGate = Completer<void>();
      final prefs = FakeSelectedVoicePreferences(
        initial: VoiceCatalog.systemVoiceId,
      );
      final container = await _show(
        tester,
        pron: pron,
        voice: voice,
        preferences: prefs,
      );
      final requiredBefore = container
          .read(requiredModelsSummaryProvider)
          .models
          .map((m) => m.phase)
          .toList();
      expect(container.read(lifeOsModelsReadyProvider), isFalse);

      await tester.tap(_action('ZIPA pronunciation'));
      await tester.pump();
      pron.progress!(0.4);
      await tester.pump();
      expect(find.text('Downloading 40%'), findsOneWidget);
      expect(_action('ZIPA pronunciation'), findsNothing);
      expect(_action('Lessac (US) practice voice'), findsOneWidget);
      await tester.tap(_action('Lessac (US) practice voice'));
      await tester.pump();
      expect(voice.downloadCalls, [kPracticeVoiceId]);
      expect(_action('Lessac (US) practice voice'), findsNothing);
      expect(pron.downloads, 1);

      // Both notifiers live in the scope, not the route's widget instance.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LocalModelScreen(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Downloading 40%'), findsOneWidget);
      expect(find.text('Downloading 100%'), findsOneWidget);
      pron.gate!.complete();
      voice.downloadGate!.complete();
      await tester.pumpAndSettle();
      expect(_rowStatus('ZIPA pronunciation', 'Installed'), findsOneWidget);
      expect(
        _rowStatus('Lessac (US) practice voice', 'Installed'),
        findsOneWidget,
      );
      expect(pron.downloads, 1);
      expect(voice.downloadCalls, [kPracticeVoiceId]);
      expect(container.read(selectedVoiceProvider), VoiceCatalog.systemVoiceId);
      expect(prefs.writes, 0);
      expect(
        container
            .read(requiredModelsSummaryProvider)
            .models
            .map((m) => m.phase)
            .toList(),
        requiredBefore,
      );
      expect(container.read(requiredModelsSummaryProvider).total, 4);
      expect(container.read(lifeOsModelsReadyProvider), isFalse);
    },
  );

  // A pushed route (briefing notification, then its model link) can put Local
  // Model over a mounted Listening screen, which keeps the installed-voices
  // cache alive while it watches it.
  testWidgets('downloading Lessac refreshes a watched installed-voices cache', (
    tester,
  ) async {
    final container = await _show(
      tester,
      pron: _PronGateway(),
      voice: _VoiceGateway(),
      preferences: FakeSelectedVoicePreferences(),
    );
    final watched = container.listen(
      installedEnglishVoicesProvider,
      (_, _) {},
    );
    addTearDown(watched.close);
    expect(await container.read(installedEnglishVoicesProvider.future), isEmpty);

    await tester.tap(_action('Lessac (US) practice voice'));
    await tester.pumpAndSettle();

    expect(
      (await container.read(installedEnglishVoicesProvider.future)).keys,
      contains(kPracticeVoiceId),
    );
  });

  testWidgets('each failed download offers a retry independently', (
    tester,
  ) async {
    final pron = _PronGateway(error: true);
    final voice = _VoiceGateway()..fail = true;
    final prefs = FakeSelectedVoicePreferences();
    final container = await _show(
      tester,
      pron: pron,
      voice: voice,
      preferences: prefs,
    );
    await tester.tap(_action('ZIPA pronunciation'));
    await tester.pumpAndSettle();
    await tester.tap(_action('Lessac (US) practice voice'));
    await tester.pumpAndSettle();
    expect(find.text('Download error'), findsNWidgets(2));
    expect(find.text('Retry'), findsNWidgets(2));
    pron.error = false;
    voice.fail = false;
    await tester.tap(_action('ZIPA pronunciation'));
    await tester.pumpAndSettle();
    await tester.tap(_action('Lessac (US) practice voice'));
    await tester.pumpAndSettle();
    expect(_rowStatus('ZIPA pronunciation', 'Installed'), findsOneWidget);
    expect(
      _rowStatus('Lessac (US) practice voice', 'Installed'),
      findsOneWidget,
    );
    expect(pron.downloads, 2);
    expect(voice.downloadCalls, [kPracticeVoiceId, kPracticeVoiceId]);
    expect(container.read(selectedVoiceProvider), VoiceCatalog.defaultVoice.id);
    expect(prefs.writes, 0);
  });
}
