import 'package:package_info_plus/package_info_plus.dart';

import 'installed_release.dart';

/// The running app's version identity (self-hosted OTA app update).
///
/// [buildNumber] is the build code compared against the published manifest;
/// [versionName] is the cosmetic string shown in the UI. Abstract so the update
/// service is unit-testable with a fake — no `package_info_plus` platform
/// channel in tests — and, since the desktop defect below, so the SOURCE of
/// those two facts can differ per platform while everything downstream (the
/// comparison, the screen, the banner) stays shared.
abstract class AppVersionInfo {
  /// The running build's code, or `null` when it is NOT KNOWN.
  ///
  /// `null` is not `0`. A source that answered 0 for "I could not tell" would
  /// make every published release look newer, and the app would offer an update
  /// the user may already be running. Callers must decline to compare instead.
  Future<int?> buildNumber();

  /// The running build's version name, or `''` when it is not known.
  Future<String> versionName();
}

/// [AppVersionInfo] backed by `package_info_plus` — the ANDROID source.
///
/// NOT USED ON DESKTOP, and that is the fix rather than an omission. See
/// [InstalledReleaseAppVersion].
class PackageInfoAppVersion implements AppVersionInfo {
  const PackageInfoAppVersion();

  @override
  Future<int?> buildNumber() async {
    final info = await PackageInfo.fromPlatform();
    // A non-numeric build number is not a build number. Unknown, not 0.
    return int.tryParse(info.buildNumber);
  }

  @override
  Future<String> versionName() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }
}

/// [AppVersionInfo] backed by what the INSTALLER recorded — the DESKTOP source.
///
/// WHY THIS EXISTS. On Linux `package_info_plus` reads
/// `data/flutter_assets/version.json` inside the bundle, and the Flutter Linux
/// build writes pubspec's `+1` into that file regardless of the
/// `--build-number` `tools/publish-linux-to-vps.sh` passes. Measured on the
/// user's laptop with release 795 installed:
///
///   $ cat /opt/lifeos/current/bundle/data/flutter_assets/version.json
///   {"app_name":"lifeos","version":"0.9.19","build_number":"1", …}
///
/// So the desktop app reported build 1 forever, `1 < 795` was true forever, and
/// the Updates screen offered — right after a successful update — an update the
/// user already had. `/opt/lifeos/manifest.json`, written by
/// `tools/install-linux.sh` from the release it actually staged, is the only
/// record on that machine that tracks reality; [InstalledReleaseReader] already
/// reads it (and the `current` symlink) for the update-outcome watcher.
///
/// Android is untouched: its `versionCode` comes through correctly and keeps
/// coming from [PackageInfoAppVersion].
class InstalledReleaseAppVersion implements AppVersionInfo {
  const InstalledReleaseAppVersion(this._reader);

  final InstalledReleaseReader _reader;

  /// Read per question rather than cached: the systemd updater rewrites the
  /// manifest while this process is running, so a value cached at startup would
  /// go stale exactly when it matters — right after an update lands.
  Future<InstalledRelease?> _read() async {
    try {
      return await _reader.read();
    } catch (_) {
      // Unreadable is unknown. It is NEVER the package_info_plus value, which
      // on this platform is known-wrong.
      return null;
    }
  }

  @override
  Future<int?> buildNumber() async => (await _read())?.versionCode;

  @override
  Future<String> versionName() async => (await _read())?.versionName ?? '';
}
