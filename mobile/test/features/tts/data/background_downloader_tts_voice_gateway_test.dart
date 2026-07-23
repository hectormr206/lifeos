// Proves the per-voice downloader group that fixes the concurrent-download
// deadlock: each voice's tasks live in their OWN group, so the defensive
// `reset(group:)` at the start of one download can never cancel a sibling
// voice that is downloading at the same time. Pure string derivation — no
// platform channels, no network.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/background_downloader_tts_voice_gateway.dart';

void main() {
  group('BackgroundDownloaderTtsVoiceGateway.groupForVoice', () {
    test('is stable for a given voice id', () {
      expect(
        BackgroundDownloaderTtsVoiceGateway.groupForVoice('es_MX-claude'),
        BackgroundDownloaderTtsVoiceGateway.groupForVoice('es_MX-claude'),
      );
    });

    test('differs between voices so one reset never hits another', () {
      final a = BackgroundDownloaderTtsVoiceGateway.groupForVoice('es_MX-claude');
      final b = BackgroundDownloaderTtsVoiceGateway.groupForVoice('en_US-lessac');
      final c = BackgroundDownloaderTtsVoiceGateway.groupForVoice('es_MX-ald');
      expect({a, b, c}, hasLength(3));
    });

    test('sanitizes id chars into a valid identifier group', () {
      final group = BackgroundDownloaderTtsVoiceGateway.groupForVoice('en_GB-jenny_dioco');
      expect(group, matches(RegExp(r'^[A-Za-z0-9_]+$')));
      expect(group, startsWith('tts_voice_'));
    });
  });
}
