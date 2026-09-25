// The listening level, kept like the vocabulary placement: its own node kind,
// every attempt kept, the latest one read as the current level.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/listening_result_repository.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late LocalGraphStore store;
  late ListeningResultRepository results;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    results = ListeningResultRepository(store);
  });

  tearDown(() async => db.close());

  test('never measured is "not measured", not a level', () async {
    expect(await results.latest(), isNull);
  });

  test('the latest attempt is the current listening level', () async {
    await results.save(CefrLevel.a2, takenAt: DateTime.utc(2026, 9, 1));
    await results.save(CefrLevel.b1, takenAt: DateTime.utc(2026, 10, 1));

    final latest = (await results.latest())!;
    expect(latest.level, CefrLevel.b1);
    expect(latest.takenAt, DateTime.utc(2026, 10, 1));
  });

  test('before A1 is a real result, kept as such', () async {
    await results.save(null, takenAt: DateTime.utc(2026, 9, 1));

    final latest = (await results.latest())!;
    expect(latest.level, isNull);
  });

  test('its own kind of node, under learning, marked as the learner\'s',
      () async {
    await results.save(CefrLevel.b1, takenAt: DateTime.utc(2026, 9, 1));

    final node = (await store.listNodesByKind(kListeningKind)).single;
    expect(node.domain, 'learning');
    expect(node.data['source'], kListeningKind);
  });
}
