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

  /// Fire-and-forget for the chat flow: it DELEGATES to [speakDiagnostic] and
  /// discards the report, so the try/fallback decision lives in exactly one
  /// place. Two copies of it is how the two paths drift apart.
  @override
  Future<void> speak(String text) async {
    await speakDiagnostic(text);
  }

  /// The real classifier. Returns:
  ///  * [VoiceTestSpoke] `neural` — Piper spoke;
  ///  * [VoiceTestSpoke] `system` — Piper failed, the OS voice covered it, and
  ///    [VoiceTestSpoke.neuralFailure] carries WHY (the user is entitled to
  ///    know he just heard the robotic voice, and because of what);
  ///  * [VoiceTestFailed] — both engines failed. The neural cause is kept when
  ///    it is the informative one; a dead OS engine on top of it is
  ///    [VoiceTestFailure.noEngine].
  @override
  Future<VoiceTestOutcome> speakDiagnostic(String text) async {
    // A previous utterance may be on the OTHER engine — stop the system voice
    // before Piper starts (Piper's own speak stops its previous playback).
    try {
      await _fallback.stop();
    } catch (_) {
      // A dead fallback channel must never block Piper speech.
    }

    final preferred = await _preferred.speakDiagnostic(text);
    if (preferred is VoiceTestSpoke) return preferred;

    final failure = (preferred as VoiceTestFailed).failure;
    if (failure == VoiceTestFailure.voiceMissing) {
      _onVoiceAbsent?.call(); // kick the lazy download; Piper next time
    }
    // Any other neural failure means the files are already there — downloading
    // again would not help, so we only cover this utterance.

    final fallback = await _speakWithFallback(text);
    return switch (fallback) {
      VoiceTestSpoke() => VoiceTestSpoke(VoiceTestEngine.system, neuralFailure: failure),
      // Nothing spoke at all. The neural cause is still the useful one unless
      // it was merely "not downloaded" — then the honest report is that this
      // device has no working voice engine.
      VoiceTestFailed(:final detail) => failure == VoiceTestFailure.voiceMissing
          ? VoiceTestFailed(VoiceTestFailure.noEngine, detail: detail)
          : VoiceTestFailed(failure, detail: (preferred).detail),
    };
  }

  Future<VoiceTestOutcome> _speakWithFallback(String text) async {
    try {
      await _preferred.stop(); // cancel any pending synthesis/playback
    } catch (_) {/* best effort */}
    return _fallback.speakDiagnostic(text);
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
