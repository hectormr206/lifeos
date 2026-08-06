import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'graph_database_backend.dart';
import 'graph_key_store.dart';
import 'local_graph_migrations.dart';

/// Opens the encrypted on-device graph database (roadmap SLICE A2).
///
/// Encryption at rest is provided by SQLCipher (via `sqflite_sqlcipher`): the
/// entire DB file is AES-256 encrypted with a per-install key held in the OS
/// keystore through [GraphKeyStore]. The file is unreadable without the key —
/// there is no plaintext-fallback path.
///
/// The 64-hex key is handed to SQLCipher as a passphrase, from which it derives
/// the AES-256 key with PBKDF2-HMAC-SHA512 over the file's own salt.
///
/// HOW the keyed connection is obtained is platform-specific and lives behind
/// [GraphDatabaseBackend]: the `sqflite_sqlcipher` native plugin on
/// Android/iOS/macOS, `sqflite_common_ffi` over a SQLCipher build of
/// `package:sqlite3` on Linux/Windows. Everything below that seam — schema,
/// migrations, backup, downgrade refusal — is shared, single-sourced code.
class LocalGraphDatabase {
  LocalGraphDatabase({GraphKeyStore? keyStore, GraphDatabaseBackend? backend})
      : _keyStore = keyStore ?? GraphKeyStore(),
        _backend = backend ?? defaultGraphDatabaseBackend();

  final GraphKeyStore _keyStore;

  /// The platform's keyed-open strategy. Injectable so tests can drive the
  /// real guard rails against a chosen backend, and so an unsupported platform
  /// fails at construction rather than halfway through an open.
  final GraphDatabaseBackend _backend;

  static const String _fileName = 'lifeos_graph.db';

  /// Absolute path of the encrypted graph DB file. Exposed for the
  /// data-control kit (backups copy this file; wipe deletes it) so the file
  /// location is defined in exactly ONE place.
  Future<String> databasePath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/$_fileName';
  }

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
    final path = await databasePath();
    final key = await _keyStore.loadOrCreateKey();

    return openGuardedGraphDatabase(
      path: path,
      peekVersion: () => _backend.peekVersion(path, key),
      openMigrating: () => _backend.openMigrating(path, key),
    );
  }
}
