// Proves the platform-capability predicates route by OS NAME, so a Linux host
// test can assert what the ANDROID build does. Android carries the user's real
// data — every "hide this on desktop" decision must be provably inert there.
//
// Product rule under test (the user's words): "ocultar las cosas que no
// podamos hacer en Linux o Pixel. Así cada uno tiene sus superpoderes." A
// capability the platform does not have is ABSENT, not disabled.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/app_platform.dart';

void main() {
  group('isDesktopPlatform', () {
    test('the three desktop shells are desktop', () {
      expect(isDesktopPlatform('linux'), isTrue);
      expect(isDesktopPlatform('macos'), isTrue);
      expect(isDesktopPlatform('windows'), isTrue);
    });

    test('the phones and the browser are not', () {
      expect(isDesktopPlatform('android'), isFalse);
      expect(isDesktopPlatform('ios'), isFalse);
      expect(isDesktopPlatform('web'), isFalse);
      expect(isDesktopPlatform('fuchsia'), isFalse);
      expect(isDesktopPlatform('something-new'), isFalse);
    });
  });

  group('supportsDefaultAssistantRole', () {
    // ACTION_ASSIST / "default digital assistant" is an Android role. Linux has
    // no such concept at all, so the Settings row is hidden, not reworded.
    test('only Android has a default-assistant role', () {
      expect(supportsDefaultAssistantRole('android'), isTrue);
    });

    test('desktop and the rest do not', () {
      expect(supportsDefaultAssistantRole('linux'), isFalse);
      expect(supportsDefaultAssistantRole('macos'), isFalse);
      expect(supportsDefaultAssistantRole('windows'), isFalse);
      expect(supportsDefaultAssistantRole('ios'), isFalse);
      expect(supportsDefaultAssistantRole('web'), isFalse);
      expect(supportsDefaultAssistantRole('unknown'), isFalse);
    });
  });

  group('supportsRuntimePermissionPrompts', () {
    // permission_handler ships android/ios only. On Linux every permission
    // resolves to "No disponible", so the whole surface is noise.
    test('the mobile OSes prompt for permissions at runtime', () {
      expect(supportsRuntimePermissionPrompts('android'), isTrue);
      expect(supportsRuntimePermissionPrompts('ios'), isTrue);
    });

    test('desktop and web do not', () {
      expect(supportsRuntimePermissionPrompts('linux'), isFalse);
      expect(supportsRuntimePermissionPrompts('macos'), isFalse);
      expect(supportsRuntimePermissionPrompts('windows'), isFalse);
      expect(supportsRuntimePermissionPrompts('web'), isFalse);
      expect(supportsRuntimePermissionPrompts('unknown'), isFalse);
    });
  });

  group('supportsSideloadedApkInstall', () {
    // REQUEST_INSTALL_PACKAGES only means something where the updater is an
    // APK. The Linux updater is a systemd timer + service.
    test('only Android sideloads an APK', () {
      expect(supportsSideloadedApkInstall('android'), isTrue);
    });

    test('every other platform updates some other way', () {
      expect(supportsSideloadedApkInstall('linux'), isFalse);
      expect(supportsSideloadedApkInstall('macos'), isFalse);
      expect(supportsSideloadedApkInstall('windows'), isFalse);
      expect(supportsSideloadedApkInstall('ios'), isFalse);
      expect(supportsSideloadedApkInstall('web'), isFalse);
    });
  });

  group('supportsDictation', () {
    // The Dictar button needs a microphone AND the sherpa-onnx Whisper
    // runtime. Both exist on the phones and on the three desktop shells; a
    // browser build has neither the plugin nor the model store.
    test('every native shell can dictate', () {
      expect(supportsDictation('android'), isTrue);
      expect(supportsDictation('ios'), isTrue);
      expect(supportsDictation('linux'), isTrue);
      expect(supportsDictation('macos'), isTrue);
      expect(supportsDictation('windows'), isTrue);
    });

    test('the browser build cannot, and an unknown platform is not assumed to',
        () {
      expect(supportsDictation('web'), isFalse);
      expect(supportsDictation('fuchsia'), isFalse);
      expect(supportsDictation('something-new'), isFalse);
    });
  });

  group('currentOperatingSystem', () {
    test('reports a non-empty OS name for the host running the suite', () {
      // The suite runs on Linux here, but asserting the literal would make the
      // test a CI-host assertion rather than a contract one.
      expect(currentOperatingSystem(), isNotEmpty);
    });
  });
}
