/// The engine's published OTA update manifest (self-hosted app update).
///
/// Mirrors `GET /api/app/manifest` from `axi/src/axi/app_updates.py`:
/// `{versionCode, versionName, apkFilename, sha256, sizeBytes, notes,
/// publishedAt}`. The app is sideloaded (no Play Store), so it polls this
/// manifest on the paired engine and self-updates when a newer build exists.
class AppManifest {
  const AppManifest({
    required this.versionCode,
    required this.versionName,
    required this.apkFilename,
    required this.sha256,
    required this.sizeBytes,
    required this.notes,
    required this.publishedAt,
  });

  /// Android `versionCode` of the published build — the source of truth for
  /// the "is this newer than what's running?" comparison (never versionName,
  /// which is cosmetic).
  final int versionCode;

  /// Human-facing version string (e.g. `1.4.0`).
  final String versionName;

  /// Stable filename of the APK inside the engine's updates dir. Not used for
  /// the download (that goes through `/api/app/download`), kept for display.
  final String apkFilename;

  /// Lowercase hex SHA-256 of the APK bytes — verified after download before
  /// the installer is ever invoked (reject on mismatch).
  final String sha256;

  /// APK size in bytes — surfaced so the user knows what a download will cost.
  final int sizeBytes;

  /// Release notes for this build (may be empty).
  final String notes;

  /// ISO-8601 UTC publish timestamp (may be empty).
  final String publishedAt;

  /// Parse a manifest map (the decoded JSON body).
  ///
  /// Throws [FormatException] when the two mandatory numeric fields
  /// (`versionCode`, `sizeBytes`) are missing/unparseable — a malformed
  /// manifest must never be silently treated as a valid "no update". String
  /// fields default to empty so a partial-but-usable manifest still works.
  factory AppManifest.fromJson(Map<String, Object?> json) {
    final versionCode = _asInt(json['versionCode']);
    if (versionCode == null) {
      throw const FormatException('manifest missing/invalid versionCode');
    }
    return AppManifest(
      versionCode: versionCode,
      versionName: _asString(json['versionName']),
      apkFilename: _asString(json['apkFilename']),
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
      other is AppManifest &&
      other.versionCode == versionCode &&
      other.versionName == versionName &&
      other.apkFilename == apkFilename &&
      other.sha256 == sha256 &&
      other.sizeBytes == sizeBytes &&
      other.notes == notes &&
      other.publishedAt == publishedAt;

  @override
  int get hashCode =>
      Object.hash(versionCode, versionName, apkFilename, sha256, sizeBytes, notes, publishedAt);

  @override
  String toString() => 'AppManifest(v$versionName+$versionCode, $sizeBytes bytes)';
}
