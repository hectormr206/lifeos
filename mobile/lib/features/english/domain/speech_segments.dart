// Joining voice-activity segments into chunks Whisper can use well.
//
// On a real 13-minute recording Silero VAD cut 155 segments with a median of
// 3.6 s. Whisper reads one window of up to 30 s and transcribes better with
// context, so neighbouring segments separated by a short pause are joined up
// to [kMaxChunkSeconds]. Each chunk spans the ORIGINAL audio from its first
// segment's start to its last segment's end, pauses included, so nothing the
// VAD judged borderline between two segments is cut out. A single segment
// longer than the maximum stays whole: the VAD's own cap already bounded it.
library;

/// Longest chunk built by joining, well inside Whisper's 30 s window.
const double kMaxChunkSeconds = 20;

/// Pauses up to this long are joined over; longer ones start a new chunk.
const double kMaxJoinPauseSeconds = 1.0;

/// A stretch of audio, in samples.
class SpeechSpan {
  const SpeechSpan({required this.start, required this.length});

  final int start;
  final int length;

  int get end => start + length;
}

List<SpeechSpan> joinSegments(
  List<SpeechSpan> segments, {
  required int sampleRate,
}) {
  final maxLength = (kMaxChunkSeconds * sampleRate).round();
  final maxPause = (kMaxJoinPauseSeconds * sampleRate).round();
  final chunks = <SpeechSpan>[];
  SpeechSpan? current;
  for (final s in segments) {
    final open = current;
    if (open != null &&
        s.start - open.end <= maxPause &&
        s.end - open.start <= maxLength) {
      current = SpeechSpan(start: open.start, length: s.end - open.start);
      continue;
    }
    if (open != null) chunks.add(open);
    current = s;
  }
  if (current != null) chunks.add(current);
  return chunks;
}
