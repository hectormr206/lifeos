import 'dart:typed_data';

import 'tts_voice.dart';

/// Raised by [SherpaPiperTtsGateway.speak] when the SELECTED Piper voice is not
/// installed yet — the composite gateway falls back to the system voice AND
/// triggers the lazy background download of that voice.
class PiperVoiceUnavailableException implements Exception {
  PiperVoiceUnavailableException(this.voiceId);
  final String voiceId;
  @override
  String toString() => 'Piper voice "$voiceId" is not installed.';
}

/// Raised when synthesis itself fails (engine load error, bogus model…) —
/// the composite gateway falls back to the system voice WITHOUT re-triggering
/// a download (the files are present; downloading again would not help).
class PiperSynthesisException implements Exception {
  PiperSynthesisException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Raw synthesized audio: mono Float32 PCM in -1..1 at [sampleRate] Hz.
class SynthesizedAudio {
  const SynthesizedAudio({required this.samples, required this.sampleRate});
  final Float32List samples;
  final int sampleRate;
}

/// Seam over the neural synthesis engine (sherpa-onnx Piper VITS) so the
/// gateway is unit-testable without FFI. Implementations MUST run the actual
/// synthesis off the UI thread — it is CPU-bound for hundreds of ms.
abstract class PiperSpeechSynthesizer {
  /// Synthesizes [text] with [voice] at [speed] (1.0 = the voice's natural
  /// pace; > 1.0 faster, < 1.0 slower). Throws [PiperSynthesisException] on any
  /// engine failure (never returns silently-empty audio as success).
  Future<SynthesizedAudio> synthesize({
    required TtsVoicePaths voice,
    required String text,
    double speed = 1.0,
  });
}
