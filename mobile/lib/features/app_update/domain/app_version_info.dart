import 'package:package_info_plus/package_info_plus.dart';

/// The running app's version identity (self-hosted OTA app update).
///
/// [buildNumber] is the Android `versionCode` compared against the engine
/// manifest; [versionName] is the cosmetic string shown in the UI. Abstract
/// so the update service is unit-testable with a fake — no `package_info_plus`
/// platform channel in tests.
abstract class AppVersionInfo {
  /// The running build's `versionCode` (pubspec `+N`).
  Future<int> buildNumber();

  /// The running build's version name (pubspec `x.y.z`).
  Future<String> versionName();
}

/// [AppVersionInfo] backed by `package_info_plus`.
///
/// `PackageInfo.buildNumber` is a [String] on every platform; it is parsed to
/// an int, falling back to `0` if the platform ever reports a non-numeric
/// build number (so a comparison degrades to "everything looks newer" rather
/// than throwing).
class PackageInfoAppVersion implements AppVersionInfo {
  const PackageInfoAppVersion();

  @override
  Future<int> buildNumber() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  @override
  Future<String> versionName() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }
}
