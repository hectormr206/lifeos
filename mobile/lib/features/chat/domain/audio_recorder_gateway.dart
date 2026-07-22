/// Seam over the `record` package so the press-and-hold voice-note flow is
/// unit-testable with a fake (no microphone, no platform channel). The
/// concrete [RecordAudioRecorderGateway] confines the plugin to the edge.
abstract class AudioRecorderGateway {
  /// Whether the mic permission is granted (requesting it if needed).
  Future<bool> hasPermission();

  /// Begins recording to a fresh on-disk file and returns its path. The file
  /// is finalised by [stop]; [cancel] discards it.
  Future<String> start();

  /// Stops recording and returns the finished file's path (the same path
  /// [start] returned), or `null` if nothing was recording.
  Future<String?> stop();

  /// Stops and discards the current recording (slide-to-cancel).
  Future<void> cancel();

  /// Whether a recording is currently in progress.
  Future<bool> isRecording();
}
