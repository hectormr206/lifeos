/// Seam over `audioplayers` so voice-note playback is unit-testable with a
/// fake. The concrete [AudioPlayersAudioPlayerGateway] confines the plugin to
/// the edge.
abstract class AudioPlayerGateway {
  /// Plays the audio file at [path] from the start. Completes when playback
  /// has been kicked off (not when it finishes).
  Future<void> play(String path);

  /// Pauses the current playback.
  Future<void> pause();

  /// Stops and resets the current playback.
  Future<void> stop();

  /// Fires `true` when a clip starts playing and `false` when it stops,
  /// pauses, or completes — lets a bubble toggle its play/pause icon.
  Stream<bool> get playingStream;

  /// Releases native player resources.
  Future<void> dispose();
}
