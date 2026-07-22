/// Seam over the device text-to-speech engine so the "Axi habla" (speak-aloud)
/// flow is unit-testable with a fake and the concrete plugin stays at the edge.
///
/// SWAP SEAM: the concrete [FlutterTtsTextToSpeechGateway] uses the phone's
/// built-in OS voices via `flutter_tts` — the interim engine. A future slice
/// can point [textToSpeechGatewayProvider] at a higher-quality on-device engine
/// (Piper) implementing this same interface, WITHOUT touching the UI or the
/// [SpeechController]. Keep this contract engine-agnostic.
abstract class TextToSpeechGateway {
  /// Speaks [text] aloud. Any utterance already in progress is stopped first —
  /// only one message is ever read at a time. Completes once speech has been
  /// kicked off (not when it finishes); natural completion is signalled via
  /// [completions]. A blank [text] is a no-op.
  Future<void> speak(String text);

  /// Stops the current playback immediately. Does NOT emit on [completions]
  /// (the caller owns the UI state for a deliberate stop).
  Future<void> stop();

  /// Fires once each time an utterance finishes ON ITS OWN (natural end or a
  /// engine-side error) — lets the active button revert from stop → speak.
  /// A programmatic [stop] / [speak]-switch does NOT emit here.
  Stream<void> get completions;

  /// Releases native engine resources.
  Future<void> dispose();
}
