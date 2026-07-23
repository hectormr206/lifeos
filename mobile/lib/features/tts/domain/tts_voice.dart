/// Resolved on-disk pieces of ONE installed Piper voice (roadmap slice B3).
/// sherpa-onnx needs all three to build an offline VITS synthesizer.
class TtsVoicePaths {
  const TtsVoicePaths({
    required this.model,
    required this.tokens,
    required this.dataDir,
  });

  /// Piper VITS acoustic model (`*.onnx`, the sherpa-onnx-converted export).
  final String model;

  /// sherpa-onnx token table (`*.tokens.txt`), derived locally from the voice's
  /// `*.onnx.json` phoneme map after download.
  final String tokens;

  /// The extracted `espeak-ng-data` DIRECTORY (shared by all Piper voices) —
  /// what `OfflineTtsVitsModelConfig.dataDir` must point at.
  final String dataDir;
}

/// Progress/availability state of the per-language Piper voice that is
/// downloaded on first use. Drives the (future) Settings → Voz affordance and
/// the lazy first-speak download trigger.
sealed class TtsVoiceStatus {
  const TtsVoiceStatus();
}

/// The voice files are not present yet — the system voice is used meanwhile.
class TtsVoiceAbsent extends TtsVoiceStatus {
  const TtsVoiceAbsent();
}

/// A download is in flight; [progress] is 0.0..1.0 (may be indeterminate < 0).
class TtsVoiceDownloading extends TtsVoiceStatus {
  const TtsVoiceDownloading(this.progress);
  final double progress;
}

/// The voice is fully installed (model + tokens + espeak-ng-data) and Piper
/// speech is usable.
class TtsVoiceReady extends TtsVoiceStatus {
  const TtsVoiceReady();
}

/// The last download attempt failed with [message]; the user may retry.
class TtsVoiceFailed extends TtsVoiceStatus {
  const TtsVoiceFailed(this.message);
  final String message;
}
