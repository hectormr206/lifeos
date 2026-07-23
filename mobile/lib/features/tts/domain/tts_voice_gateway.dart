import 'tts_voice.dart';

/// Seam over "is this Piper voice on disk / fetch it" so the speak flow and the
/// catalog notifier are unit-testable with fakes and the concrete downloader
/// stays at the edge (mirrors the STT `SttModelGateway`).
///
/// Keyed by VOICE ID (e.g. `es_MX-claude`), not language: the catalog offers
/// several voices per language and the id is the hosted file stem.
abstract class TtsVoiceGateway {
  /// The installed voice with [voiceId], or null when any piece (model, tokens,
  /// espeak-ng-data) is missing or invalid.
  Future<TtsVoicePaths?> installedVoice(String voiceId);

  /// Downloads + installs the voice [voiceId] (model + config, plus the shared
  /// espeak-ng-data archive when not yet extracted), reporting aggregate 0..1
  /// [onProgress]. Throws on any failure — a partial/bogus install never reads
  /// back as installed.
  Future<TtsVoicePaths> download(
    String voiceId, {
    void Function(double progress)? onProgress,
  });
}
