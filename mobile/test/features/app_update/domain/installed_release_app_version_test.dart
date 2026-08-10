// The desktop answer to "which build am I running": the installer's manifest,
// not the bundle's version.json.
//
// `package_info_plus` reads `data/flutter_assets/version.json`, and the Flutter
// Linux build writes pubspec's `+1` there no matter what `--build-number` the
// publish script passes. `/opt/lifeos/manifest.json` is written by
// `tools/install-linux.sh` from the release that was actually staged, so it is
// the only record on the machine that tracks what is installed.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/app_version_info.dart';
import 'package:lifeos/features/app_update/domain/installed_release.dart';

import '../support/fakes.dart';

class _ThrowingReader implements InstalledReleaseReader {
  @override
  Future<InstalledRelease?> read() async => throw const FileSystemExceptionLike();
}

class FileSystemExceptionLike implements Exception {
  const FileSystemExceptionLike();
}

void main() {
  group('InstalledReleaseAppVersion', () {
    test('reports the versionCode and versionName the installer recorded', () async {
      final version = InstalledReleaseAppVersion(FakeInstalledReleaseReader(
          const InstalledRelease(versionCode: 795, versionName: '0.9.19')));

      expect(await version.buildNumber(), 795);
      expect(await version.versionName(), '0.9.19');
    });

    test('reports an UNKNOWN build when nothing on disk is readable', () async {
      // Not 0, and above all not the package_info_plus value: that one is
      // known-wrong on this platform, and falling back to it is what made the
      // app nag about an update it had already installed.
      final version = InstalledReleaseAppVersion(FakeInstalledReleaseReader(null));

      expect(await version.buildNumber(), isNull);
      expect(await version.versionName(), isEmpty);
    });

    test('reports UNKNOWN rather than throwing when the read blows up', () async {
      final version = InstalledReleaseAppVersion(_ThrowingReader());

      expect(await version.buildNumber(), isNull);
      expect(await version.versionName(), isEmpty);
    });

    test('reads the disk once per question, so a fresh install is seen', () async {
      // The reader is cheap and the answer changes under us: the systemd
      // updater rewrites the manifest while this process is running.
      final reader = FakeInstalledReleaseReader(
          const InstalledRelease(versionCode: 795, versionName: '0.9.19'));
      final version = InstalledReleaseAppVersion(reader);
      expect(await version.buildNumber(), 795);

      reader.release = const InstalledRelease(versionCode: 800, versionName: '0.9.20');

      expect(await version.buildNumber(), 800);
    });
  });

  group('parseInstalledReleaseManifest, as the version source relies on it', () {
    test('a malformed versionCode reads as unknown, never as a number', () async {
      // Whatever wrote "795" as a string, or as null, or as -1, did not tell us
      // which build is installed. Guessing here would be the same lie one level
      // down.
      for (final bad in <Object?>['795', null, -1, 0, 1.5, <String>[]]) {
        final version = InstalledReleaseAppVersion(FakeInstalledReleaseReader(
            parseInstalledReleaseManifest('{"versionCode": ${_json(bad)}}')));
        expect(await version.buildNumber(), isNull, reason: 'versionCode: $bad');
      }
    });
  });
}

String _json(Object? value) => switch (value) {
      null => 'null',
      final String s => '"$s"',
      final List<String> _ => '[]',
      _ => '$value',
    };
