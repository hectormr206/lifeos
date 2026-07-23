/// The published brain-model OTA manifest (self-hosted model update).
///
/// Mirrors the APK OTA's `AppManifest` house pattern, but for the on-device
/// chat weights: the VPS hosts `manifest.json` + the `.litertlm` file flat
/// under one public base path (like /stt /tts /embed — no access key). Shape:
/// `{modelName, versionCode, filename, sha256, sizeBytes, notes, publishedAt}`.
/// The app compares `versionCode` against the tracked installed version to
/// decide "hay un nuevo modelo disponible" — never the filename.
library;

/// Stable internal name of the on-device chat model. The manifest's
/// `modelName` should match; the tracked install is keyed on it so a future
/// different model (a rename, a new family) is never silently "updated" over.
const String kBrainModelName = 'gemma-4-E2B-it';

/// Stable ON-DISK filename the weights always live under locally, REGARDLESS
/// of the (possibly versioned) filename published in the manifest. flutter_gemma
/// keys installation state on the file's last path segment (`modelId`), so
/// keeping this constant means `isModelInstalled` keeps working across updates.
const String kBrainModelFileName = 'gemma-4-E2B-it.litertlm';

/// The versionCode an already-installed model with NO tracked version is
/// adopted as (migration for installs that predate the OTA flow — e.g. the
/// original HuggingFace download). Adopt in place; never re-download 2.6GB.
const int kBrainModelAdoptedVersionCode = 1;

/// Immutable, parsed brain-model manifest.
class BrainModelManifest {
  const BrainModelManifest({
    required this.modelName,
    required this.versionCode,
    required this.filename,
    required this.sha256,
    required this.sizeBytes,
    required this.notes,
    this.publishedAt = '',
  });

  /// Stable internal model name (expected: [kBrainModelName]).
  final String modelName;

  /// Monotonic publish counter — the source of truth for "is this newer than
  /// what's installed?" (exactly like the APK OTA's versionCode).
  final int versionCode;

  /// Filename of the weights on the server (`<base>/<filename>`). May be
  /// versioned server-side; locally the file is always [kBrainModelFileName].
  final String filename;

  /// Lowercase hex SHA-256 of the weights — verified after download before the
  /// file is ever handed to flutter_gemma (reject on mismatch).
  final String sha256;

  /// Size in bytes — surfaced so the user knows what a ~2.6GB download costs.
  final int sizeBytes;

  /// Release notes for this model build (may be empty).
  final String notes;

  /// ISO-8601 UTC publish timestamp (may be empty).
  final String publishedAt;

  /// Parse a manifest map (the decoded JSON body).
  ///
  /// Throws [FormatException] when `versionCode` is missing/unparseable — a
  /// malformed manifest must never be silently treated as a valid "no update".
  /// String fields default to empty so a partial-but-usable manifest still
  /// works (the downloader separately refuses to fetch without sha/filename).
  factory BrainModelManifest.fromJson(Map<String, Object?> json) {
    final versionCode = _asInt(json['versionCode']);
    if (versionCode == null) {
      throw const FormatException('brain manifest missing/invalid versionCode');
    }
    return BrainModelManifest(
      modelName: _asString(json['modelName']),
      versionCode: versionCode,
      filename: _asString(json['filename']),
      sha256: _asString(json['sha256']),
      sizeBytes: _asInt(json['sizeBytes']) ?? 0,
      notes: _asString(json['notes']),
      publishedAt: _asString(json['publishedAt']),
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String _asString(Object? value) => value == null ? '' : value.toString();

  @override
  bool operator ==(Object other) =>
      other is BrainModelManifest &&
      other.modelName == modelName &&
      other.versionCode == versionCode &&
      other.filename == filename &&
      other.sha256 == sha256 &&
      other.sizeBytes == sizeBytes &&
      other.notes == notes &&
      other.publishedAt == publishedAt;

  @override
  int get hashCode =>
      Object.hash(modelName, versionCode, filename, sha256, sizeBytes, notes, publishedAt);

  @override
  String toString() => 'BrainModelManifest($modelName v$versionCode, $sizeBytes bytes)';
}
