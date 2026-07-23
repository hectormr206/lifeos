// Proves the unified "required models" layer (option B all-models-ready gate):
//   * lifeOsModelsReadyProvider is true ONLY when all four models are installed;
//   * "Descargar todo" downloads the MISSING models and skips installed ones —
//     the already-installed brain is NEVER re-downloaded.
// Everything is faked (no downloader, no filesystem, no graph DB).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/embedding/domain/embed_model.dart';
import 'package:lifeos/features/embedding/domain/rag_service.dart';
import 'package:lifeos/features/embedding/embedding_providers.dart';
import 'package:lifeos/features/embedding/data/embed_model_source_config.dart';
import 'package:lifeos/features/local_model/presentation/local_model_notifier.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/required_models.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../embedding/embed_model_warmup_test.dart' show FakeEmbedModelGateway;
import '../../stt/support/fake_stt.dart';
import '../../tts/support/fake_tts.dart';
import '../support/fake_brain_model_ota.dart';
import '../support/fake_local_llm_engine.dart';

const _sttPaths = SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't');
const _ttsVoice = TtsVoicePaths(model: 'm', tokens: 't', dataDir: 'd');
const _embedPaths = EmbedModelPaths(model: '/m.tflite', tokenizer: '/t.model');

/// Builds a container wired with in-memory fakes for all four models.
ProviderContainer _container({
  required bool brainInstalled,
  SttModelPaths? sttInstalled,
  Map<String, TtsVoicePaths>? ttsInstalled,
  EmbedModelPaths? embedInstalled,
  FakeSttModelGateway? sttGateway,
  FakeTtsVoiceGateway? ttsGateway,
  FakeEmbedModelGateway? embedGateway,
  FakeBrainModelUpdateGateway? brainGateway,
  bool embedConfigured = false,
}) {
  final container = ProviderContainer(
    overrides: [
      // Brain
      localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: brainInstalled)),
      brainModelUpdateGatewayProvider
          .overrideWithValue(brainGateway ?? FakeBrainModelUpdateGateway(configured: false)),
      brainModelVersionStoreProvider.overrideWithValue(FakeBrainModelVersionStore()),
      notificationPermissionGatewayProvider
          .overrideWithValue(FakeNotificationPermissionGateway()),
      localModelPreferencesProvider.overrideWithValue(FakeLocalModelPreferences()),
      // STT
      sttModelGatewayProvider
          .overrideWithValue(sttGateway ?? FakeSttModelGateway(installed: sttInstalled)),
      // TTS
      ttsVoiceGatewayProvider
          .overrideWithValue(ttsGateway ?? FakeTtsVoiceGateway(installed: ttsInstalled)),
      appLanguageCodeProvider.overrideWithValue('es'),
      // Embedding
      embedModelGatewayProvider
          .overrideWithValue(embedGateway ?? FakeEmbedModelGateway(installed: embedInstalled)),
      embedModelSourceConfigProvider.overrideWithValue(
        embedConfigured
            ? const EmbedModelSourceConfig(baseUrl: 'https://vps.example/embed')
            : const EmbedModelSourceConfig(),
      ),
      // The embed warmup runs a graph backfill after a download; there is no
      // graph DB in these host tests, so make it a clean no-op via an errored
      // rag service (the warmup swallows backfill failures by design).
      ragServiceProvider.overrideWith(
        (ref) => Future<RagService>.error(StateError('no graph in test')),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Settles the async hydration probes so the composed summary is deterministic.
Future<void> _settle(ProviderContainer c) async {
  await c.read(localModelManagerProvider.notifier).ready;
  await c.read(sttModelDownloadProvider.notifier).ready;
  await c.read(ttsVoiceInstalledProbeProvider.future);
  await c.read(embedModelInstalledProbeProvider.future);
}

void main() {
  group('lifeOsModelsReadyProvider', () {
    test('is TRUE only when all four models are installed', () async {
      final c = _container(
        brainInstalled: true,
        sttInstalled: _sttPaths,
        ttsInstalled: {'es_MX-claude': _ttsVoice},
        embedInstalled: _embedPaths,
      );
      await _settle(c);

      final summary = c.read(requiredModelsSummaryProvider);
      expect(summary.allReady, isTrue);
      expect(summary.readyCount, 4);
      expect(c.read(lifeOsModelsReadyProvider), isTrue);
    });

    test('is FALSE when any model is missing, and lists it as pending', () async {
      // Brain + STT + TTS present, embedding missing.
      final c = _container(
        brainInstalled: true,
        sttInstalled: _sttPaths,
        ttsInstalled: {'es_MX-claude': _ttsVoice},
        embedInstalled: null,
      );
      await _settle(c);

      final summary = c.read(requiredModelsSummaryProvider);
      expect(c.read(lifeOsModelsReadyProvider), isFalse);
      expect(summary.readyCount, 3);
      expect(summary.pending.map((m) => m.id), [RequiredModelId.embed]);
    });

    test('a fresh device (nothing installed) is not ready', () async {
      final c = _container(brainInstalled: false);
      await _settle(c);

      expect(c.read(lifeOsModelsReadyProvider), isFalse);
      expect(c.read(requiredModelsSummaryProvider).readyCount, 0);
    });
  });

  group('Descargar todo', () {
    test('downloads the MISSING models and never re-downloads the installed brain',
        () async {
      final brainGateway = FakeBrainModelUpdateGateway(
        configured: true,
        manifest: brainManifest(),
      );
      final sttGateway = FakeSttModelGateway(installed: null);
      final ttsGateway = FakeTtsVoiceGateway();
      final embedGateway = FakeEmbedModelGateway(installed: null);

      final c = _container(
        brainInstalled: true, // already on the device (adopted v1)
        sttGateway: sttGateway,
        ttsGateway: ttsGateway,
        embedGateway: embedGateway,
        brainGateway: brainGateway,
        embedConfigured: true,
      );
      await _settle(c);

      await c.read(requiredModelsDownloadProvider.notifier).downloadAll();

      // Brain skipped (installed) — the ~2.6 GB is NOT fetched again.
      expect(brainGateway.downloadCount, 0);
      // The three missing companions each downloaded exactly once.
      expect(sttGateway.downloadCalls, 1);
      expect(ttsGateway.downloadCalls, ['es_MX-claude']);
      expect(embedGateway.downloads, 1);

      // Everything is now installed → the experience is ready.
      expect(c.read(lifeOsModelsReadyProvider), isTrue);
      expect(c.read(requiredModelsDownloadProvider), isFalse); // sequence finished
    });

    test('with everything already installed, Descargar todo downloads nothing', () async {
      final sttGateway = FakeSttModelGateway(installed: _sttPaths);
      final ttsGateway = FakeTtsVoiceGateway(installed: {'es_MX-claude': _ttsVoice});
      final embedGateway = FakeEmbedModelGateway(installed: _embedPaths);

      final c = _container(
        brainInstalled: true,
        sttGateway: sttGateway,
        ttsGateway: ttsGateway,
        embedGateway: embedGateway,
        embedConfigured: true,
      );
      await _settle(c);

      await c.read(requiredModelsDownloadProvider.notifier).downloadAll();

      expect(sttGateway.downloadCalls, 0);
      expect(ttsGateway.downloadCalls, isEmpty);
      expect(embedGateway.downloads, 0);
      expect(c.read(lifeOsModelsReadyProvider), isTrue);
    });
  });
}
