/// The filesystem seam for the autostart entry.
///
/// Small on purpose. The suite runs on the developer's real Linux box, so a
/// test that touched the true `~/.config/autostart/` would register the test
/// runner to start at his login — a bug that only shows up at the next reboot.
/// Everything above this interface is therefore tested against an in-memory
/// map, and this file is the only part that cannot be.
library;

import 'dart:io';

abstract class AutostartFileSystem {
  Future<bool> exists(String path);
  Future<String> readAsString(String path);
  Future<void> writeAsString(String path, String contents);
  Future<void> delete(String path);
  Future<void> createDirectory(String path);
}

class IoAutostartFileSystem implements AutostartFileSystem {
  const IoAutostartFileSystem();

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<String> readAsString(String path) => File(path).readAsString();

  /// Writes IN PLACE rather than via a temporary file and a rename.
  ///
  /// The usual reason to prefer rename — atomicity — does not apply and its
  /// cost does: nothing in this process holds the file open, and the only
  /// reader is the desktop session's autostart scan, which happens once at
  /// login and re-opens the path by name. A rename would also change the
  /// inode, which some desktop environments' file watchers handle badly.
  @override
  Future<void> writeAsString(String path, String contents) async {
    await File(path).writeAsString(contents, flush: true);
  }

  @override
  Future<void> delete(String path) => File(path).delete();

  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }
}
