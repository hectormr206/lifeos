import 'dart:async';

import '../../chat/domain/text_to_speech_gateway.dart';
import '../domain/piper_speech_synthesizer.dart';

/// Composite [TextToSpeechGateway]: Piper-preferred with a system-voice
/// fallback, so the 🔊 button ALWAYS works (roadmap slice B3).
///
/// speak():
///  * Piper voice installed → neural speech via [preferred].
///  * Voice not downloaded yet ([PiperVoiceUnavailableException]) → fire
///    [onVoiceAbsent] ONCE per attempt (the lazy background download — Piper
///    next time) and read the message with the system voice this time.
///  * Synthesis/playback failure (anything else) → system voice, WITHOUT
///    re-triggering a download (the files are already on disk).
///
/// One-at-a-time holds ACROSS engines: the non-chosen engine is stopped
/// before/when the other starts. [completions] merges both engines' natural
/// ends — at most one is ever audible, so the merged stream stays unambiguous.
class PiperPreferredTextToSpeechGateway implements TextToSpeechGateway {
  PiperPreferredTextToSpeechGateway({
    required this._preferred,
    required this._fallback,
    this._onVoiceAbsent,
  }) {
    _subs = [
      _preferred.completions.listen(_emitCompletion),
      _fallback.completions.listen(_emitCompletion),
    ];
  }

  final TextToSpeechGateway _preferred;
  final TextToSpeechGateway _fallback;
  final void Function()? _onVoiceAbsent;

  final _completions = StreamController<void>.broadcast();
  late final List<StreamSubscription<void>> _subs;

  void _emitCompletion(void _) {
    if (!_completions.isClosed) _completions.add(null);
  }

  @override
  Future<void> speak(String text) async {
    // A previous utterance may be on the OTHER engine — stop the system voice
    // before Piper starts (Piper's own speak stops its previous playback).
    try {
      await _fallback.stop();
    } catch (_) {
      // A dead fallback channel must never block Piper speech.
    }
    try {
      await _preferred.speak(text);
    } on PiperVoiceUnavailableException {
      _onVoiceAbsent?.call(); // kick the lazy download; Piper next time
      await _speakWithFallback(text);
    } catch (_) {
      // Synthesis/playback failed with the voice present — files are fine,
      // downloading again would not help. Just keep the button working.
      await _speakWithFallback(text);
    }
  }

  Future<void> _speakWithFallback(String text) async {
    try {
      await _preferred.stop(); // cancel any pending synthesis/playback
    } catch (_) {/* best effort */}
    await _fallback.speak(text);
  }

  @override
  Future<void> stop() async {
    try {
      await _preferred.stop();
    } catch (_) {/* still stop the other engine */}
    await _fallback.stop();
  }

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    try {
      await _preferred.dispose();
    } catch (_) {/* never let teardown throw */}
    try {
      await _fallback.dispose();
    } catch (_) {/* never let teardown throw */}
    await _completions.close();
  }
}
