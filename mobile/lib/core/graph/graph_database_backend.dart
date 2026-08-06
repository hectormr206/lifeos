import 'dart:io' show Platform;

import 'package:sqflite_common/sqlite_api.dart';

import 'local_graph_migrations.dart';
import 'sqlcipher_ffi_backend.dart';
import 'sqlcipher_mobile_backend.dart';

/// The platform seam for OPENING the encrypted graph database (roadmap
/// SLICE A2). Everything above this line — the migration framework, the
/// backup/downgrade guard rails, the store, the schema — is platform-agnostic
/// and shared. Only "how do I get a keyed SQLCipher connection" differs.
///
/// Two implementations exist, and they must produce the SAME on-disk file:
///
///  * [SqlCipherMobileGraphBackend] — Android / iOS / macOS, via the
///    `sqflite_sqlcipher` native plugin (SQLCipher 4.10.0). This is the path
///    the user's phone has real data on; it is unchanged.
///  * [SqlCipherFfiGraphBackend] — Linux (and Windows once its runner lands),
///    via `sqflite_common_ffi` over a SQLCipher build of `package:sqlite3`
///    (SQLCipher 4.17.0). Selected by the `hooks:` block in `pubspec.yaml`.
///
/// Both hand the 64-hex key from [GraphKeyStore] to SQLCipher as a PASSPHRASE
/// (`sqlite3_key` / `PRAGMA key = '<hex>'`), so SQLCipher derives the AES key
/// with PBKDF2-HMAC-SHA512 over the per-file salt. Both sides being SQLCipher
/// 4.x, the derivation parameters and page format match and the same file
/// opens on either. If one side ever moves to a different SQLCipher MAJOR
/// version, or switches to raw-key (`x'…'`) mode, that compatibility breaks —
/// which matters the day the graph syncs between phone and desktop.
abstract class GraphDatabaseBackend {
  /// Short identifier used in error messages and tests.
  String get name;

  /// Reads the at-rest schema version WITHOUT migrating, so
  /// [openGuardedGraphDatabase] can decide whether to back up (upgrade) or
  /// refuse (downgrade) before any write happens.
  ///
  /// Returns null ONLY when the file genuinely does not exist. A file that
  /// exists but cannot be decrypted must THROW: reporting null there would
  /// tell the guard "fresh install" and let it create an empty database on top
  /// of the user's undecryptable data.
  Future<int?> peekVersion(String path, String key);

  /// Performs the real keyed, migrating open (version + all migration
  /// callbacks from [graphOpenOptions]).
  Future<Database> openMigrating(String path, String key);
}

/// Raised when the platform cannot provide encryption at rest.
///
/// This is the guard that makes "there is no plaintext-fallback path" true
/// rather than aspirational. On desktop, `PRAGMA key` against a stock (non
/// SQLCipher) SQLite build is silently ignored: the open succeeds, the app
/// looks fine, and the user's memory is written to disk in the clear with
/// nothing anywhere to notice it. Every desktop open therefore proves the
/// cipher exists first and raises this instead of degrading.
class GraphEncryptionUnavailableException implements Exception {
  GraphEncryptionUnavailableException(this.message);

  /// The loaded sqlite3 library is not a SQLCipher build.
  factory GraphEncryptionUnavailableException.noCipher(String backend) =>
      GraphEncryptionUnavailableException(
        'The sqlite3 library loaded by the $backend graph backend is not a '
        'SQLCipher build (PRAGMA cipher_version is empty), so "PRAGMA key" '
        'would be silently ignored and the graph database would be written '
        'UNENCRYPTED. Refusing to open. Restore the '
        '"hooks: user_defines: sqlite3: source: sqlcipher" block in '
        'pubspec.yaml and rebuild.',
      );

  /// The running platform has no encrypted graph backend at all.
  factory GraphEncryptionUnavailableException.unsupportedPlatform(String os) =>
      GraphEncryptionUnavailableException(
        'No encrypted graph database backend exists for "$os". The graph is '
        'encrypted at rest by design and there is no plaintext fallback, so '
        'the database is not opened on this platform.',
      );

  final String message;

  @override
  String toString() => 'GraphEncryptionUnavailableException: $message';
}

/// Selects the backend for an operating-system name as reported by
/// [Platform.operatingSystem].
///
/// Taking the OS as a parameter (instead of reading `Platform` inline) is what
/// makes the routing itself testable on the host VM — a Linux test can assert
/// that `'android'` still routes to the untouched mobile plugin path.
///
/// Windows is deliberately routed to the SAME FFI backend as Linux: the
/// `package:sqlite3` SQLCipher build ships a `sqlite3.dll`, so enabling
/// Windows is a `flutter create --platforms=windows` away, not a code change.
GraphDatabaseBackend graphDatabaseBackendFor(String operatingSystem) {
  switch (operatingSystem) {
    case 'android':
    case 'ios':
    case 'macos':
      return SqlCipherMobileGraphBackend();
    case 'linux':
    case 'windows':
      return SqlCipherFfiGraphBackend();
    default:
      throw GraphEncryptionUnavailableException.unsupportedPlatform(
        operatingSystem,
      );
  }
}

/// The backend for the platform this process is actually running on.
GraphDatabaseBackend defaultGraphDatabaseBackend() =>
    graphDatabaseBackendFor(Platform.operatingSystem);
