import 'brain_model_manifest.dart';

/// Raised when the brain-model download cannot be completed or verified.
class BrainModelDownloadException implements Exception {
  BrainModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Talks to the PUBLIC brain-model OTA source on the VPS (the same house
/// pattern as the APK OTA + STT/TTS/EMBED model sources):
///   * `GET <base>/manifest.json` → [BrainModelManifest] (fail-soft null —
///     offline / nothing published / malformed must never crash app open),
///   * `GET <base>/<manifest.filename>` → the ~2.6GB `.litertlm` weights,
///     downloaded resumable via background_downloader, SHA-256-verified
///     against the manifest, then parked at a STABLE local path
///     (`.../brain_model/gemma-4-E2B-it.litertlm`) whose path is handed to
///     flutter_gemma via its file-install API.
///
/// Abstracted so the notifier is unit-testable with an in-memory fake.
abstract class BrainModelUpdateGateway {
  /// Whether a real base URL is configured (placeholder replaced or
  /// `--dart-define=BRAIN_MODEL_BASE_URL` provided). When false the app falls
  /// back to the legacy in-engine network download and never checks for
  /// updates.
  bool get isConfigured;

  /// Fetches + parses `<base>/manifest.json`. Returns null on ANY failure
  /// (unconfigured, offline, 404, malformed) — the update check is fail-soft.
  Future<BrainModelManifest?> fetchManifest();

  /// Downloads the weights described by [manifest], verifies their SHA-256,
  /// and returns the absolute LOCAL path of the verified file (the stable
  /// [kBrainModelFileName] location). Emits fractional progress in `0.0..1.0`.
  ///
  /// Throws [BrainModelDownloadException] on an unconfigured source, an
  /// incomplete download, or a sha256 mismatch (the bogus file is deleted so
  /// it can never be handed to flutter_gemma).
  Future<String> downloadAndVerify(
    BrainModelManifest manifest, {
    void Function(double progress)? onProgress,
  });

  /// Deletes the OTA-downloaded weights file, if present. Needed because
  /// flutter_gemma's `uninstallModel` does NOT delete external
  /// (`fromFile`-installed) files — only registrations + files in its own
  /// model dir. Safe to call when nothing was ever downloaded.
  Future<void> deleteLocalFile();
}
