import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'graph_key_store.dart';
import 'local_graph_migrations.dart';
import 'local_graph_schema.dart';

/// Opens the encrypted on-device graph database (roadmap SLICE A2).
///
/// Encryption at rest is provided by SQLCipher (via `sqflite_sqlcipher`): the
/// entire DB file is AES-256 encrypted with a per-install key held in the OS
/// keystore through [GraphKeyStore]. The file is unreadable without the key —
/// there is no plaintext-fallback path.
///
/// The key is passed as `password`; `sqflite_sqlcipher` issues the
/// corresponding `PRAGMA key` on open. Because the key is already 64 hex chars
/// (32 raw bytes) it is a full-strength AES-256 key.
class LocalGraphDatabase {
  LocalGraphDatabase({GraphKeyStore? keyStore})
      : _keyStore = keyStore ?? GraphKeyStore();

  final GraphKeyStore _keyStore;

  static const String _fileName = 'lifeos_graph.db';

  /// Open (creating + keying on first run) the encrypted graph database,
  /// through the non-destructive migration framework.
  ///
  /// Data-safety contract (the app auto-updates via OTA): an update must NEVER
  /// corrupt or lose the user's graph/memory/RAG/config. This path therefore:
  ///  * refuses to open a database written by a NEWER app version (downgrade),
  ///    leaving the file untouched instead of wiping it;
  ///  * copies the file to a `.bak` before running any upgrade;
  ///  * surfaces a decrypt/open/migration failure (restoring the backup) rather
  ///    than silently creating an empty database in its place;
  ///  * applies only additive, ordered migration steps (see
  ///    `local_graph_migrations.dart` + `MIGRATIONS.md`).
  Future<Database> open() async {
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}/$_fileName';
    final key = await _keyStore.loadOrCreateKey();

    return openGuardedGraphDatabase(
      path: path,
      peekVersion: () => _peekVersion(path, key),
      openMigrating: () => openDatabase(
        path,
        password: key,
        version: kLocalGraphSchemaVersion,
        onConfigure: graphOnConfigure,
        onCreate: graphOnCreate,
        onUpgrade: graphOnUpgrade,
        onDowngrade: graphOnDowngrade,
      ),
    );
  }

  /// Reads the at-rest schema version WITHOUT migrating, so the guard can decide
  /// whether to back up (upgrade) or refuse (downgrade) before any write. Opens
  /// read-only with the key; returns null when the file does not exist yet.
  Future<int?> _peekVersion(String path, String key) async {
    if (!await databaseExists(path)) return null;
    final db = await openReadOnlyDatabase(path, password: key);
    try {
      return await db.getVersion();
    } finally {
      await db.close();
    }
  }
}
