// Reading a passage aloud, sentence by sentence, with an English voice.
//
// A passage is a minute or two of audio, and synthesizing it in one go on a
// phone would mean a long silence before the first word. So it is spoken a
// sentence at a time, with the NEXT sentence synthesized while the current one
// plays: the first word comes fast and there are no gaps. The stream reports
// which sentence is playing, so the reader can follow it in the text (reading
// while listening).
//
// It reuses the app's own Piper chain (synthesizer → WAV → playback) and the
// voices already in the catalog. Different passages get different speakers
// from the installed English voices: listening only to one voice trains the
// ear for one voice.
library;

import 'dart:async';

import '../../tts/data/wav_encoder.dart';
import '../../tts/domain/piper_speech_synthesizer.dart';
import '../../tts/domain/tts_playback.dart';
import '../../tts/domain/tts_voice.dart';

/// The slower pace offered for listening practice. Learner broadcasts such as
/// VOA Learning English were read about a third slower than normal speech.
const double kSlowSpeed = 0.8;

/// An installed English voice for a passage, or null when none is installed.
/// The same [seed] always gets the same voice; different seeds spread across
/// the installed speakers.
String? pickEnglishVoice(List<String> installedIds, {required int seed}) {
  final english = [
    for (final id in installedIds)
      if (id.startsWith('en_')) id,
  ]..sort();
  if (english.isEmpty) return null;
  return english[seed.abs() % english.length];
}

class PassageSpeaker {
  PassageSpeaker({required this._synthesizer, required this._playback});

  final PiperSpeechSynthesizer _synthesizer;
  final TtsPlayback _playback;

  /// Bumped by every [speak] and [stop]: a run whose epoch is stale ends.
  int _epoch = 0;
  Completer<void> _stopped = Completer<void>();

  /// Speaks [sentences] in order and emits the index of each as it starts.
  /// Ends after the last one, or right away after [stop]. A synthesis failure
  /// is emitted as an error and ends the run.
  Stream<int> speak(
    List<String> sentences, {
    required TtsVoicePaths voice,
    double speed = 1.0,
  }) async* {
    final epoch = ++_epoch;
    _stopped = Completer<void>();
    final stopped = _stopped.future;

    // The next sentence is synthesized AHEAD, while the current one plays. If
    // that fails before the loop awaits it, the error would surface as an
    // unhandled one; a handler is attached up front, and the later `await`
    // still receives the error and reports it through the stream.
    Future<SynthesizedAudio> prefetch(int i) {
      final audio = _synthesizer.synthesize(
          voice: voice, text: sentences[i], speed: speed);
      audio.then((_) {}, onError: (Object _) {});
      return audio;
    }

    Future<SynthesizedAudio>? next = sentences.isEmpty ? null : prefetch(0);
    for (var i = 0; i < sentences.length; i++) {
      final audio = await next!;
      if (epoch != _epoch) return;
      next = i + 1 < sentences.length ? prefetch(i + 1) : null;

      final ended = _playback.completions.first;
      await _playback.play(pcmFloat32ToWav16(audio.samples, audio.sampleRate));
      yield i;
      await Future.any([ended, stopped]);
      if (epoch != _epoch) return;
    }
  }

  /// Stops speaking now. Nothing queued plays afterwards.
  Future<void> stop() {
    _epoch++;
    if (!_stopped.isCompleted) _stopped.complete();
    return _playback.stop();
  }
}
