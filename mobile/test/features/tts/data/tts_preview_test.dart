// Proves the preview's epoch/cancellation guard: a preview that finishes LATE
// must never stop and replace the most recently requested one — the user hears
// the voice of the row they tapped LAST (same protection the main speak path
// has via its `_epoch` counter). Also: stop() invalidates an in-flight
// synthesis so it cannot play afterwards.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/tts_preview.dart';
import 'package:lifeos/features/tts/domain/piper_speech_synthesizer.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';

import '../support/fake_tts.dart';

TtsVoicePaths _voice(String id) =>
    TtsVoicePaths(model: '$id.onnx', tokens: '$id.tokens.txt', dataDir: '/data');

/// Per-voice gates + per-voice sample lengths so a test can hold ONE synthesis
/// in flight and tell apart which voice's audio actually played.
class _ScriptedSynthesizer implements PiperSpeechSynthesizer {
  final Map<String, Completer<void>> gates = {};
  final Map<String, int> sampleCounts = {};

  @override
  Future<SynthesizedAudio> synthesize({
    required TtsVoicePaths voice,
    required String text,
    double speed = 1.0,
  }) async {
    final gate = gates[voice.model];
    if (gate != null) await gate.future;
    return SynthesizedAudio(
      samples: Float32List(sampleCounts[voice.model] ?? 1),
      sampleRate: 22050,
    );
  }
}

void main() {
  test('a LATE first preview never replaces the most recently requested one', () async {
    final synth = _ScriptedSynthesizer()
      ..gates['amy.onnx'] = Completer<void>() // Amy synthesizes slowly…
      ..sampleCounts['amy.onnx'] = 100
      ..sampleCounts['alan.onnx'] = 200; // …Alan is instant (cached).
    final playback = FakePlayback();
    final preview = TtsPreview(synthesizer: synth, playback: playback);

    // Tap Amy (slow), then immediately tap Alan (fast).
    final amy = preview.play(voice: _voice('amy'), text: 'Hola, soy tu voz.');
    final alan = preview.play(voice: _voice('alan'), text: 'Hola, soy tu voz.');
    await alan;

    expect(playback.played, hasLength(1));
    final alanBytes = playback.played.single.length;

    // Amy's synthesis finishes LATE → must be dropped, not cut Alan off.
    synth.gates['amy.onnx']!.complete();
    await amy;

    expect(playback.played, hasLength(1),
        reason: 'the stale Amy sample must never reach the speaker');
    expect(playback.played.single.length, alanBytes,
        reason: 'what is playing is still the LAST requested voice (Alan)');
    expect(playback.stops, 1, reason: 'only Alan\'s own pre-play stop ran');
  });

  test('stop() invalidates an in-flight synthesis (no late playback)', () async {
    final synth = _ScriptedSynthesizer()..gates['amy.onnx'] = Completer<void>();
    final playback = FakePlayback();
    final preview = TtsPreview(synthesizer: synth, playback: playback);

    final pending = preview.play(voice: _voice('amy'), text: 'Hola.');
    await preview.stop();
    synth.gates['amy.onnx']!.complete();
    await pending;

    expect(playback.played, isEmpty, reason: 'stopped previews never play late');
  });

  test('the normal single-preview flow still plays (stop-then-play)', () async {
    final synth = _ScriptedSynthesizer()..sampleCounts['amy.onnx'] = 50;
    final playback = FakePlayback();
    final preview = TtsPreview(synthesizer: synth, playback: playback);

    await preview.play(voice: _voice('amy'), text: 'Hola.');

    expect(playback.stops, 1);
    expect(playback.played, hasLength(1));
  });
}
