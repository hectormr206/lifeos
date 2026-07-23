import 'dart:typed_data';

/// Seam over WAV playback for synthesized speech so the Piper gateway is
/// unit-testable without the `audioplayers` platform channel.
abstract class TtsPlayback {
  /// Starts playing [wavBytes] (a complete RIFF/WAV file), stopping anything
  /// already playing first. Completes once playback has been kicked off.
  Future<void> play(Uint8List wavBytes);

  /// Stops playback immediately. Does NOT emit on [completions].
  Future<void> stop();

  /// Fires once each time playback finishes ON ITS OWN (natural end).
  Stream<void> get completions;

  /// Releases the player.
  Future<void> dispose();
}
