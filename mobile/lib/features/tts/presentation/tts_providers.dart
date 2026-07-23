import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/audioplayers_tts_playback.dart';
import '../data/background_downloader_tts_voice_gateway.dart';
import '../data/sherpa_piper_speech_synthesizer.dart';
import '../data/tts_preview.dart';
import '../domain/piper_speech_synthesizer.dart';
import '../domain/tts_voice_gateway.dart';

/// Manages the on-device Piper voices: probing whether a voice id is installed
/// and downloading it on first use. Overridden with a fake in tests.
final ttsVoiceGatewayProvider = Provider<TtsVoiceGateway>(
  (ref) => BackgroundDownloaderTtsVoiceGateway(),
);

/// On-device neural synthesis engine (sherpa-onnx Piper VITS). Loads + frees
/// the engine per synthesis, off the UI thread (see
/// [SherpaPiperSpeechSynthesizer]). Overridden with a fake in tests.
final piperSpeechSynthesizerProvider = Provider<PiperSpeechSynthesizer>(
  (ref) => const SherpaPiperSpeechSynthesizer(),
);

/// One-off preview player (synthesize a sample with a chosen voice + play it),
/// used by the voice catalog's "Preescuchar" action. Kept separate from the
/// chat speak playback so a preview never fights the reply being read aloud.
final ttsPreviewProvider = Provider<TtsPreview>((ref) {
  final preview = TtsPreview(
    synthesizer: ref.watch(piperSpeechSynthesizerProvider),
    playback: AudioplayersTtsPlayback(),
  );
  ref.onDispose(preview.dispose);
  return preview;
});
