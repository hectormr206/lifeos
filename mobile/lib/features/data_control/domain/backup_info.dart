/// One on-device backup of the encrypted graph database (data-control kit).
///
/// A backup is a consistent, still-encrypted copy of the SQLCipher DB file —
/// USER DATA ONLY (nodes, edges, vectors, chat history). Model files are never
/// part of a backup. Backups live under the app-support directory:
///   `backups/auto/`   — daily automatic copies (retention-capped),
///   `backups/manual/` — user-created copies + pre-restore snapshots.
library;

/// How a backup came to exist. Encoded in the file name so a listing never
/// needs a sidecar index.
enum BackupKind {
  /// Created automatically (once per day on app open, retention-capped).
  auto,

  /// Created explicitly by the user ("Crear copia ahora").
  manual,

  /// Snapshot of the CURRENT data taken automatically right before a restore,
  /// so a restore is always reversible ("regresar a los datos actuales").
  preRestore,
}

/// Immutable descriptor of one backup file on disk.
class BackupInfo {
  const BackupInfo({
    required this.path,
    required this.kind,
    required this.createdAt,
    required this.sizeBytes,
  });

  /// Absolute path of the backup file.
  final String path;

  final BackupKind kind;

  /// Creation instant, parsed from the file name (stable across file moves).
  final DateTime createdAt;

  final int sizeBytes;

  String get fileName => path.split('/').last;

  bool get isPreRestore => kind == BackupKind.preRestore;

  @override
  String toString() =>
      'BackupInfo(${kind.name}, $createdAt, $sizeBytes B, $path)';

  @override
  bool operator ==(Object other) =>
      other is BackupInfo &&
      other.path == path &&
      other.kind == kind &&
      other.createdAt == createdAt &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(path, kind, createdAt, sizeBytes);
}
