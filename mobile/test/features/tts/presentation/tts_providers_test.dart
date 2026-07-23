// Proves the Piper voice-download notifier: an already-installed voice lands
// Ready without re-downloading, a download streams progress then lands Ready,
// a failure lands Failed (never throws), and downloadForCurrentLanguage
// follows the app language.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../support/fake_tts.dart';

const _voice = TtsVoicePaths(model: 'm', tokens: 't', dataDir: 'd');

void main() {
  ProviderContainer containerWith(FakeTtsVoiceGateway gateway, {String language = 'es'}) {
    final container = ProviderContainer(overrides: [
      ttsVoiceGatewayProvider.overrideWithValue(gateway),
      appLanguageCodeProvider.overrideWithValue(language),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  group('TtsVoiceDownloadNotifier', () {
    test('starts Absent (no eager probing at build)', () {
      final container = containerWith(FakeTtsVoiceGateway());

      expect(container.read(ttsVoiceDownloadProvider), isA<TtsVoiceAbsent>());
    });

    test('an already-installed voice lands Ready WITHOUT downloading', () async {
      final gateway = FakeTtsVoiceGateway(installed: {'es': _voice});
      final container = containerWith(gateway);

      await container.read(ttsVoiceDownloadProvider.notifier).download('es');

      expect(container.read(ttsVoiceDownloadProvider), isA<TtsVoiceReady>());
      expect(gateway.downloadCalls, isEmpty);
    });

    test('download streams progress then lands Ready', () async {
      final gateway = FakeTtsVoiceGateway(downloadProgress: const [0.25, 0.75, 1.0]);
      final container = containerWith(gateway);
      final seen = <TtsVoiceStatus>[];
      container.listen(ttsVoiceDownloadProvider, (_, next) => seen.add(next));

      await container.read(ttsVoiceDownloadProvider.notifier).download('es');

      expect(gateway.downloadCalls, ['es']);
      expect(seen.whereType<TtsVoiceDownloading>(), isNotEmpty);
      expect(container.read(ttsVoiceDownloadProvider), isA<TtsVoiceReady>());
    });

    test('a failed download lands Failed, never throws', () async {
      final gateway = FakeTtsVoiceGateway(downloadError: Exception('boom'));
      final container = containerWith(gateway);

      await container.read(ttsVoiceDownloadProvider.notifier).download('es'); // must not throw

      expect(container.read(ttsVoiceDownloadProvider), isA<TtsVoiceFailed>());
    });

    test('downloadForCurrentLanguage downloads the APP language voice', () async {
      final gateway = FakeTtsVoiceGateway();
      final container = containerWith(gateway, language: 'en');

      await container.read(ttsVoiceDownloadProvider.notifier).downloadForCurrentLanguage();

      expect(gateway.downloadCalls, ['en']);
    });

    test('a language switch after Ready still downloads the OTHER voice', () async {
      final gateway = FakeTtsVoiceGateway(installed: {'es': _voice});
      final container = containerWith(gateway);
      final notifier = container.read(ttsVoiceDownloadProvider.notifier);

      await notifier.download('es'); // Ready via the installed probe
      await notifier.download('en'); // must NOT be skipped

      expect(gateway.downloadCalls, ['en']);
      expect(container.read(ttsVoiceDownloadProvider), isA<TtsVoiceReady>());
    });
  });
}
