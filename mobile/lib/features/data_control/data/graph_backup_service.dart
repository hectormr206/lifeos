import 'dart:io';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../domain/backup_info.dart';

/// On-device backups of the encrypted graph DB (data-control kit, part A).
///
/// MECHANISM — `VACUUM INTO`, not close-copy-reopen. SQLite (≥3.27, and the
/// SQLCipher build sqflite_sqlcipher ships) writes a transactionally
/// CONSISTENT, compacted copy of the live database to a new file, without
/// closing the source. On SQLCipher the copy keeps the source's encryption,
/// so a backup file is exactly as protected at rest as the live DB. This
/// avoids the close→copy→reopen dance (and the window where a half-open app
/// could write mid-copy). The sqflite ffi backend supports it too, so the
/// same code path is what the host tests exercise.
///
/// Backups contain USER DATA ONLY (the graph DB: nodes/edges/vectors/chat/
/// reminders/facts). NOT covered: shared_preferences (briefing/schedule/UI
/// prefs) and voice-note .wav files — documented limitation of this slice.
///
/// RESTORE is REVERSIBLE: before replacing the live file, the CURRENT state
/// is snapshotted as a [BackupKind.preRestore] backup that shows up in the
/// list, so the user can restore it to "regresar a los datos actuales".
class GraphBackupService {
  GraphBackupService({
    required this._database,
    required this._databasePath,
    required this._backupsRoot,
    required this._suspendDatabase,
    required this._resumeDatabase,
    DateTime Function()? clock,
    this.autoRetention = 5,
  }) : _now = clock ?? DateTime.now;

  /// Resolves the OPEN live DB handle (opens it if needed).
  final Future<Database> Function() _database;

  /// Absolute path of the live DB file.
  final Future<String> Function() _databasePath;

  /// Root directory holding `auto/` and `manual/` backup subdirectories.
  final Future<Directory> Function() _backupsRoot;

  /// Closes the live handle so the file can be replaced (restore only).
  final Future<void> Function() _suspendDatabase;

  /// Signals the app to lazily re-open the DB (restore only) — in production
  /// this invalidates `graphDatabaseHandleProvider`.
  final void Function() _resumeDatabase;

  final DateTime Function() _now;

  /// How many AUTOMATIC backups are kept; the oldest rotate out so storage
  /// never balloons. Manual + pre-restore backups are never auto-deleted.
  final int autoRetention;

  static final RegExp _fileNamePattern = RegExp(
    r'^graph-(auto|manual|prerestore)-(\d+)\.db$',
  );

  static String _tag(BackupKind kind) => switch (kind) {
    BackupKind.auto => 'auto',
    BackupKind.manual => 'manual',
    BackupKind.preRestore => 'prerestore',
  };

  static BackupKind? _kindOf(String tag) => switch (tag) {
    'auto' => BackupKind.auto,
    'manual' => BackupKind.manual,
    'prerestore' => BackupKind.preRestore,
    _ => null,
  };

  Future<Directory> _dirFor(BackupKind kind) async {
    final root = await _backupsRoot();
    final sub = kind == BackupKind.auto ? 'auto' : 'manual';
    return Directory('${root.path}/$sub').create(recursive: true);
  }

  /// Create a consistent backup of the live DB. Automatic backups are
  /// retention-rotated right after creation.
  Future<BackupInfo> createBackup({required BackupKind kind}) async {
    final db = await _database();
    final dir = await _dirFor(kind);
    final createdAt = _now();
    final path =
        '${dir.path}/graph-${_tag(kind)}-${createdAt.millisecondsSinceEpoch}.db';
    // Consistent snapshot of the live (still-open) database; see class doc.
    await db.execute('VACUUM INTO ?', [path]);
    if (kind == BackupKind.auto) await _rotateAuto();
    final size = await File(path).length();
    return BackupInfo(
      path: path,
      kind: kind,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdAt.millisecondsSinceEpoch,
      ),
      sizeBytes: size,
    );
  }

  /// Lands an archive that came from OUTSIDE this device (downloaded from the
  /// user's server and already decrypted) as an ordinary manual backup.
  ///
  /// It deliberately stops there rather than restoring: the existing restore
  /// flow snapshots the CURRENT data before overwriting, so routing an
  /// imported archive through it keeps the operation reversible. Writing the
  /// live database directly from a download would not be.
  ///
  /// Written to a temporary file and renamed into place, so an interrupted
  /// import never leaves a truncated file that looks like a whole backup.
  Future<BackupInfo> importArchive(
    List<int> bytes, {
    required String name,
  }) async {
    final dir = await _dirFor(BackupKind.manual);
    final createdAt = _now();
    final path =
        '${dir.path}/graph-imported-${createdAt.millisecondsSinceEpoch}.db';
    final temporary = File('$path.part');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(path);
    return BackupInfo(
      path: path,
      kind: BackupKind.manual,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdAt.millisecondsSinceEpoch,
      ),
      sizeBytes: bytes.length,
    );
  }

  /// Daily automatic backup: create one if none exists for TODAY yet.
  /// Returns true when a backup was created. Called fire-and-forget on app
  /// open; the caller swallows failures (a backup must never block startup).
  Future<bool> maybeAutoBackup() async {
    final today = _now();
    final existing = await list();
    final hasToday = existing.any(
      (b) =>
          b.kind == BackupKind.auto &&
          b.createdAt.year == today.year &&
          b.createdAt.month == today.month &&
          b.createdAt.day == today.day,
    );
    if (hasToday) return false;
    await createBackup(kind: BackupKind.auto);
    return true;
  }

  /// Every backup on disk, newest first.
  Future<List<BackupInfo>> list() async {
    final root = await _backupsRoot();
    final backups = <BackupInfo>[];
    for (final sub in const ['auto', 'manual']) {
      final dir = Directory('${root.path}/$sub');
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        final match = _fileNamePattern.firstMatch(entry.path.split('/').last);
        if (match == null) continue;
        final kind = _kindOf(match.group(1)!);
        if (kind == null) continue;
        backups.add(
          BackupInfo(
            path: entry.path,
            kind: kind,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              int.parse(match.group(2)!),
            ),
            sizeBytes: await entry.length(),
          ),
        );
      }
    }
    backups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return backups;
  }

  /// Delete one backup file (manual list management). Safe if already gone.
  Future<void> deleteBackup(BackupInfo backup) async {
    final file = File(backup.path);
    if (await file.exists()) await file.delete();
  }

  /// Restore [backup] over the live database — REVERSIBLY.
  ///
  ///  1. Snapshot the CURRENT data as a pre-restore backup (shows in the list).
  ///  2. Close the live handle.
  ///  3. Copy the backup file over the live path; drop stale `-wal`/`-shm`/
  ///     `-journal` sidecars so SQLite never mixes the old WAL into the
  ///     restored file.
  ///  4. Ask the app to re-open lazily (guarded migration path included — a
  ///     backup written by a NEWER schema is refused, never destroyed).
  ///
  /// Returns the pre-restore snapshot so the UI can point at the way back.
  Future<BackupInfo> restoreBackup(BackupInfo backup) async {
    if (!await File(backup.path).exists()) {
      throw StateError('Backup file no longer exists: ${backup.path}');
    }
    final preRestore = await createBackup(kind: BackupKind.preRestore);
    await _suspendDatabase();
    final dbPath = await _databasePath();
    await File(backup.path).copy(dbPath);
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final sidecar = File('$dbPath$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
    _resumeDatabase();
    return preRestore;
  }

  /// Keep only the newest [autoRetention] automatic backups.
  Future<void> _rotateAuto() async {
    final autos = (await list())
        .where((b) => b.kind == BackupKind.auto)
        .toList();
    for (final stale in autos.skip(autoRetention)) {
      await deleteBackup(stale);
    }
  }
}
