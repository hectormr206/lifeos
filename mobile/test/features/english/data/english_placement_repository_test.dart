// Keeping every vocabulary placement, on the real graph store SQL.
//
// A placement is a node of its own kind, not a `fact`: it is a measurement,
// not a memory, so it stays out of the Cerebro and out of its cleanup. It
// lives in the graph because the graph already encrypts and syncs, which is
// what lets the laptop and the phone agree on the learner's level.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/english_placement_repository.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late LocalGraphStore store;
  late EnglishPlacementRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    repository = EnglishPlacementRepository(store);
  });

  tearDown(() async => db.close());

  VocabPlacementResult result({
    CefrLevel cefr = CefrLevel.b1,
    int words = 3000,
    bool reliable = true,
  }) =>
      VocabPlacementResult(
        knownByBand: const [1.0, 0.9, 0.6, 0.4, 0.1],
        falseAlarmRate: 0.1,
        estimatedWords: words,
        xlexScore: words,
        cefr: cefr,
        reliable: reliable,
      );

  test('a placement is its own kind of node, under learning', () async {
    final takenAt = DateTime.utc(2026, 9, 24, 15);
    await repository.save(result(), takenAt: takenAt);

    final nodes = await store.listNodesByKind(kEnglishPlacementKind);
    expect(nodes, hasLength(1));
    expect(nodes.single.domain, 'learning');
    expect(nodes.single.occurredAt, takenAt);
    // The mark that tells any cleanup a person produced this, not a model.
    expect(nodes.single.data['source'], kEnglishPlacementKind);
  });

  test('the label reads as a sentence, not as a key', () async {
    await repository.save(result(), takenAt: DateTime.utc(2026, 9, 24));

    final node = (await store.listNodesByKind(kEnglishPlacementKind)).single;
    expect(node.label, contains('B1'));
    expect(node.label, contains('3000'));
  });

  test('every field of the result comes back as it was saved', () async {
    final saved = result();
    await repository.save(saved, takenAt: DateTime.utc(2026, 9, 24));

    final back = (await repository.history()).single.result;
    expect(back.cefr, saved.cefr);
    expect(back.estimatedWords, saved.estimatedWords);
    expect(back.xlexScore, saved.xlexScore);
    expect(back.reliable, saved.reliable);
    expect(back.falseAlarmRate, saved.falseAlarmRate);
    expect(back.knownByBand, saved.knownByBand);
  });

  test('history is newest first, so progress reads top-down', () async {
    await repository.save(result(words: 2000, cefr: CefrLevel.a2),
        takenAt: DateTime.utc(2026, 9, 1));
    await repository.save(result(words: 2900, cefr: CefrLevel.b1),
        takenAt: DateTime.utc(2026, 10, 1));

    final words = [
      for (final record in await repository.history())
        record.result.estimatedWords,
    ];
    expect(words, [2900, 2000]);
  });

  test('the current level ignores a newer attempt that was not reliable',
      () async {
    await repository.save(result(cefr: CefrLevel.b1),
        takenAt: DateTime.utc(2026, 9, 1));
    await repository.save(result(cefr: CefrLevel.c2, reliable: false),
        takenAt: DateTime.utc(2026, 9, 2));

    final current = await repository.latestReliable();
    expect(current?.result.cefr, CefrLevel.b1);
  });

  test('no placement yet means no level, not a default one', () async {
    expect(await repository.latestReliable(), isNull);
  });

  test('a damaged node is skipped instead of breaking the history',
      () async {
    await store.createNode(
      kind: kEnglishPlacementKind,
      label: 'roto',
      data: const {'cefr': 'z9'},
    );
    await repository.save(result(), takenAt: DateTime.utc(2026, 9, 24));

    expect(await repository.history(), hasLength(1));
  });
}
