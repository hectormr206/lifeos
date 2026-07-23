import 'tts_voice.dart';

/// Seam over "is the Piper voice for a language on disk / fetch it" so the
/// speak flow and the download notifier are unit-testable with fakes and the
/// concrete downloader stays at the edge (mirrors the STT `SttModelGateway`).
abstract class TtsVoiceGateway {
  /// The installed voice for app language [languageCode] ('es'/'en'), or null
  /// when any piece (model, tokens, espeak-ng-data) is missing/invalid or the
  /// language has no Piper voice configured.
  Future<TtsVoicePaths?> installedVoice(String languageCode);

  /// Downloads + installs the voice for [languageCode] (model + config, plus
  /// the shared espeak-ng-data archive when not yet extracted), reporting
  /// aggregate 0..1 [onProgress]. Throws on any failure — a partial/bogus
  /// install never reads back as installed.
  Future<TtsVoicePaths> download(
    String languageCode, {
    void Function(double progress)? onProgress,
  });
}
