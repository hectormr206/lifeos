import 'app_manifest.dart';

/// Result of an update check (self-hosted OTA app update).
///
/// Three outcomes, matching the spec: a strictly-newer engine build is
/// [UpdateAvailable]; an equal-or-older build is [UpToDate]; anything that
/// prevented a definite answer (no engine paired, 404 with nothing published,
/// network error, malformed manifest) is [UpdateUnknown] — never a crash.
sealed class UpdateStatus {
  const UpdateStatus();
}

/// A strictly-newer build is available on the paired engine.
class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable({required this.manifest});

  final AppManifest manifest;

  String get versionName => manifest.versionName;
  String get notes => manifest.notes;
  int get sizeBytes => manifest.sizeBytes;
  int get versionCode => manifest.versionCode;

  @override
  bool operator ==(Object other) => other is UpdateAvailable && other.manifest == manifest;

  @override
  int get hashCode => manifest.hashCode;

  @override
  String toString() => 'UpdateAvailable($versionName+$versionCode)';
}

/// The running build is the latest (engine build code <= running build code).
class UpToDate extends UpdateStatus {
  const UpToDate({required this.currentVersionName, required this.currentVersionCode});

  final String currentVersionName;
  final int currentVersionCode;

  @override
  bool operator ==(Object other) =>
      other is UpToDate &&
      other.currentVersionName == currentVersionName &&
      other.currentVersionCode == currentVersionCode;

  @override
  int get hashCode => Object.hash(currentVersionName, currentVersionCode);

  @override
  String toString() => 'UpToDate($currentVersionName+$currentVersionCode)';
}

/// Could not determine update state (no engine / 404 / network / bad payload).
/// [reason] is a short, user-facing Spanish hint — never surfaced as an error.
class UpdateUnknown extends UpdateStatus {
  const UpdateUnknown([this.reason]);

  final String? reason;

  @override
  bool operator ==(Object other) => other is UpdateUnknown && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'UpdateUnknown(${reason ?? ''})';
}
