import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Single source of truth for where sealed voice notes live DURABLY:
/// `<applicationSupportDirectory>/voice_notes/`. The OS temp directory — where
/// recordings used to be sealed beside themselves — is wiped on reboot (tmpfs)
/// and purged on a timer (systemd-tmpfiles `10d`), silently destroying user
/// notes. The application-support directory survives both.
///
/// Injectable via [directoryProvider] so tests control the location without a
/// path_provider platform channel — the same pattern as `FileOutbox`
/// (`core/outbox/outbox.dart`) and `FileResponseCache`
/// (`core/cache/response_cache.dart`).
class VoiceNoteDirectory {
  VoiceNoteDirectory({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  static const _subdir = 'voice_notes';

  /// Creates the durable directory when missing and returns it.
  Future<Directory> resolve() async {
    final base = await _directoryProvider();
    final directory = Directory('${base.path}/$_subdir');
    await directory.create(recursive: true);
    return directory;
  }
}
