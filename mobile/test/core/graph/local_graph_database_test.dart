// TIMEOUT, calibrated not padded — same rationale as the other graph suites:
// a real SQLCipher open is PBKDF2-HMAC-SHA512 with 256 000 iterations, which
// is seconds of pure CPU on the contended Ryzen 5 5500U runner.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_database_backend.dart';
import 'package:lifeos/core/graph/local_graph_database.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/core/graph/sqlcipher_ffi_backend.dart';
import 'package:lifeos/core/graph/sqlcipher_mobile_backend.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// Covers the platform seam that lets the ENCRYPTED graph database open on
/// Linux desktop as well as on mobile (roadmap SLICE A2).
///
/// The two halves this file protects:
///  * routing — every OS gets the right backend, and an OS with no encrypted
///    backend is REFUSED rather than served an unencrypted database;
///  * `LocalGraphDatabase.open()` still goes through the full non-destructive
///    guard rail, now on whichever backend the platform selected.
///
/// The mobile half of the seam is characterised here as far as a host VM can:
/// the routing is asserted directly, and the mobile backend is proven to fail
/// loudly off-device instead of degrading. What it actually does on-device is
/// unchanged by construction — `SqlCipherMobileGraphBackend` holds the same
/// two expressions that used to be inline in `LocalGraphDatabase`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('backend routing', () {
    test('mobile platforms keep the sqflite_sqlcipher native plugin', () {
      for (final os in ['android', 'ios', 'macos']) {
        final backend = graphDatabaseBackendFor(os);
        expect(backend, isA<SqlCipherMobileGraphBackend>(), reason: os);
        expect(backend.name, 'sqflite_sqlcipher', reason: os);
      }
    });

    test('desktop platforms use the FFI + SQLCipher backend', () {
      for (final os in ['linux', 'windows']) {
        expect(graphDatabaseBackendFor(os), isA<SqlCipherFfiGraphBackend>(),
            reason: os);
      }
    });

    test('an unsupported platform is refused, never given a plaintext DB', () {
      expect(
        () => graphDatabaseBackendFor('fuchsia'),
        throwsA(isA<GraphEncryptionUnavailableException>()),
      );
      // The message has to say why, because this is a refusal to store data.
      expect(
        () => graphDatabaseBackendFor('web'),
        throwsA(
          isA<GraphEncryptionUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('no plaintext fallback'),
          ),
        ),
      );
    });

    test('this host resolves a backend without throwing', () {
      expect(defaultGraphDatabaseBackend(), isA<SqlCipherFfiGraphBackend>());
    });
  });

  group('the mobile backend fails loudly off-device (no silent degradation)',
      () {
    // On Linux there is no `sqflite_sqlcipher` native implementation at all.
    // The one thing that must never happen is a successful open, so assert it
    // throws rather than asserting a particular exception type.
    const mobile = SqlCipherMobileGraphBackend();

    late Directory tmp;
    late String path;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lifeos_graph_mobile_');
      path = '${tmp.path}/graph.db';
      // An EXISTING file is the case that matters: reporting "absent" for a
      // file that is there would let the guard create an empty DB over it.
      await File(path).writeAsBytes(List<int>.filled(64, 0));
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('peekVersion throws instead of answering "fresh install"', () async {
      await expectLater(mobile.peekVersion(path, 'deadbeef'), throwsA(anything));
    });

    test('openMigrating throws instead of returning a handle', () async {
      await expectLater(
        mobile.openMigrating(path, 'deadbeef'),
        throwsA(anything),
      );
    });
  });

  group('LocalGraphDatabase.open() end-to-end on the desktop backend', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lifeos_graph_db_');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('creates, keys, writes and reads back the real encrypted graph',
        () async {
      final db = await LocalGraphDatabase().open();
      expect(await db.getVersion(), kLocalGraphSchemaVersion);
      final created = await SqfliteLocalGraphStore(db)
          .createNode(kind: 'person', label: 'Héctor');
      await db.close();

      // The key came from the keystore and persists, so a brand-new instance
      // reopens the SAME encrypted file.
      final reopened = await LocalGraphDatabase().open();
      addTearDown(() => reopened.close());
      final node =
          await SqfliteLocalGraphStore(reopened).getNodeByUuid(created.uuid);
      expect(node!.label, 'Héctor');

      // And it really is encrypted at rest.
      final path = await LocalGraphDatabase().databasePath();
      final head = String.fromCharCodes(
        (await File(path).readAsBytes()).take(15),
      );
      expect(head, isNot('SQLite format 3'));
    });

    test('a rotated key surfaces as an error, not an empty database', () async {
      final db = await LocalGraphDatabase().open();
      await SqfliteLocalGraphStore(db).createNode(kind: 'fact', label: 'mine');
      await db.close();

      final path = await LocalGraphDatabase().databasePath();
      final before = await File(path).readAsBytes();

      // Simulate the keystore losing/rotating the key (e.g. a restored
      // machine): the data is unreadable, and the ONLY acceptable outcome is
      // an error. Silently minting an empty graph here would destroy it.
      FlutterSecureStorage.setMockInitialValues({});
      await expectLater(LocalGraphDatabase().open(), throwsA(anything));
      expect(await File(path).readAsBytes(), equals(before));
    });

    test('the guard rail still refuses a database from a NEWER app version',
        () async {
      final path = await LocalGraphDatabase().databasePath();
      final key = await _mintKey();

      final backend = SqlCipherFfiGraphBackend();
      final future = kLocalGraphSchemaVersion + 1;
      final seed = await backend.openWithOptions(
        path,
        key,
        OpenDatabaseOptions(
          version: future,
          onCreate: (db, _) => createLatestGraphSchema(db),
          singleInstance: false,
        ),
      );
      await seed.close();

      await expectLater(
        LocalGraphDatabase().open(),
        throwsA(isA<GraphMigrationException>()),
      );
      expect(await backend.peekVersion(path, key), future);
    });
  });
}

/// Materialises the keystore key the way production does, so a test can seed a
/// file the app will later try to open.
Future<String> _mintKey() async {
  const storage = FlutterSecureStorage();
  const secureKey = 'lifeos.graph.db_key';
  final existing = await storage.read(key: secureKey);
  if (existing != null && existing.isNotEmpty) return existing;
  // Let GraphKeyStore mint it through its own path.
  final db = LocalGraphDatabase();
  final opened = await db.open();
  await opened.close();
  await File(await db.databasePath()).delete();
  return (await storage.read(key: secureKey))!;
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}
