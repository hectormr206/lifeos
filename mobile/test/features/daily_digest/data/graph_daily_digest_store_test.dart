// Proves the daily-digest CONTENT is encrypted at rest: it persists as one
// well-known node in the (SQLCipher-in-production) graph DB, NEVER in plain
// shared_preferences — and the one-shot legacy migration imports the old plain
// key, verifies readability, and only then deletes the plaintext (a failed
// import keeps the plain key so the digest is never lost).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/daily_digest/data/graph_daily_digest_store.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _legacyKey = SharedPrefsDailyDigestPreferences.legacyLastDigestKey;

DailyDigest _digest({String wrapUp = 'Hoy te cuidaste bien.'}) => DailyDigest(
  generatedAt: DateTime.utc(2026, 7, 24, 21),
  deterministicText: 'Salud\n  Yo\n    80 kg',
  wrapUp: wrapUp,
  entriesCount: 1,
);

/// Delegates reads to a real store but FAILS every write — simulates an
/// encrypted store that cannot accept the migration import.
class _WriteFailingStore implements LocalGraphStore {
  _WriteFailingStore(this._inner);
  final LocalGraphStore _inner;

  @override
  Future<GraphNodeRecord?> getNodeByUuid(
    String uuid, {
    bool includeDeleted = false,
  }) => _inner.getNodeByUuid(uuid, includeDeleted: includeDeleted);

  @override
  Future<GraphNodeRecord> upsertNode(GraphNodeRecord node) =>
      throw StateError('graph store is down');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected call in this test');
}

/// Delegates writes but lies during the post-write read-back. This models a
/// broken storage layer that acknowledges an import without making the exact
/// payload readable; migration must keep its plaintext fallback in that case.
class _MismatchedReadBackStore implements LocalGraphStore {
  _MismatchedReadBackStore(this._inner);
  final LocalGraphStore _inner;
  var _wasWritten = false;

  @override
  Future<GraphNodeRecord?> getNodeByUuid(
    String uuid, {
    bool includeDeleted = false,
  }) async {
    if (_wasWritten && uuid == GraphDailyDigestContentStore.digestNodeUuid) {
      final real = await _inner.getNodeByUuid(
        uuid,
        includeDeleted: includeDeleted,
      );
      return real?.copyWith(data: _digest(wrapUp: 'wrong payload').toJson());
    }
    return _inner.getNodeByUuid(uuid, includeDeleted: includeDeleted);
  }

  @override
  Future<GraphNodeRecord> upsertNode(GraphNodeRecord node) async {
    _wasWritten = true;
    return _inner.upsertNode(node);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected call in this test');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Database db;
  late SqfliteLocalGraphStore graphStore;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    graphStore = SqfliteLocalGraphStore(db);
  });

  tearDown(() => db.close());

  GraphDailyDigestContentStore build({LocalGraphStore? store}) =>
      GraphDailyDigestContentStore(store: store ?? graphStore);

  group('save', () {
    test(
      'persists to the graph DB as ONE well-known app_state node — plain prefs stay empty',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = build();

        await store.saveLastDigest(_digest());

        // Encrypted home: a single node with the fixed identity.
        final node = await graphStore.getNodeByUuid(
          GraphDailyDigestContentStore.digestNodeUuid,
        );
        expect(node, isNotNull);
        expect(node!.kind, GraphDailyDigestContentStore.digestNodeKind);
        expect(node.data['wrapUp'], 'Hoy te cuidaste bien.');
        // NOT the plaintext copy of the user's life: plain prefs hold nothing.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey(_legacyKey), isFalse);

        // Round-trips.
        final loaded = await store.lastDigest();
        expect(loaded!.wrapUp, 'Hoy te cuidaste bien.');
        expect(loaded.deterministicText, _digest().deterministicText);
        expect(loaded.entriesCount, 1);
      },
    );

    test(
      'is an UPSERT: re-saving keeps one node, newest content wins',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = build();

        await store.saveLastDigest(_digest(wrapUp: 'primero'));
        await store.saveLastDigest(_digest(wrapUp: 'segundo'));

        final nodes = await graphStore.listNodesByKind(
          GraphDailyDigestContentStore.digestNodeKind,
        );
        expect(
          nodes,
          hasLength(1),
          reason: 'a fixed uuid must never accrete copies',
        );
        expect((await store.lastDigest())!.wrapUp, 'segundo');
      },
    );
  });

  group('legacy plain-prefs migration', () {
    test(
      'imports the plain key into the graph, verifies, then REMOVES the plaintext',
      () async {
        SharedPreferences.setMockInitialValues({
          _legacyKey: _digest(wrapUp: 'legado').encode(),
        });
        final store = build();

        final migrated = await store.lastDigest();

        // Content identical to what the plain key held.
        expect(migrated!.wrapUp, 'legado');
        expect(migrated.deterministicText, _digest().deterministicText);
        // Now encrypted…
        final node = await graphStore.getNodeByUuid(
          GraphDailyDigestContentStore.digestNodeUuid,
        );
        expect(node, isNotNull);
        expect(node!.data['wrapUp'], 'legado');
        // …and the plaintext copy is GONE (removing it is the point).
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey(_legacyKey), isFalse);
        // Subsequent reads come from the graph.
        expect((await store.lastDigest())!.wrapUp, 'legado');
      },
    );

    test('no legacy key → nothing to migrate, clean null', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await build().lastDigest(), isNull);
      expect(
        await graphStore.getNodeByUuid(
          GraphDailyDigestContentStore.digestNodeUuid,
        ),
        isNull,
      );
    });

    test(
      'import failure KEEPS the plain key (no loss) and still returns the digest',
      () async {
        SharedPreferences.setMockInitialValues({
          _legacyKey: _digest(wrapUp: 'legado').encode(),
        });
        final store = build(store: _WriteFailingStore(graphStore));

        final digest = await store.lastDigest();

        // The digest is still served from the legacy copy…
        expect(digest!.wrapUp, 'legado');
        // …and the plain key was NOT deleted, so nothing was lost.
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(_legacyKey),
          isTrue,
          reason: 'delete only AFTER a verified import',
        );
        // The next read (store healthy again) retries and completes migration.
        final retried = await build().lastDigest();
        expect(retried!.wrapUp, 'legado');
        expect(prefs.containsKey(_legacyKey), isFalse);
      },
    );

    test(
      'unverified import KEEPS the plain key even when the write acknowledged',
      () async {
        SharedPreferences.setMockInitialValues({
          _legacyKey: _digest(wrapUp: 'legado').encode(),
        });
        final store = build(store: _MismatchedReadBackStore(graphStore));

        final digest = await store.lastDigest();

        expect(digest!.wrapUp, 'legado');
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(_legacyKey),
          isTrue,
          reason:
              'the fallback may disappear only after its exact graph payload reads back',
        );
      },
    );

    test(
      'undecodable legacy plaintext is removed without creating a node',
      () async {
        SharedPreferences.setMockInitialValues({_legacyKey: 'not json {'});
        final store = build();

        expect(await store.lastDigest(), isNull);
        expect(
          await graphStore.getNodeByUuid(
            GraphDailyDigestContentStore.digestNodeUuid,
          ),
          isNull,
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(_legacyKey),
          isFalse,
          reason: 'corrupt plaintext is unusable and must not linger',
        );
      },
    );
  });

  group('wipe interaction', () {
    test('the graph wipe (fresh empty DB) leaves no digest', () async {
      SharedPreferences.setMockInitialValues({});
      await build().saveLastDigest(_digest());

      // The full wipe DELETES the DB file + rotates the key; the next open
      // recreates an empty schema. Model that with a brand-new in-memory DB.
      final freshDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(freshDb.close);
      await createLatestGraphSchema(freshDb);
      final fresh = GraphDailyDigestContentStore(
        store: SqfliteLocalGraphStore(freshDb),
      );

      expect(await fresh.lastDigest(), isNull);
    });
  });
}
