import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/launch/launch_options.dart';
import 'package:lifeos/features/autostart/data/autostart_file_system.dart';
import 'package:lifeos/features/autostart/data/xdg_login_autostart.dart';
import 'package:lifeos/features/autostart/domain/autostart_entry.dart';
import 'package:lifeos/features/autostart/domain/login_autostart.dart';

/// The Linux implementation, exercised entirely against an in-memory file
/// system: the suite runs on the developer's real Linux box, and a test that
/// wrote `~/.config/autostart/lifeos.desktop` would register the test runner
/// to start at his login.
class _FakeFileSystem implements AutostartFileSystem {
  _FakeFileSystem({Map<String, String>? files})
      : files = {...?files};

  final Map<String, String> files;
  final List<String> createdDirectories = [];

  /// Set to make the next write throw, standing in for a read-only home or a
  /// full disk.
  Object? writeError;

  /// Set to make the write silently not stick — the nastiest real failure,
  /// and the one the read-back guard exists for.
  bool swallowWrites = false;

  Object? deleteError;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<String> readAsString(String path) async {
    final content = files[path];
    if (content == null) {
      throw StateError('no such file: $path');
    }
    return content;
  }

  @override
  Future<void> writeAsString(String path, String contents) async {
    final error = writeError;
    if (error != null) throw error;
    if (swallowWrites) return;
    files[path] = contents;
  }

  @override
  Future<void> delete(String path) async {
    final error = deleteError;
    if (error != null) throw error;
    files.remove(path);
  }

  @override
  Future<void> createDirectory(String path) async {
    createdDirectories.add(path);
  }
}

void main() {
  const entryPath = '/home/h/.config/autostart/lifeos.desktop';
  const stableExec = '/opt/lifeos/current/bundle/lifeos';

  XdgLoginAutostart build(
    AutostartFileSystem fs, {
    String Function()? resolveExecutable,
  }) =>
      XdgLoginAutostart(
        fileSystem: fs,
        entryPath: entryPath,
        resolveExecutablePath:
            resolveExecutable ?? () => stableExec,
      );

  group('isEnabled — the REAL state, not the remembered one', () {
    test('no file means off', () async {
      expect(await build(_FakeFileSystem()).isEnabled(), isFalse);
    });

    test('our own entry means on', () async {
      final fs = _FakeFileSystem(files: {
        entryPath: buildXdgAutostartEntry(
          execPath: stableExec,
          arguments: const [hiddenLaunchFlag],
        ),
      });
      expect(await build(fs).isEnabled(), isTrue);
    });

    test('a file the user disabled by hand reads as off', () async {
      // The user can delete this file, or GNOME Tweaks can set Hidden=true.
      // The stored preference is NOT the truth; the disk is.
      final fs = _FakeFileSystem(files: {
        entryPath: '[Desktop Entry]\nType=Application\nHidden=true\n',
      });
      expect(await build(fs).isEnabled(), isFalse);
    });

    test('an unreadable file FAILS LOUDLY rather than reporting off', () async {
      // "Off" would be a lie the user acts on: he would flip the switch, we
      // would overwrite whatever is there, and nobody would ever learn the
      // directory was broken.
      final fs = _UnreadableFileSystem(entryPath);
      await expectLater(
        build(fs).isEnabled(),
        throwsA(isA<LoginAutostartUnavailableException>()),
      );
    });
  });

  group('setEnabled(true)', () {
    test('creates the directory and writes a stable, hidden entry', () async {
      final fs = _FakeFileSystem();
      await build(fs).setEnabled(true);

      expect(fs.createdDirectories, contains('/home/h/.config/autostart'));
      final written = fs.files[entryPath]!;
      expect(written, contains('Exec=$stableExec $hiddenLaunchFlag'));
      expect(entryContainsVersionedPath(written), isFalse);
      expect(await build(fs).isEnabled(), isTrue);
    });

    test('replaces a previously disabled entry rather than leaving it off',
        () async {
      final fs = _FakeFileSystem(files: {
        entryPath: '[Desktop Entry]\nType=Application\nHidden=true\n',
      });
      await build(fs).setEnabled(true);
      expect(await build(fs).isEnabled(), isTrue);
    });

    test('a refused write is reported, never swallowed', () async {
      final fs = _FakeFileSystem()..writeError = StateError('read-only home');
      await expectLater(
        build(fs).setEnabled(true),
        throwsA(isA<LoginAutostartUnavailableException>()),
      );
    });

    test('a write that does not stick is caught by reading it back', () async {
      // Silent success is the cardinal sin here: the switch would sit ON and
      // the app would never start at login, with nothing to explain it.
      final fs = _FakeFileSystem()..swallowWrites = true;
      await expectLater(
        build(fs).setEnabled(true),
        throwsA(isA<LoginAutostartUnavailableException>()),
      );
    });

    test('a dev build refuses instead of writing a build-directory path',
        () async {
      final fs = _FakeFileSystem();
      final autostart = build(
        fs,
        resolveExecutable: () => throw const LoginAutostartUnavailableException(
          'not an installed copy',
        ),
      );
      await expectLater(
        autostart.setEnabled(true),
        throwsA(isA<LoginAutostartUnavailableException>()),
      );
      expect(fs.files, isEmpty);
    });
  });

  group('setEnabled(false)', () {
    test('removes the entry', () async {
      final fs = _FakeFileSystem();
      final autostart = build(fs);
      await autostart.setEnabled(true);
      await autostart.setEnabled(false);

      expect(fs.files.containsKey(entryPath), isFalse);
      expect(await autostart.isEnabled(), isFalse);
    });

    test('turning off something already off is not an error', () async {
      await build(_FakeFileSystem()).setEnabled(false);
    });

    test('a refused delete is reported', () async {
      final fs = _FakeFileSystem(files: {entryPath: '[Desktop Entry]\n'})
        ..deleteError = StateError('permission denied');
      await expectLater(
        build(fs).setEnabled(false),
        throwsA(isA<LoginAutostartUnavailableException>()),
      );
    });
  });
}

/// A file system where the entry exists but cannot be read.
class _UnreadableFileSystem implements AutostartFileSystem {
  _UnreadableFileSystem(this.path);

  final String path;

  @override
  Future<bool> exists(String p) async => p == path;

  @override
  Future<String> readAsString(String p) async =>
      throw StateError('permission denied');

  @override
  Future<void> writeAsString(String p, String contents) async {}

  @override
  Future<void> delete(String p) async {}

  @override
  Future<void> createDirectory(String p) async {}
}
