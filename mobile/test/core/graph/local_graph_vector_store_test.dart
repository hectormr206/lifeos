import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Vector-recall tests for the on-device graph store (roadmap SLICE B1).
///
/// Same host-side `sqflite_common_ffi` backend as the other graph tests. These
/// build the LATEST schema (`createLatestGraphSchema` = v1 base + all
/// migrations) so the v3 `vec_nodes` table exists. The store does storage +
/// cosine math only; embeddings are supplied directly as vectors.
void main() {
  late Database db;
  late SqfliteLocalGraphStore store;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
  });

  tearDown(() async => db.close());

  Float32List v(List<double> xs) => Float32List.fromList(xs);

  group('upsert + recall cosine ranking', () {
    test('ranks nodes by cosine similarity to the query, most similar first',
        () async {
      final near = await store.createNode(kind: 'fact', label: 'near');
      final mid = await store.createNode(kind: 'fact', label: 'mid');
      final far = await store.createNode(kind: 'fact', label: 'far');

      const model = 'm@3';
      // Query points along +x. near ≈ +x, mid at 45°, far ≈ +y (orthogonal).
      await store.upsertNodeVector(near.uuid, model, 3, v([1, 0, 0]));
      await store.upsertNodeVector(mid.uuid, model, 3, v([1, 1, 0]));
      await store.upsertNodeVector(far.uuid, model, 3, v([0, 1, 0]));

      final hits = await store.recall(v([1, 0, 0]), k: 3, model: model);
      expect(hits.map((n) => n.uuid).toList(),
          [near.uuid, mid.uuid, far.uuid]);
    });

    test('respects k (returns only the top-k)', () async {
      const model = 'm@3';
      for (var i = 0; i < 5; i++) {
        final n = await store.createNode(kind: 'fact', label: 'n$i');
        // Decreasing similarity to +x as i grows.
        await store.upsertNodeVector(
            n.uuid, model, 3, v([5.0 - i, i.toDouble(), 0]));
      }
      final hits = await store.recall(v([1, 0, 0]), k: 2, model: model);
      expect(hits.length, 2);
      expect(hits.first.label, 'n0');
    });

    test('re-upserting a node overwrites its vector (one row per node+model)',
        () async {
      final a = await store.createNode(kind: 'fact', label: 'a');
      final b = await store.createNode(kind: 'fact', label: 'b');
      const model = 'm@2';
      await store.upsertNodeVector(a.uuid, model, 2, v([1, 0]));
      await store.upsertNodeVector(b.uuid, model, 2, v([0, 1]));

      // a was near +x; move it to +y so b (still +x-ish? no) — flip so a loses.
      await store.upsertNodeVector(a.uuid, model, 2, v([0, 1]));
      await store.upsertNodeVector(b.uuid, model, 2, v([1, 0]));

      final hits = await store.recall(v([1, 0]), k: 2, model: model);
      expect(hits.first.uuid, b.uuid);

      // Still exactly one row for (a, model): recall returns both nodes once.
      expect(hits.map((n) => n.uuid).toSet(), {a.uuid, b.uuid});
    });
  });

  group('model filtering (caveat R8)', () {
    test('recall(model:) only considers vectors of that model', () async {
      final x = await store.createNode(kind: 'fact', label: 'x');
      final y = await store.createNode(kind: 'fact', label: 'y');
      await store.upsertNodeVector(x.uuid, 'modelA', 2, v([1, 0]));
      await store.upsertNodeVector(y.uuid, 'modelB', 2, v([1, 0]));

      final a = await store.recall(v([1, 0]), k: 5, model: 'modelA');
      expect(a.map((n) => n.uuid).toList(), [x.uuid]);

      final b = await store.recall(v([1, 0]), k: 5, model: 'modelB');
      expect(b.map((n) => n.uuid).toList(), [y.uuid]);
    });

    test('recall without model throws when vectors span multiple models',
        () async {
      final x = await store.createNode(kind: 'fact', label: 'x');
      final y = await store.createNode(kind: 'fact', label: 'y');
      await store.upsertNodeVector(x.uuid, 'modelA', 2, v([1, 0]));
      await store.upsertNodeVector(y.uuid, 'modelB', 2, v([1, 0]));

      expect(
        () => store.recall(v([1, 0]), k: 5),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('recall without model is fine when only one model is present',
        () async {
      final x = await store.createNode(kind: 'fact', label: 'x');
      await store.upsertNodeVector(x.uuid, 'onlyModel', 2, v([1, 0]));
      final hits = await store.recall(v([1, 0]), k: 5);
      expect(hits.single.uuid, x.uuid);
    });

    test('rows whose stored dim differs from the query are skipped', () async {
      final ok = await store.createNode(kind: 'fact', label: 'ok');
      final wrong = await store.createNode(kind: 'fact', label: 'wrong');
      const model = 'm';
      await store.upsertNodeVector(ok.uuid, model, 2, v([1, 0]));
      await store.upsertNodeVector(wrong.uuid, model, 3, v([1, 0, 0]));

      final hits = await store.recall(v([1, 0]), k: 5, model: model);
      expect(hits.map((n) => n.uuid).toList(), [ok.uuid]);
    });
  });

  group('tombstone exclusion + deletion', () {
    test('recall hides vectors whose node is soft-deleted', () async {
      final live = await store.createNode(kind: 'fact', label: 'live');
      final dead = await store.createNode(kind: 'fact', label: 'dead');
      const model = 'm@2';
      await store.upsertNodeVector(live.uuid, model, 2, v([1, 0]));
      await store.upsertNodeVector(dead.uuid, model, 2, v([1, 0]));

      await store.softDeleteNode(dead.uuid);

      final hits = await store.recall(v([1, 0]), k: 5, model: model);
      expect(hits.map((n) => n.uuid).toList(), [live.uuid]);
    });

    test('deleteNodeVector removes the vector across all models', () async {
      final n = await store.createNode(kind: 'fact', label: 'n');
      await store.upsertNodeVector(n.uuid, 'modelA', 2, v([1, 0]));
      await store.upsertNodeVector(n.uuid, 'modelB', 2, v([1, 0]));

      await store.deleteNodeVector(n.uuid);

      expect(await store.recall(v([1, 0]), k: 5, model: 'modelA'), isEmpty);
      expect(await store.recall(v([1, 0]), k: 5, model: 'modelB'), isEmpty);
    });
  });

  group('edge cases', () {
    test('recall over an empty store returns []', () async {
      expect(await store.recall(v([1, 0]), k: 5, model: 'm'), isEmpty);
    });

    test('k <= 0 returns []', () async {
      final n = await store.createNode(kind: 'fact', label: 'n');
      await store.upsertNodeVector(n.uuid, 'm', 2, v([1, 0]));
      expect(await store.recall(v([1, 0]), k: 0, model: 'm'), isEmpty);
    });

    test('an orphan vector (no matching live node) is ignored', () async {
      // Vector for a uuid that has no node row at all.
      await store.upsertNodeVector('ghost-uuid', 'm', 2, v([1, 0]));
      expect(await store.recall(v([1, 0]), k: 5, model: 'm'), isEmpty);
    });

    test('vectors round-trip through the BLOB with float precision', () async {
      final n = await store.createNode(kind: 'fact', label: 'n');
      await store.upsertNodeVector(n.uuid, 'm', 3, v([0.25, -0.5, 0.125]));
      // Identical query → cosine 1.0 → it is the single hit.
      final hits = await store.recall(v([0.25, -0.5, 0.125]), k: 1, model: 'm');
      expect(hits.single.uuid, n.uuid);
    });
  });
}
