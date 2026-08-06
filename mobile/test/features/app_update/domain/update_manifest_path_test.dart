// The update manifest does not live at one URL for every platform.
//
// Android publishes a single signed APK at `<base>/manifest`. Desktop
// publishes a per-architecture tarball, because the bundle contains compiled
// .so files — handing an arm64 laptop the x64 build gives it something it
// cannot execute. So the desktop manifest is `<base>/linux/x64/manifest.json`,
// exactly where `tools/publish-linux-to-vps.sh` uploads it.
//
// Getting this wrong is not a cosmetic bug: a Linux build asking for
// `/manifest` reads the ANDROID versionCode and would offer to "update" the
// laptop with a phone package.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/update_manifest_path.dart';

void main() {
  test('Android reads the single published APK manifest', () {
    expect(updateManifestPathFor('android', arch: 'x64'), '/manifest');
  });

  test('Linux reads the per-architecture desktop manifest', () {
    expect(
      updateManifestPathFor('linux', arch: 'x64'),
      '/linux/x64/manifest.json',
    );
  });

  test('the architecture is part of the path, not decoration', () {
    // An arm64 laptop must never be pointed at the x64 tarball.
    expect(
      updateManifestPathFor('linux', arch: 'arm64'),
      '/linux/arm64/manifest.json',
    );
  });

  test('macOS and Windows follow the same desktop shape', () {
    expect(updateManifestPathFor('macos', arch: 'arm64'),
        '/macos/arm64/manifest.json');
    expect(updateManifestPathFor('windows', arch: 'x64'),
        '/windows/x64/manifest.json');
  });

  test('an unknown platform has no manifest — it does not guess one', () {
    // Answering with a plausible-looking path would send a future shell to a
    // URL nobody has ever published to, and it would look like a server fault.
    expect(updateManifestPathFor('web', arch: 'x64'), isNull);
    expect(updateManifestPathFor('fuchsia', arch: 'x64'), isNull);
  });

  test('the architecture name matches what the publisher uploads', () {
    // publish-linux-to-vps.sh maps uname -m to exactly these two.
    expect(updateArchFor('x86_64'), 'x64');
    expect(updateArchFor('amd64'), 'x64');
    expect(updateArchFor('aarch64'), 'arm64');
    expect(updateArchFor('arm64'), 'arm64');
  });

  test('the already-published name maps to itself', () {
    // The host probe reports 'x64' directly; feeding it back through must not
    // suddenly mean "unknown architecture" and disable updates.
    expect(updateArchFor('x64'), 'x64');
    expect(updateArchFor('arm64'), 'arm64');
  });

  test('an unrecognised CPU yields no arch rather than a wrong one', () {
    expect(updateArchFor('riscv64'), isNull);
  });
}
