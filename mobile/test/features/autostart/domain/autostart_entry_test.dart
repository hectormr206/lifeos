import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/launch/launch_options.dart';
import 'package:lifeos/features/autostart/domain/autostart_entry.dart';

/// The generated login entries, and the ONE rule that outranks all of them:
/// the command must point at a path that survives an update.
///
/// `tools/install-linux.sh` already installs the applications-menu entry with
/// `Exec=$CURRENT_LINK/bundle/lifeos %U` and says in a comment why: it points
/// at the `current` symlink so the entry keeps working across upgrades. An
/// autostart entry that pointed at `/opt/lifeos/releases/<version>/…` instead
/// would be pruned out from under the user by the next OTA update, and LifeOS
/// would simply stop starting one day with nothing logged anywhere.
void main() {
  group('buildXdgAutostartEntry', () {
    const stableExec = '/opt/lifeos/current/bundle/lifeos';

    test('is a valid autostart desktop entry', () {
      final entry = buildXdgAutostartEntry(
        execPath: stableExec,
        arguments: const [hiddenLaunchFlag],
      );

      expect(entry, startsWith('[Desktop Entry]\n'));
      expect(entry, contains('Type=Application'));
      expect(entry, contains('Name=LifeOS'));
      expect(entry, contains('Terminal=false'));
      // Without this the entry is inert in GNOME/KDE.
      expect(entry, contains('X-GNOME-Autostart-enabled=true'));
      // `Hidden=true` is how the XDG spec says "this entry is switched off".
      // Writing it enabled must never emit it.
      expect(entry, isNot(contains('Hidden=true')));
      expect(entry, endsWith('\n'));
    });

    test('launches hidden, so login does not throw a window at the user', () {
      final entry = buildXdgAutostartEntry(
        execPath: stableExec,
        arguments: const [hiddenLaunchFlag],
      );
      expect(entry, contains('Exec=$stableExec $hiddenLaunchFlag'));
    });

    test('a quoted path stays one argument', () {
      final entry = buildXdgAutostartEntry(
        execPath: '/home/a b/lifeos',
        arguments: const [hiddenLaunchFlag],
      );
      expect(entry, contains('Exec="/home/a b/lifeos" $hiddenLaunchFlag'));
    });

    test('THE RULE: the entry never carries a versioned path', () {
      final entry = buildXdgAutostartEntry(
        execPath: stableExec,
        arguments: const [hiddenLaunchFlag],
      );
      expect(
        entryContainsVersionedPath(entry),
        isFalse,
        reason: 'an entry pointing at a release directory dies on the next '
            'update, silently',
      );
    });

    test('building from a versioned path is refused, not written', () {
      // Belt and braces: the caller already resolves a stable path, but the
      // writer refuses too. This failure is unrecoverable-by-observation —
      // the user would only find out months later — so it must never be
      // reachable by accident.
      expect(
        () => buildXdgAutostartEntry(
          execPath: '/opt/lifeos/releases/10420/bundle/lifeos',
          arguments: const [hiddenLaunchFlag],
        ),
        throwsA(isA<VersionedAutostartPathException>()),
      );
    });
  });

  group('looksLikeVersionedPath', () {
    test('catches the shapes this installer actually produces', () {
      for (final path in const [
        '/opt/lifeos/releases/10420/bundle/lifeos',
        '/opt/lifeos/releases/1.4.2/bundle/lifeos',
        '/opt/lifeos/1.4.2/lifeos',
        '/opt/lifeos/v1.4.2/lifeos',
        '/home/h/Apps/LifeOS-2.0.0/lifeos',
      ]) {
        expect(looksLikeVersionedPath(path), isTrue, reason: path);
      }
    });

    test('leaves genuinely stable paths alone', () {
      for (final path in const [
        '/opt/lifeos/current/bundle/lifeos',
        '/usr/local/bin/lifeos',
        '/usr/bin/lifeos',
        // A digit in a name is not a version; only a whole segment is.
        '/opt/lifeos3/current/bundle/lifeos',
      ]) {
        expect(looksLikeVersionedPath(path), isFalse, reason: path);
      }
    });
  });

  group('xdgEntryIsEnabled — reading the REAL state back', () {
    test('an entry we wrote reads back as enabled', () {
      final entry = buildXdgAutostartEntry(
        execPath: '/opt/lifeos/current/bundle/lifeos',
        arguments: const [hiddenLaunchFlag],
      );
      expect(xdgEntryIsEnabled(entry), isTrue);
    });

    test('Hidden=true means the user switched it off elsewhere', () {
      // GNOME Tweaks and KDE both write `Hidden=true` rather than deleting the
      // file. Reporting that as ON would be a toggle that lies.
      expect(
        xdgEntryIsEnabled('[Desktop Entry]\nType=Application\nHidden=true\n'),
        isFalse,
      );
      expect(
        xdgEntryIsEnabled('[Desktop Entry]\nHidden=TRUE\n'),
        isFalse,
      );
      expect(
        xdgEntryIsEnabled('[Desktop Entry]\nHidden=false\n'),
        isTrue,
      );
    });

    test('X-GNOME-Autostart-enabled=false also means off', () {
      expect(
        xdgEntryIsEnabled(
          '[Desktop Entry]\nX-GNOME-Autostart-enabled=false\n',
        ),
        isFalse,
      );
    });
  });

  group('macOS LaunchAgent plist (designed, not yet wired)', () {
    test('runs the app at load, hidden, under the app id', () {
      final plist = buildMacosLaunchAgentPlist(
        execPath: '/Applications/LifeOS.app/Contents/MacOS/LifeOS',
        arguments: const [hiddenLaunchFlag],
      );

      expect(plist, contains('<key>Label</key>'));
      expect(plist, contains('<string>com.lifeos.lifeos</string>'));
      expect(plist, contains('<key>RunAtLoad</key>'));
      expect(plist, contains('<true/>'));
      expect(
        plist,
        contains('<string>/Applications/LifeOS.app/Contents/MacOS/LifeOS'
            '</string>'),
      );
      expect(plist, contains('<string>$hiddenLaunchFlag</string>'));
      // A LaunchAgent with KeepAlive would resurrect the app the instant the
      // user quits it from the tray menu. That is the opposite of quit.
      expect(plist, isNot(contains('KeepAlive')));
    });

    test('the same version rule applies', () {
      expect(
        () => buildMacosLaunchAgentPlist(
          execPath: '/Applications/LifeOS-1.4.2.app/Contents/MacOS/LifeOS',
          arguments: const [hiddenLaunchFlag],
        ),
        throwsA(isA<VersionedAutostartPathException>()),
      );
    });

    test('the executable path is XML-escaped, not pasted raw', () {
      final plist = buildMacosLaunchAgentPlist(
        execPath: '/Apps/A&B/LifeOS',
        arguments: const [],
      );
      expect(plist, contains('<string>/Apps/A&amp;B/LifeOS</string>'));
    });
  });

  group('Windows Run value (designed, not yet wired)', () {
    test('is the command line the registry value must hold', () {
      final value = buildWindowsRunCommand(
        execPath: r'C:\Program Files\LifeOS\lifeos.exe',
        arguments: const [hiddenLaunchFlag],
      );
      expect(value, r'"C:\Program Files\LifeOS\lifeos.exe" --hidden');
    });

    test('the same version rule applies', () {
      expect(
        () => buildWindowsRunCommand(
          execPath: r'C:\Program Files\LifeOS\1.4.2\lifeos.exe',
          arguments: const [hiddenLaunchFlag],
        ),
        throwsA(isA<VersionedAutostartPathException>()),
      );
    });
  });
}
