import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/autostart/domain/autostart_mechanism.dart';

/// Platform dispatch for "start at login", in the same shape as
/// `features/app_update/domain/update_manifest_path.dart`: the decision takes
/// the operating-system NAME as a parameter and answers `null` where the
/// capability does not exist, so a Linux host can assert what the macOS and
/// Windows builds WILL do long before those runners exist.
void main() {
  group('autostartMechanismFor', () {
    test('Linux uses an XDG autostart desktop entry', () {
      expect(
        autostartMechanismFor('linux'),
        AutostartMechanism.xdgDesktopEntry,
      );
    });

    test('macOS uses a per-user LaunchAgent plist', () {
      expect(
        autostartMechanismFor('macos'),
        AutostartMechanism.launchAgentPlist,
      );
    });

    test('Windows uses the per-user Run registry key', () {
      expect(
        autostartMechanismFor('windows'),
        AutostartMechanism.runRegistryValue,
      );
    });

    test('the phones and the browser have no login at all', () {
      for (final os in const ['android', 'ios', 'web', 'fuchsia', 'plan9']) {
        expect(autostartMechanismFor(os), isNull, reason: os);
      }
    });
  });

  group('supportsLoginAutostart', () {
    test('is exactly "a mechanism exists"', () {
      for (final os in const [
        'linux',
        'macos',
        'windows',
        'android',
        'ios',
        'web',
      ]) {
        expect(
          supportsLoginAutostart(os),
          autostartMechanismFor(os) != null,
          reason: os,
        );
      }
    });
  });

  group('isImplementedOn — what actually ships today', () {
    test('only Linux is wired; macOS and Windows await their runners', () {
      // This repo has no `macos/` or `windows/` runner, so those mechanisms
      // are DESIGNED but not reachable. Saying so in code (and failing loudly
      // at the seam) beats a toggle that appears to work and does nothing.
      expect(loginAutostartIsImplementedOn('linux'), isTrue);
      expect(loginAutostartIsImplementedOn('macos'), isFalse);
      expect(loginAutostartIsImplementedOn('windows'), isFalse);
      expect(loginAutostartIsImplementedOn('android'), isFalse);
    });
  });

  group('per-platform locations', () {
    test('Linux honours XDG_CONFIG_HOME, and falls back to ~/.config', () {
      expect(
        xdgAutostartEntryPath(home: '/home/hector'),
        '/home/hector/.config/autostart/lifeos.desktop',
      );
      expect(
        xdgAutostartEntryPath(home: '/home/hector', xdgConfigHome: '/cfg'),
        '/cfg/autostart/lifeos.desktop',
      );
      // An empty XDG_CONFIG_HOME is "unset" per the spec, not a path of "".
      expect(
        xdgAutostartEntryPath(home: '/home/hector', xdgConfigHome: ''),
        '/home/hector/.config/autostart/lifeos.desktop',
      );
      // A RELATIVE XDG_CONFIG_HOME is invalid per the spec and must be
      // ignored, not joined into something that lands in the process's cwd.
      expect(
        xdgAutostartEntryPath(home: '/home/hector', xdgConfigHome: 'relative'),
        '/home/hector/.config/autostart/lifeos.desktop',
      );
    });

    test('macOS lands in the user LaunchAgents directory, under the app id',
        () {
      expect(
        macosLaunchAgentPlistPath(home: '/Users/hector'),
        '/Users/hector/Library/LaunchAgents/com.lifeos.lifeos.plist',
      );
    });

    test('Windows names the HKCU Run value, never HKLM', () {
      // HKLM would be machine-wide and need administrator rights. The whole
      // point of this feature is that the app can flip it itself, unprivileged.
      expect(windowsRunRegistryKey, startsWith(r'HKEY_CURRENT_USER\'));
      expect(
        windowsRunRegistryKey,
        r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run',
      );
      expect(windowsRunValueName, 'LifeOS');
    });
  });
}
