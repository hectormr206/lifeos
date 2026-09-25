// Joining voice-activity segments into chunks Whisper can use well.
//
// On a real 13-minute recording Silero VAD cut 155 segments with a median of
// 3.6 s. Whisper reads one window of up to 30 s and does better with context,
// so neighbouring segments separated by a short pause are joined, up to a
// maximum length, and each chunk spans the ORIGINAL audio from its first
// segment's start to its last segment's end (the pauses included).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/speech_segments.dart';

const _rate = 16000;
SpeechSpan span(double startS, double lengthS) => SpeechSpan(
      start: (startS * _rate).round(),
      length: (lengthS * _rate).round(),
    );

List<(double, double)> seconds(List<SpeechSpan> spans) => [
      for (final s in spans) (s.start / _rate, (s.start + s.length) / _rate),
    ];

void main() {
  test('close segments are joined, pauses included', () {
    final chunks = joinSegments(
      [span(0, 3), span(3.4, 4), span(7.8, 2)],
      sampleRate: _rate,
    );

    expect(seconds(chunks), [(0.0, 9.8)]);
  });

  test('a long pause starts a new chunk', () {
    final chunks = joinSegments(
      [span(0, 3), span(5, 3)],
      sampleRate: _rate,
    );

    expect(seconds(chunks), [(0.0, 3.0), (5.0, 8.0)]);
  });

  test('a chunk never grows past the maximum', () {
    final chunks = joinSegments(
      [for (var i = 0; i < 10; i++) span(i * 4.2, 4)],
      sampleRate: _rate,
    );

    for (final (start, end) in seconds(chunks)) {
      expect(end - start, lessThanOrEqualTo(kMaxChunkSeconds));
    }
    expect(chunks.length, greaterThan(1));
  });

  test('one segment longer than the maximum stays whole: VAD already cut it',
      () {
    final chunks = joinSegments([span(0, 25)], sampleRate: _rate);

    expect(seconds(chunks), [(0.0, 25.0)]);
  });

  test('no segments, no chunks', () {
    expect(joinSegments(const [], sampleRate: _rate), isEmpty);
  });
}
