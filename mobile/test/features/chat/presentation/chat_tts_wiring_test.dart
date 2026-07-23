// Proves the B3 provider re-point: `textToSpeechGatewayProvider` now serves
// the Piper-preferred composite (same TextToSpeechGateway seam — zero UI
// change), and a speak attempt WITHOUT the voice on disk kicks the lazy
// background download for the current app language.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/tts/data/piper_preferred_text_to_speech_gateway.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../tts/support/fake_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerWith(FakeTtsVoiceGateway voices, FakeSynthesizer synthesizer) {
    final container = ProviderContainer(overrides: [
      ttsVoiceGatewayProvider.overrideWithValue(voices),
      piperSpeechSynthesizerProvider.overrideWithValue(synthesizer),
      appLanguageCodeProvider.overrideWithValue('es'),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('textToSpeechGatewayProvider serves the Piper-preferred composite', () {
    final container = containerWith(FakeTtsVoiceGateway(), FakeSynthesizer());

    final gateway = container.read(textToSpeechGatewayProvider);

    expect(gateway, isA<PiperPreferredTextToSpeechGateway>());
  });

  test('first speak without the voice on disk triggers its background download', () async {
    final voices = FakeTtsVoiceGateway(); // nothing installed yet
    final container = containerWith(voices, FakeSynthesizer());
    final gateway = container.read(textToSpeechGatewayProvider);

    try {
      await gateway.speak('hola Axi');
    } catch (_) {
      // The system-voice fallback has no platform channel in tests — the
      // download trigger fired BEFORE the fallback utterance either way.
    }
    await Future<void>.delayed(Duration.zero);

    expect(voices.downloadCalls, ['es_MX-claude']); // Piper next time
  });
}
