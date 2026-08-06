import 'dart:io';

// `sqflite_ffi` re-exports the whole `sqflite_common` API surface
// (`Database`, `OpenDatabaseOptions`, `DatabaseFactory`), so this single
// import covers both the factory and the shared types.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'graph_database_backend.dart';
import 'local_graph_migrations.dart';

/// Probe returning the SQLCipher version string of the sqlite3 library behind
/// [factory], or null when that library has no cipher at all.
///
/// Injectable purely so the "no plaintext fallback" guard can be tested: a
/// stock-SQLite build cannot otherwise be manufactured on a machine whose
/// bundled library IS SQLCipher.
typedef CipherVersionProbe = Future<String?> Function(DatabaseFactory factory);

/// DESKTOP backend for the encrypted graph database: Linux today, Windows the
/// moment its runner is added (roadmap SLICE A2).
///
/// ## Why this exists
///
/// `sqflite_sqlcipher` ships native code for `android ios macos` only, and no
/// federated `_linux` implementation exists. On Linux it can only throw
/// `MissingPluginException`, which is why the desktop build could launch but
/// never store or read anything.
///
/// This backend instead drives `package:sqlite3` — configured in `pubspec.yaml`
/// to bundle a SQLCipher build — through `sqflite_common_ffi`. That factory
/// exposes the identical sqflite `Database` API, so the whole migration
/// framework (`local_graph_migrations.dart`, `openGuardedGraphDatabase`) is
/// REUSED unchanged; only the two operations in [GraphDatabaseBackend] differ.
///
/// ## Why every open probes the cipher first
///
/// In stock SQLite, `PRAGMA key` is not an error — it is silently ignored. So
/// the failure mode of losing the SQLCipher build is not a crash, it is an app
/// that keeps working perfectly while writing the user's private memory to
/// disk in the clear, indefinitely, with nothing to notice it. The graph's
/// data-safety contract says there is no plaintext-fallback path, and
/// [_assertCipherAvailable] is what enforces it: no handle is ever returned
/// from a library that cannot encrypt.
///
/// ## On-disk compatibility with mobile
///
/// The key is applied as `PRAGMA key = '<64 hex chars>'` — a PASSPHRASE, which
/// is exactly what `sqflite_sqlcipher` does on Android/iOS/macOS (it calls
/// `sqlite3_key` with the same string; neither side uses the raw-key `x'…'`
/// literal syntax). SQLCipher 4.x defaults are identical on both sides
/// (PBKDF2-HMAC-SHA512, 256 000 iterations, HMAC-SHA512, 4096-byte pages), so
/// a file written here opens on the phone and vice versa.
class SqlCipherFfiGraphBackend implements GraphDatabaseBackend {
  SqlCipherFfiGraphBackend({
    DatabaseFactory? databaseFactory,
    CipherVersionProbe? cipherVersionProbe,
  })  : _injectedFactory = databaseFactory,
        _probe = cipherVersionProbe ?? _probeCipherVersion;

  final DatabaseFactory? _injectedFactory;
  final CipherVersionProbe _probe;

  /// `sqfliteFfiInit()` installs process-wide ffi state; doing it more than
  /// once is wasteful and, in tests that construct several backends, noisy.
  static bool _ffiInitialised = false;

  /// Cached successful probe result. The probe costs a full in-memory database
  /// open, and the answer cannot change within a process — the library is
  /// loaded once. A FAILED probe is never cached, so it re-raises every time.
  String? _cipherVersion;

  @override
  String get name => 'sqflite_common_ffi + SQLCipher';

  DatabaseFactory get _factory {
    if (_injectedFactory != null) return _injectedFactory;
    if (!_ffiInitialised) {
      sqfliteFfiInit();
      _ffiInitialised = true;
    }
    return databaseFactoryFfi;
  }

  /// The SQLCipher version backing this process, e.g. `4.17.0 community`.
  /// Throws [GraphEncryptionUnavailableException] if there is no cipher.
  Future<String> cipherVersion() async {
    final cached = _cipherVersion;
    if (cached != null) return cached;
    final version = await _probe(_factory);
    if (version == null || version.isEmpty) {
      throw GraphEncryptionUnavailableException.noCipher(name);
    }
    return _cipherVersion = version;
  }

  /// Fails the operation BEFORE any file is touched when encryption is
  /// unavailable. Called first by every entry point, so a cipher-less build
  /// cannot create, open, or overwrite a database at all.
  Future<void> _assertCipherAvailable() => cipherVersion();

  @override
  Future<int?> peekVersion(String path, String key) async {
    await _assertCipherAvailable();
    // Only a MISSING file means "fresh install". An existing file that will
    // not decrypt must throw out of here: answering null would tell
    // `openGuardedGraphDatabase` there is nothing on disk, and it would
    // happily create an empty database over the user's data.
    if (!await File(path).exists()) return null;

    final db = await openWithOptions(
      path,
      key,
      OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      return await db.getVersion();
    } finally {
      await db.close();
    }
  }

  @override
  Future<Database> openMigrating(String path, String key) async {
    await _assertCipherAvailable();
    return openWithOptions(path, key, graphOpenOptions());
  }

  /// Opens [path] keyed with [key] under arbitrary [options].
  ///
  /// The key has to be applied as the first statement on the connection, so
  /// this wraps whatever `onConfigure` [options] carry: key first, then the
  /// original hook. `graphOpenOptions()` already defaults that hook to
  /// [graphOnConfigure], so foreign keys stay on.
  ///
  /// Also the seam used to open a database pinned at a specific historical
  /// schema version (migration tests, recovery tooling) without duplicating
  /// the keying logic.
  Future<Database> openWithOptions(
    String path,
    String key,
    OpenDatabaseOptions options,
  ) async {
    await _assertCipherAvailable();
    final inner = options.onConfigure;
    return _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: options.version,
        onConfigure: (db) async {
          await _applyKey(db, key);
          if (inner != null) await inner(db);
        },
        onCreate: options.onCreate,
        onUpgrade: options.onUpgrade,
        onDowngrade: options.onDowngrade,
        onOpen: options.onOpen,
        readOnly: options.readOnly,
        singleInstance: options.singleInstance,
      ),
    );
  }

  /// Issues `PRAGMA key` and then PROVES it took effect.
  ///
  /// The proof matters twice over. With a wrong key, `PRAGMA key` itself
  /// succeeds — SQLCipher only discovers the mismatch when it tries to decrypt
  /// a page, so without this read the failure would surface later, in the
  /// middle of a migration. And on a database that is not SQLCipher-encrypted
  /// at all, this read fails rather than silently adopting a plaintext file.
  Future<void> _applyKey(Database db, String key) async {
    await db.rawQuery("PRAGMA key = '${_escapeSqlLiteral(key)}'");
    // Reading the catalogue forces SQLCipher to decrypt page 1.
    await db.rawQuery('SELECT count(*) FROM sqlite_master');
  }

  /// Doubles single quotes, the SQL string-literal escape. The key from
  /// `GraphKeyStore` is 64 hex characters and can never contain one, but
  /// `PRAGMA key` takes no bind parameters, so the value is interpolated and
  /// escaping it is not optional.
  static String _escapeSqlLiteral(String value) => value.replaceAll("'", "''");
}

Future<String?> _probeCipherVersion(DatabaseFactory factory) async {
  final db = await factory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  try {
    final rows = await db.rawQuery('PRAGMA cipher_version');
    if (rows.isEmpty) return null;
    final value = rows.first.values.first?.toString();
    return (value == null || value.isEmpty) ? null : value;
  } on Object {
    // Stock SQLite answers an unknown PRAGMA with an empty result rather than
    // an error, but a build that errors instead is equally cipher-less.
    return null;
  } finally {
    await db.close();
  }
}
