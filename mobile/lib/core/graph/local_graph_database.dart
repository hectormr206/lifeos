import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'graph_key_store.dart';
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

  /// Open (creating + keying on first run) the encrypted graph database.
  Future<Database> open() async {
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}/$_fileName';
    final key = await _keyStore.loadOrCreateKey();

    return openDatabase(
      path,
      password: key,
      version: kLocalGraphSchemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await applyLocalGraphSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 is the initial schema; future DDL changes add migrations here.
        // Re-applying is idempotent (IF NOT EXISTS) so it is safe as a guard.
        await applyLocalGraphSchema(db);
      },
    );
  }
}
