import 'package:sqflite_common/sqlite_api.dart' show Database;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'graph_database_backend.dart';
import 'local_graph_migrations.dart';
import 'local_graph_schema.dart';

/// Android / iOS / macOS backend: SQLCipher through the `sqflite_sqlcipher`
/// native plugin (roadmap SLICE A2).
///
/// This is a VERBATIM extraction of what `LocalGraphDatabase.open()` did before
/// the desktop split existed — same `openDatabase(password:)` call, same
/// callbacks, same read-only peek. The user has real data on his phone written
/// by exactly these calls, so nothing here may change without a migration
/// story. The extraction is behaviour-preserving by construction: the two
/// method bodies below are the two expressions that used to be inline.
///
/// The 64-hex key is passed as `password`, which the plugin hands to SQLCipher
/// as a passphrase (`sqlite3_key` on iOS/macOS via FMDB, `openDatabase(path,
/// password)` on Android via `net.zetetic:sqlcipher-android`). SQLCipher then
/// derives the AES-256 key with PBKDF2-HMAC-SHA512 over the file's own salt.
/// (An earlier comment in `graph_key_store.dart` claimed raw-key `x'<hex>'`
/// mode; that is not what these plugins do — neither wraps the string in the
/// `x'…'` literal syntax that would trigger it. The desktop backend matches
/// the ACTUAL passphrase behaviour so the files stay interchangeable.)
class SqlCipherMobileGraphBackend implements GraphDatabaseBackend {
  const SqlCipherMobileGraphBackend();

  @override
  String get name => 'sqflite_sqlcipher';

  @override
  Future<int?> peekVersion(String path, String key) async {
    if (!await sqlcipher.databaseExists(path)) return null;
    final db = await sqlcipher.openReadOnlyDatabase(path, password: key);
    try {
      return await db.getVersion();
    } finally {
      await db.close();
    }
  }

  @override
  Future<Database> openMigrating(String path, String key) =>
      sqlcipher.openDatabase(
        path,
        password: key,
        version: kLocalGraphSchemaVersion,
        onConfigure: graphOnConfigure,
        onCreate: graphOnCreate,
        onUpgrade: graphOnUpgrade,
        onDowngrade: graphOnDowngrade,
      );
}
