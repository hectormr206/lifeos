import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/locale_providers.dart';
import '../data/background_downloader_tts_voice_gateway.dart';
import '../data/sherpa_piper_speech_synthesizer.dart';
import '../domain/piper_speech_synthesizer.dart';
import '../domain/tts_voice.dart';
import '../domain/tts_voice_gateway.dart';

/// Manages the on-device Piper voices: probing whether the current language's
/// voice is installed and downloading it on first use. Overridden with a fake
/// in tests.
final ttsVoiceGatewayProvider = Provider<TtsVoiceGateway>(
  (ref) => BackgroundDownloaderTtsVoiceGateway(),
);

/// On-device neural synthesis engine (sherpa-onnx Piper VITS). Loads + frees
/// the engine per synthesis, off the UI thread (see
/// [SherpaPiperSpeechSynthesizer]). Overridden with a fake in tests.
final piperSpeechSynthesizerProvider = Provider<PiperSpeechSynthesizer>(
  (ref) => const SherpaPiperSpeechSynthesizer(),
);

/// Drives the Piper voice-download state (roadmap slice B3).
///
/// Today the download is triggered LAZILY: the first speak attempt without an
/// installed voice kicks [downloadForCurrentLanguage] in the background while
/// the system voice covers that utterance — Piper takes over next time. A
/// later Settings → Voz slice can watch this same provider to offer an
/// explicit download button + progress bar. Never throws to callers — a
/// failed download lands in [TtsVoiceFailed] so the user (or the next speak)
/// may retry.
final ttsVoiceDownloadProvider =
    NotifierProvider<TtsVoiceDownloadNotifier, TtsVoiceStatus>(TtsVoiceDownloadNotifier.new);

class TtsVoiceDownloadNotifier extends Notifier<TtsVoiceStatus> {
  bool _downloading = false;

  @override
  TtsVoiceStatus build() => const TtsVoiceAbsent();

  /// Downloads the Piper voice for the CURRENT app language, streaming
  /// progress into [state]. No-op when a download is already in flight or the
  /// voice landed Ready this session.
  Future<void> downloadForCurrentLanguage() =>
      download(ref.read(appLanguageCodeProvider));

  /// Downloads the Piper voice for [languageCode], streaming progress into
  /// [state]. No-op when a download is already in flight; when the voice is
  /// already on disk (e.g. after a language switch back) it just lands Ready
  /// without re-downloading.
  Future<void> download(String languageCode) async {
    if (_downloading) return;
    _downloading = true;
    try {
      final gateway = ref.read(ttsVoiceGatewayProvider);
      if (await gateway.installedVoice(languageCode) != null) {
        state = const TtsVoiceReady();
        return;
      }
      state = const TtsVoiceDownloading(0);
      await gateway.download(
        languageCode,
        onProgress: (p) => state = TtsVoiceDownloading(p),
      );
      state = const TtsVoiceReady();
    } catch (e) {
      state = TtsVoiceFailed(e.toString());
    } finally {
      _downloading = false;
    }
  }
}
