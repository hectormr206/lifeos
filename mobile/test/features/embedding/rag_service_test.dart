import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/embedding/domain/rag_service.dart';
import 'package:lifeos/features/embedding/domain/text_embedder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A deterministic, device-free [TextEmbedder] for tests. Maps each exact text
/// to a caller-supplied vector; records the (text, isQuery) calls so the
/// query/document task split can be asserted. Unknown text → zero vector.
class FakeTextEmbedder implements TextEmbedder {
  FakeTextEmbedder(
    this._vectors, {
    this.model = 'fake@3',
    this.dimension = 3,
  });

  final Map<String, List<double>> _vectors;
  final List<({String text, bool isQuery})> calls = [];
  var disposed = false;

  @override
  final String model;

  @override
  final int dimension;

  @override
  Future<Float32List> embed(String text, {bool isQuery = false}) async {
    calls.add((text: text, isQuery: isQuery));
    final vec = _vectors[text] ?? List<double>.filled(dimension, 0);
    return Float32List.fromList(vec);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

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

  group('indexNode', () {
    test('embeds label + data (document task) and stores a recallable vector',
        () async {
      final node = await store.createNode(
        kind: 'fact',
        label: 'apples',
        data: {'note': 'red'},
      );
      final embedder = FakeTextEmbedder({'apples\nred': [1, 0, 0]});
      final rag = RagService(embedder: embedder, store: store);

      await rag.indexNode(node);

      // Document task (isQuery == false) was used for indexing.
      expect(embedder.calls.single.isQuery, isFalse);
      expect(embedder.calls.single.text, 'apples\nred');

      // The vector is stored under the embedder's model and recallable.
      final hits = await store.recall(
        Float32List.fromList([1, 0, 0]),
        k: 5,
        model: embedder.model,
      );
      expect(hits.single.uuid, node.uuid);
    });

    test('skips a tombstoned node (nothing indexed)', () async {
      final created = await store.createNode(kind: 'fact', label: 'gone');
      await store.softDeleteNode(created.uuid);
      // A caller re-indexing a node it just fetched would hold the tombstoned
      // record; indexNode must no-op on it.
      final node =
          await store.getNodeByUuid(created.uuid, includeDeleted: true);
      expect(node!.isDeleted, isTrue);
      final embedder = FakeTextEmbedder({'gone': [1, 0, 0]});
      final rag = RagService(embedder: embedder, store: store);

      await rag.indexNode(node);

      expect(embedder.calls, isEmpty);
      expect(
        await store.recall(Float32List.fromList([1, 0, 0]),
            k: 5, model: embedder.model),
        isEmpty,
      );
    });
  });

  group('recallByText', () {
    test('embeds the query (query task) and returns nearest nodes ranked',
        () async {
      final near = await store.createNode(kind: 'fact', label: 'near');
      final far = await store.createNode(kind: 'fact', label: 'far');
      final embedder = FakeTextEmbedder({
        'near': [1, 0, 0],
        'far': [0, 1, 0],
        'find x': [1, 0, 0],
      });
      final rag = RagService(embedder: embedder, store: store);

      await rag.indexNode(near);
      await rag.indexNode(far);
      embedder.calls.clear();

      final hits = await rag.recallByText('find x', k: 2);

      // Query task (isQuery == true) was used for the recall.
      expect(embedder.calls.single.isQuery, isTrue);
      expect(hits.map((n) => n.uuid).toList(), [near.uuid, far.uuid]);
    });

    test('blank query returns [] without embedding', () async {
      final embedder = FakeTextEmbedder({});
      final rag = RagService(embedder: embedder, store: store);

      expect(await rag.recallByText('   ', k: 5), isEmpty);
      expect(embedder.calls, isEmpty);
    });

    test('recall is scoped to the embedder model (never crosses models)',
        () async {
      // A vector from a DIFFERENT model must not be returned.
      final other = await store.createNode(kind: 'fact', label: 'other');
      await store.upsertNodeVector(
          other.uuid, 'someOtherModel', 3, Float32List.fromList([1, 0, 0]));

      final mine = await store.createNode(kind: 'fact', label: 'mine');
      final embedder = FakeTextEmbedder({
        'mine': [1, 0, 0],
        'q': [1, 0, 0],
      });
      final rag = RagService(embedder: embedder, store: store);
      await rag.indexNode(mine);

      final hits = await rag.recallByText('q', k: 5);
      expect(hits.map((n) => n.uuid).toList(), [mine.uuid]);
    });
  });

  group('backfillMissingVectors', () {
    test('backfillMissingVectors indexes only unvectored live facts',
        () async {
      // Facts recorded while the embedder was dormant (no vector yet).
      final oldFact = await store.createNode(kind: 'fact', label: 'old');
      final older = await store.createNode(kind: 'fact', label: 'older');
      // Already indexed under THIS model → must be skipped.
      final done = await store.createNode(kind: 'fact', label: 'done');
      // Not a fact → never backfilled.
      await store.createNode(kind: 'conversation', label: 'chit chat');
      // Tombstoned fact → never backfilled.
      final dead = await store.createNode(kind: 'fact', label: 'dead');
      await store.softDeleteNode(dead.uuid);

      final embedder = FakeTextEmbedder({
        'old': [1, 0, 0],
        'older': [0, 1, 0],
      });
      final rag = RagService(embedder: embedder, store: store);
      await store.upsertNodeVector(
          done.uuid, embedder.model, 3, Float32List.fromList([0, 0, 1]));

      final indexed = await rag.backfillMissingVectors(batchSize: 1);

      expect(indexed, 2);
      expect(
        embedder.calls.map((c) => c.text).toSet(),
        {'old', 'older'},
      );
      expect(embedder.calls.every((c) => !c.isQuery), isTrue);
      // Both backfilled facts are now recallable under this model.
      final hits = await store.recall(Float32List.fromList([1, 0, 0]),
          k: 10, model: embedder.model);
      expect(hits.map((n) => n.uuid).toSet(),
          {oldFact.uuid, older.uuid, done.uuid});
    });

    test(
        'backfillMissingVectors treats a DIFFERENT-model vector as missing '
        '(R8: every model needs its own vectors)', () async {
      final fact = await store.createNode(kind: 'fact', label: 'crossed');
      await store.upsertNodeVector(
          fact.uuid, 'someOtherModel@3', 3, Float32List.fromList([1, 0, 0]));

      final embedder = FakeTextEmbedder({'crossed': [0, 1, 0]});
      final rag = RagService(embedder: embedder, store: store);

      expect(await rag.backfillMissingVectors(), 1);
      final hits = await store.recall(Float32List.fromList([0, 1, 0]),
          k: 5, model: embedder.model);
      expect(hits.single.uuid, fact.uuid);
    });

    test('backfillMissingVectors caps the pass at maxNodes', () async {
      for (var i = 0; i < 5; i++) {
        await store.createNode(kind: 'fact', label: 'fact $i');
      }
      final embedder = FakeTextEmbedder({});
      final rag = RagService(embedder: embedder, store: store);

      expect(await rag.backfillMissingVectors(batchSize: 2, maxNodes: 3), 3);
      expect(embedder.calls.length, 3);
    });
  });
}
