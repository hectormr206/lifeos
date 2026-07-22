import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import '../domain/text_to_speech_gateway.dart';

/// [TextToSpeechGateway] backed by the device's built-in OS text-to-speech via
/// the `flutter_tts` plugin — the INTERIM speak-aloud engine.
///
/// SWAP SEAM: this confines `flutter_tts` to the edge. A future slice can drop
/// in a higher-quality on-device engine (Piper) behind [TextToSpeechGateway]
/// and only re-point `textToSpeechGatewayProvider` — no UI change.
class FlutterTtsTextToSpeechGateway implements TextToSpeechGateway {
  FlutterTtsTextToSpeechGateway([FlutterTts? tts]) : _tts = tts ?? FlutterTts() {
    // Natural end of an utterance (and engine-side errors) revert the button.
    // A deliberate stop() / speak()-switch is intentionally NOT wired to the
    // cancel handler, so switching messages never spuriously clears the
    // just-set speaking state.
    _tts.setCompletionHandler(_emitCompletion);
    _tts.setErrorHandler((_) => _emitCompletion());
  }

  final FlutterTts _tts;
  final _completions = StreamController<void>.broadcast();
  bool _configured = false;

  /// Spanish locales in preference order: neutral Latin-American first, then
  /// Spain, then the bare language tag. The first one the device actually has
  /// installed wins.
  static const _spanishLocales = ['es-MX', 'es-ES', 'es'];

  void _emitCompletion() {
    if (!_completions.isClosed) _completions.add(null);
  }

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _applySpanishVoice();
    await _tts.setSpeechRate(0.5); // 0..1; ~natural narration pace
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    _configured = true;
  }

  /// Picks the best available Spanish voice. If the device has NO Spanish voice
  /// installed we leave the engine on its default rather than crash — the
  /// neutral-Spanish text is still read, just with the default voice.
  Future<void> _applySpanishVoice() async {
    for (final locale in _spanishLocales) {
      try {
        final available = await _tts.isLanguageAvailable(locale);
        if (available == true) {
          await _tts.setLanguage(locale);
          return;
        }
      } catch (_) {
        // isLanguageAvailable can throw on some engines — try the next locale.
      }
    }
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _ensureConfigured();
    await _tts.stop(); // one utterance at a time
    await _tts.speak(text);
  }

  @override
  Future<void> stop() => _tts.stop();

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Future<void> dispose() async {
    await _tts.stop();
    await _completions.close();
  }
}
