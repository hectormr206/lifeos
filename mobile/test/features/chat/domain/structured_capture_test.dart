// Proves the crown-jewel END-TO-END: a health reading typed into chat lands as a
// STRUCTURED domain entry (visible via LocalDomainRepository) + its graph fact,
// attributed to the right person, deterministically deduped by source message,
// carrying provenance — while a non-parseable line keeps the raw-fact behavior.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;
  late LocalDomainRepository repo;

  final now = DateTime(2026, 7, 22, 10, 0);

  setUpAll(() async {
    sqfliteFfiInit();
    await initializeDateFormatting('es');
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    writer = MemoryWriter(store);
    repo = LocalDomainRepository(store, writer: writer, now: () => now);
  });

  tearDown(() async => db.close());

  ChatContextBuilder builder() => ChatContextBuilder(
        loadDeps: () async => ChatContextDeps(store: store, writer: writer),
        languageCode: () => 'es',
        now: () => now,
      );

  Future<List<GraphNodeRecord>> facts() => store.listNodesByKind('fact');

  test('a BP reading lands as a STRUCTURED blood_pressure entry (mine)', () async {
    await builder().recordTurn(
      userText: '122 77 55 pulsos',
      axiText: 'Anotado.',
      sourceConversationUuid: 'conv-1',
      sourceMessageId: 'msg-1',
    );

    final entries = await repo.list('health', type: 'blood_pressure');
    expect(entries.length, 1);
    final e = entries.single;
    expect(e.data['systolic'], 122);
    expect(e.data['diastolic'], 77);
    expect(e.data['pulse'], 55);
    expect(e.label, 'presión 122/77, pulso 55');
    // Dated to the turn, carries provenance for the delete-cascade.
    expect(e.timestamp, now.toUtc());
    expect(e.data['sourceConversationUuid'], 'conv-1');
    expect(e.data['sourceMessageId'], 'msg-1');
    // Exactly one fact node (structured hit does NOT also write a raw fact).
    expect((await facts()).length, 1);
  });

  test("wife's reading attributes to the esposa person node", () async {
    await builder().recordTurn(
      userText: 'de mi esposa son 120, 60, 49 pulsos',
      axiText: 'Listo.',
    );

    final entries = await repo.list('health', type: 'blood_pressure');
    expect(entries.single.data['subject'], 'esposa');

    final person = (await store.listNodesByKind('person'))
        .firstWhere((p) => p.data['role'] != 'user');
    final involves =
        await store.edgesForNode(entries.single.uuid, relation: 'involves');
    expect(involves.single.dstUuid, person.uuid);
  });

  test("dad's reading: 'esto le salió a mi papá 135, 89, 95 pulsos'", () async {
    await builder().recordTurn(
      userText: 'esto le salió a mi papá 135, 89, 95 pulsos',
      axiText: 'Ok.',
    );
    final e = (await repo.list('health', type: 'blood_pressure')).single;
    expect(e.data['subject'], 'papá');
    expect(e.data['systolic'], 135);
  });

  test('glucose + weight also land as structured entries', () async {
    await builder().recordTurn(userText: 'glucosa 110', axiText: 'ok');
    await builder().recordTurn(userText: 'peso 82', axiText: 'ok');

    expect((await repo.list('health', type: 'glucose')).single.data['value'], 110);
    expect((await repo.list('health', type: 'weight')).single.data['value'], 82.0);
  });

  test('entryId dedup: re-processing the same message writes one entry', () async {
    for (var i = 0; i < 2; i++) {
      await builder().recordTurn(
        userText: '122 77 55 pulsos',
        axiText: 'ok',
        sourceMessageId: 'msg-dup',
      );
    }
    expect((await repo.list('health', type: 'blood_pressure')).length, 1);
    expect((await facts()).length, 1);
  });

  test('name-learning then a bare-relation reading resolves to the named node',
      () async {
    await builder().recordTurn(
      userText: 'mi esposa se llama Celia',
      axiText: 'ok',
    );
    await builder().recordTurn(
      userText: 'de mi esposa son 118, 79, 60 pulsos',
      axiText: 'ok',
    );

    final person = (await store.listNodesByKind('person'))
        .firstWhere((p) => p.data['role'] != 'user');
    expect(person.label, 'Celia');
    final e = (await repo.list('health', type: 'blood_pressure')).single;
    final involves = await store.edgesForNode(e.uuid, relation: 'involves');
    expect(involves.single.dstUuid, person.uuid);
  });

  test('no parse → raw-fact behavior unchanged (never mis-file)', () async {
    // Filler between the keyword and the numbers → parser misses → raw fallback.
    await builder().recordTurn(
      userText: 'Mi presión hoy fue 128/84',
      axiText: 'ok',
    );
    // No STRUCTURED blood_pressure entry (it did not parse)…
    expect(await repo.list('health', type: 'blood_pressure'), isEmpty);
    // …but the raw health fact is still there, untyped, as before.
    final f = (await facts()).single;
    expect(f.domain, 'health');
    expect(f.data['type'], isNull);
    expect(f.label, contains('128/84'));
  });
}
