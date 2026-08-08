// What is REALLY installed in /opt/lifeos, read from the machine.
//
// The desktop updater runs as root in another process, so the only way the app
// can tell an update apart from a request that went nowhere is to look at what
// the installer left behind. `tools/install-linux.sh` writes exactly two
// durable facts: `$PREFIX/manifest.json` (the published manifest, copied
// verbatim, mode 0644 = world readable) and `$PREFIX/current`, a symlink to
// `releases/<versionCode>`.
//
// Both are parsed here, manifest first, because the symlink alone cannot name
// the version the user sees.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/installed_release.dart';

void main() {
  group('parseInstalledReleaseManifest', () {
    test('reads versionCode + versionName from the installer state manifest',
        () {
      // Byte-for-byte the shape install-linux.sh copies to /opt/lifeos.
      const json = '''
{
  "versionCode": 793,
  "versionName": "0.9.21",
  "filename": "lifeos-linux-x64-0.9.21-793.tar.gz",
  "sha256": "abc",
  "sizeBytes": 57384190,
  "arch": "x64",
  "platform": "linux"
}
''';

      final release = parseInstalledReleaseManifest(json);

      expect(release, isNotNull);
      expect(release!.versionCode, 793);
      expect(release.versionName, '0.9.21');
    });

    test('returns null rather than a wrong answer on unusable JSON', () {
      // A truncated or HTML error page must never read as "version 0
      // installed" — that would make the watcher call any later read an
      // upgrade.
      expect(parseInstalledReleaseManifest('<html>nope</html>'), isNull);
      expect(parseInstalledReleaseManifest('{}'), isNull);
      expect(parseInstalledReleaseManifest('{"versionCode": "x"}'), isNull);
    });
  });

  group('versionCodeFromReleaseLink', () {
    test('recovers the versionCode from the `current` symlink target', () {
      expect(versionCodeFromReleaseLink('/opt/lifeos/releases/793'), 793);
    });

    test('answers null for anything that is not a release directory', () {
      expect(versionCodeFromReleaseLink('/opt/lifeos/releases/staging'), isNull);
      expect(versionCodeFromReleaseLink(''), isNull);
    });
  });

  group('OptLifeosInstalledReleaseReader', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lifeos-installed-release');
    });
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('reads the manifest when it is there', () async {
      final manifest = File('${dir.path}/manifest.json');
      await manifest.writeAsString(
        jsonEncode({'versionCode': 793, 'versionName': '0.9.21'}),
      );
      final reader = OptLifeosInstalledReleaseReader(
        manifestPath: manifest.path,
        currentLinkPath: '${dir.path}/current',
      );

      final release = await reader.read();

      expect(release?.versionCode, 793);
      expect(release?.versionName, '0.9.21');
    });

    test('falls back to the `current` symlink when the manifest is unreadable',
        () async {
      // The versionCode is the fact the watcher needs; the name is unknown and
      // is reported as unknown rather than invented.
      await Directory('${dir.path}/releases/793').create(recursive: true);
      final link = Link('${dir.path}/current');
      await link.create('${dir.path}/releases/793');
      final reader = OptLifeosInstalledReleaseReader(
        manifestPath: '${dir.path}/manifest.json', // does not exist
        currentLinkPath: link.path,
      );

      final release = await reader.read();

      expect(release?.versionCode, 793);
      expect(release?.versionName, isEmpty);
    });

    test('answers null when nothing on disk can be read', () async {
      final reader = OptLifeosInstalledReleaseReader(
        manifestPath: '${dir.path}/manifest.json',
        currentLinkPath: '${dir.path}/current',
      );

      expect(await reader.read(), isNull);
    });

    test('the production paths are the ones install-linux.sh maintains', () {
      // Pinned rather than commented: these two strings are a contract with
      // the installer, and a rename there must break a test here.
      expect(OptLifeosInstalledReleaseReader.defaultManifestPath,
          '/opt/lifeos/manifest.json');
      expect(OptLifeosInstalledReleaseReader.defaultCurrentLinkPath,
          '/opt/lifeos/current');
    });
  });
}
