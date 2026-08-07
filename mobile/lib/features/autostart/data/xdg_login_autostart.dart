/// The Linux implementation of [LoginAutostart]: an XDG autostart entry in
/// `$XDG_CONFIG_HOME/autostart/`.
///
/// WHY XDG AND NOT A SYSTEMD USER UNIT. Both work. The `.desktop` file wins on
/// the one axis that decides this feature: the app can write it itself, at
/// runtime, unprivileged, with no `systemctl` and no D-Bus round trip — which
/// is what makes the toggle live in Settings instead of in a README. It is
/// also what every desktop environment's own "startup applications" panel
/// reads and writes, so the user can turn it off from GNOME Tweaks and this
/// app will notice.
///
/// WHY NO `launch_at_startup` PACKAGE. It would earn its keep if it were
/// carrying three platforms. It is not: this repo has only a `linux/` runner,
/// and on Linux the package's entire job is the twenty lines below — write a
/// `.desktop` file, check whether it exists, delete it. It would also cost the
/// two things this feature cannot give up: it derives its `Exec` from
/// `Platform.resolvedExecutable`, which on this install is the VERSIONED
/// release path (see `stable_executable.dart`), and its `isEnabled` is a bare
/// existence check that reports a `Hidden=true` entry as ON. Both are exactly
/// the silent-wrong-answer failures this slice exists to prevent, and both
/// would have to be worked around from outside the package.
library;

import 'dart:io';

import '../../../core/launch/launch_options.dart';
import '../domain/autostart_entry.dart';
import '../domain/autostart_mechanism.dart';
import '../domain/login_autostart.dart';
import '../domain/stable_executable.dart';
import 'autostart_file_system.dart';

class XdgLoginAutostart implements LoginAutostart {
  /// The private initializing formals below are named `entryPath:` and
  /// `resolveExecutablePath:` at call sites — Dart drops the leading
  /// underscore, the same trick `TrayService` uses for `createController`.
  XdgLoginAutostart({
    required AutostartFileSystem fileSystem,
    required this._entryPath,
    required this._resolveExecutablePath,
  }) : _fs = fileSystem;

  /// The production instance, bound to this process and this user.
  factory XdgLoginAutostart.forHost({
    AutostartFileSystem fileSystem = const IoAutostartFileSystem(),
  }) {
    final env = Platform.environment;
    final home = env['HOME'];
    if (home == null || home.isEmpty) {
      // No home directory means no per-user config directory to write into.
      // Refusing here — rather than writing to `/autostart/` — keeps the
      // failure legible.
      throw const LoginAutostartUnavailableException(
        'HOME is not set, so LifeOS cannot find your configuration directory '
        'to register itself for login.',
      );
    }
    return XdgLoginAutostart(
      fileSystem: fileSystem,
      entryPath: xdgAutostartEntryPath(
        home: home,
        xdgConfigHome: env['XDG_CONFIG_HOME'],
      ),
      resolveExecutablePath: () => resolveStableExecutablePath(
        runningExecutable: Platform.resolvedExecutable,
        candidates: linuxStableExecutableCandidates,
        resolveRealPath: _resolveIfExists,
      ),
    );
  }

  final AutostartFileSystem _fs;
  final String _entryPath;
  final String Function() _resolveExecutablePath;

  /// The fully-resolved target of [path], or null if it does not exist.
  /// Separate function because `resolveSymbolicLinksSync` THROWS on a dangling
  /// symlink — a leftover `/usr/local/bin/lifeos` after an uninstall — and
  /// that must read as "not a usable candidate", not as a crash.
  static String? _resolveIfExists(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> isEnabled() async {
    if (!await _fs.exists(_entryPath)) return false;
    final String contents;
    try {
      contents = await _fs.readAsString(_entryPath);
    } catch (e) {
      // NOT `return false`. "Off" would be a lie the user acts on: he would
      // flip the switch, we would overwrite whatever is there, and nobody
      // would ever learn the directory was unreadable.
      throw LoginAutostartUnavailableException(
        'LifeOS could not read $_entryPath, so it cannot tell whether it is '
        'set to start at login. Detail: $e',
      );
    }
    return xdgEntryIsEnabled(contents);
  }

  @override
  Future<void> setEnabled(bool enabled) =>
      enabled ? _register() : _unregister();

  Future<void> _register() async {
    // Throws when this is not an installed copy. Deliberately BEFORE any write:
    // a dev build must leave the user's autostart directory untouched.
    final execPath = _resolveExecutablePath();
    final entry = buildXdgAutostartEntry(
      execPath: execPath,
      // The point of the whole flag: log in, get a tray icon, not a window.
      arguments: const [hiddenLaunchFlag],
    );

    try {
      await _fs.createDirectory(xdgAutostartDirectoryOf(_entryPath));
      await _fs.writeAsString(_entryPath, entry);
    } catch (e) {
      throw LoginAutostartUnavailableException(
        'LifeOS could not write $_entryPath, so it will NOT start at login. '
        'Detail: $e',
      );
    }

    // READ BACK. A write that reports success and does not stick is the one
    // failure the user could never diagnose: the switch would sit ON and
    // LifeOS would never start at login. Confirming costs one stat and one
    // read; not confirming costs the user a feature that lies.
    if (!await isEnabled()) {
      throw LoginAutostartUnavailableException(
        'LifeOS wrote $_entryPath but it did not take effect, so it will not '
        'start at login. Check that the directory is writable and not managed '
        'by another tool.',
      );
    }
  }

  Future<void> _unregister() async {
    if (!await _fs.exists(_entryPath)) return;
    try {
      await _fs.delete(_entryPath);
    } catch (e) {
      throw LoginAutostartUnavailableException(
        'LifeOS could not remove $_entryPath, so it will keep starting at '
        'login. Detail: $e',
      );
    }
  }
}
