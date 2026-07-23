import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import '../domain/text_to_speech_gateway.dart';

/// Ordered TTS locale candidates for a given app language code (i18n slice).
///
/// The first one the device actually has installed wins; the bare language tag
/// is the last resort. ADDING A LANGUAGE = one more case here.
List<String> ttsLocaleCandidates(String languageCode) => switch (languageCode) {
      // Neutral Latin-American first, then Spain, then the bare tag.
      'es' => const ['es-MX', 'es-ES', 'es'],
      'en' => const ['en-US', 'en-GB', 'en'],
      _ => [languageCode],
    };

/// Returns the first [candidates] locale the engine reports as available, or
/// null when none are (leaving the engine on its default). Extracted as a pure
/// function — over an injected [isAvailable] probe — so the locale-selection
/// logic is unit-testable without the `flutter_tts` platform channel.
Future<String?> firstAvailableTtsLocale(
  List<String> candidates,
  Future<bool> Function(String locale) isAvailable,
) async {
  for (final locale in candidates) {
    try {
      if (await isAvailable(locale) == true) return locale;
    } catch (_) {
      // isLanguageAvailable can throw on some engines — try the next locale.
    }
  }
  return null;
}

/// [TextToSpeechGateway] backed by the device's built-in OS text-to-speech via
/// the `flutter_tts` plugin — the INTERIM speak-aloud engine.
///
/// i18n slice: the spoken language now follows the current app language
/// ([currentLanguageCode]) instead of being hard-forced to Spanish. The graceful
/// fallback is unchanged: if the device has NO voice for the selected language
/// we leave the engine on its default rather than crash.
///
/// SWAP SEAM: this confines `flutter_tts` to the edge. A future slice can drop
/// in a higher-quality on-device engine (Piper) behind [TextToSpeechGateway]
/// and only re-point `textToSpeechGatewayProvider` — no UI change.
class FlutterTtsTextToSpeechGateway implements TextToSpeechGateway {
  FlutterTtsTextToSpeechGateway({
    FlutterTts? tts,
    String Function()? currentLanguageCode,
    double Function()? currentRate,
    double Function()? currentPitch,
  })  : _tts = tts ?? FlutterTts(),
        _currentLanguageCode = currentLanguageCode ?? _defaultLanguageCode,
        _currentRate = currentRate ?? _defaultRate,
        _currentPitch = currentPitch ?? _defaultPitch {
    // Natural end of an utterance (and engine-side errors) revert the button.
    // A deliberate stop() / speak()-switch is intentionally NOT wired to the
    // cancel handler, so switching messages never spuriously clears the
    // just-set speaking state.
    _tts.setCompletionHandler(_emitCompletion);
    _tts.setErrorHandler((_) => _emitCompletion());
  }

  static String _defaultLanguageCode() => 'es';

  /// `flutter_tts` reads naturally at ~0.5 (0..1); 1.0 pitch is neutral.
  static double _defaultRate() => 0.5;
  static double _defaultPitch() => 1.0;

  final FlutterTts _tts;

  /// Reads the CURRENT app language live at each speak, so switching language in
  /// Settings changes the spoken voice without recreating the gateway.
  final String Function() _currentLanguageCode;

  /// Read live at each speak so the "Voz" sliders apply to the next utterance
  /// without recreating the gateway. Values are the plugin's native scales:
  /// rate 0.0..1.0 (~0.5 natural), pitch 0.5..2.0 (1.0 neutral).
  final double Function() _currentRate;
  final double Function() _currentPitch;

  final _completions = StreamController<void>.broadcast();

  /// Whether the one-time volume setup ran (rate/pitch are re-applied per speak).
  bool _configured = false;

  /// The language the voice is currently set to, so we re-select the locale only
  /// when the app language actually changes.
  String? _appliedLanguageCode;

  void _emitCompletion() {
    if (!_completions.isClosed) _completions.add(null);
  }

  Future<void> _ensureConfigured() async {
    if (!_configured) {
      await _tts.setVolume(1.0);
      _configured = true;
    }
    // Re-applied every speak so a "Voz" slider change takes effect immediately.
    await _tts.setSpeechRate(_currentRate()); // 0..1; ~0.5 natural narration pace
    await _tts.setPitch(_currentPitch());
    await _applyVoiceForCurrentLanguage();
  }

  /// Picks the best available voice for the CURRENT app language. If the device
  /// has NO voice for it we leave the engine on its default rather than crash —
  /// the text is still read, just with the default voice. Re-runs only when the
  /// language changed since the last apply.
  Future<void> _applyVoiceForCurrentLanguage() async {
    final languageCode = _currentLanguageCode();
    if (languageCode == _appliedLanguageCode) return;
    final chosen = await firstAvailableTtsLocale(
      ttsLocaleCandidates(languageCode),
      (locale) async => (await _tts.isLanguageAvailable(locale)) == true,
    );
    if (chosen != null) {
      await _tts.setLanguage(chosen);
    }
    // Mark applied regardless: a missing voice stays on the engine default, and
    // we should not re-probe every utterance for the same language.
    _appliedLanguageCode = languageCode;
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
    try {
      await _tts.stop();
    } catch (_) {
      // The platform channel may be gone (shutdown / no engine / a widget test
      // with no plugin) — never let teardown throw.
    }
    await _completions.close();
  }
}
