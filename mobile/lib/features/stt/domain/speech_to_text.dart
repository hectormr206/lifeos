/// On-device speech-to-text seam (roadmap slice B2).
///
/// Confines the sherpa-onnx Whisper plugin to the edge so the voice-note flow
/// (features/chat) is unit-testable with a fake — no native runtime, no model
/// file, no microphone. The concrete implementation lives in
/// `features/stt/data/sherpa_stt_service.dart`.
abstract class SpeechToText {
  /// Transcribes the 16 kHz mono PCM16 WAV file at [wavPath] to text.
  ///
  /// [languageCode] is the app's i18n language ('es' / 'en'); the recognizer is
  /// pinned to that language (Whisper is multilingual). Returns the transcript
  /// (already trimmed; MAY be empty when the note held no intelligible speech).
  /// Throws [SttException] when the model is not available or transcription
  /// fails — callers DEGRADE GRACEFULLY (canned reply), they never crash.
  Future<String> transcribe(String wavPath, {required String languageCode});
}

/// Raised when on-device transcription cannot be performed (model missing,
/// recognizer failed to load, decode error). Callers treat it as "couldn't
/// listen this time" and fall back — the voice note is never lost.
class SttException implements Exception {
  SttException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Maps the app i18n language code to the Whisper recognizer `language` value.
///
/// Whisper's multilingual base model keys off ISO-639-1 codes; 'es' and 'en'
/// are the two the app ships. Anything else falls back to Spanish (the app's
/// neutral default), matching `resolveSystemLocale`.
String sttWhisperLanguage(String appLanguageCode) =>
    appLanguageCode == 'en' ? 'en' : 'es';
