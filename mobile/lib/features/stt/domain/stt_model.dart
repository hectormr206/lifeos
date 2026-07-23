/// Resolved on-disk paths to the three files that make up the offline Whisper
/// model (roadmap slice B2). sherpa-onnx needs all three to build a recognizer.
class SttModelPaths {
  const SttModelPaths({
    required this.encoder,
    required this.decoder,
    required this.tokens,
  });

  /// Whisper int8 encoder (`*-encoder.int8.onnx`).
  final String encoder;

  /// Whisper int8 decoder (`*-decoder.int8.onnx`).
  final String decoder;

  /// Whisper token table (`*-tokens.txt`).
  final String tokens;
}

/// Progress/availability state of the ~80 MB Whisper model that is downloaded
/// on first use. Drives a download affordance in the UI.
sealed class SttModelStatus {
  const SttModelStatus();
}

/// The model files are not present yet — offer a download.
class SttModelAbsent extends SttModelStatus {
  const SttModelAbsent();
}

/// A download is in flight; [progress] is 0.0..1.0 (may be indeterminate < 0).
class SttModelDownloading extends SttModelStatus {
  const SttModelDownloading(this.progress);
  final double progress;
}

/// All model files are present on disk and STT is usable.
class SttModelReady extends SttModelStatus {
  const SttModelReady();
}

/// The last download attempt failed with [message]; the user may retry.
class SttModelFailed extends SttModelStatus {
  const SttModelFailed(this.message);
  final String message;
}
