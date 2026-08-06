/// The state of one "Dictar" take.
///
/// Mirrors `features/stt/domain/stt_model.dart`'s `SttModelStatus`: a sealed
/// hierarchy so the screen switches exhaustively and a new state cannot be
/// forgotten at a call site.
///
/// There is deliberately no "failed quietly" state. Every way a take can go
/// wrong lands in [DictationFailed] carrying a message the user can act on —
/// the repo's rule is that a capability which is attempted and fails must SAY
/// so, never degrade into silence. (Hiding is reserved for capabilities the
/// platform does not have at all; see `core/platform/app_platform.dart`.)
sealed class DictationStatus {
  const DictationStatus();
}

/// Nothing is happening — the mic button is waiting to be pressed.
class DictationIdle extends DictationStatus {
  const DictationIdle();
}

/// The microphone is open and capturing.
class DictationRecording extends DictationStatus {
  const DictationRecording();
}

/// The take is finished and Whisper is decoding it on-device.
class DictationTranscribing extends DictationStatus {
  const DictationTranscribing();
}

/// A transcript the user can edit, send to Axi, or copy.
class DictationReady extends DictationStatus {
  const DictationReady(this.text);

  /// The transcript, already trimmed and guaranteed non-empty (an empty decode
  /// is a [DictationFailed], not a blank field with no explanation).
  final String text;
}

/// The take could not be completed. [message] is user-facing.
class DictationFailed extends DictationStatus {
  const DictationFailed(
    this.message, {
    this.modelMissing = false,
    this.permissionDenied = false,
    this.recorderUnavailable = false,
  });

  /// What went wrong, in words the user can act on.
  final String message;

  /// The voice model is not installed. Singled out because it is the one
  /// failure the user can fix from inside the app — the screen offers the
  /// download instead of just an error.
  final bool modelMissing;

  /// The microphone permission was refused.
  final bool permissionDenied;

  /// The recorder itself could not open. On Linux this is usually the missing
  /// `parecord`/`ffmpeg` pair that `record_linux` shells out to and that
  /// `tools/install-linux.sh` probes for — so the screen adds that hint on
  /// desktop. [message] always carries the underlying error too.
  final bool recorderUnavailable;
}
