import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// SLICE A3 — on-device memory write path.
///
/// Runs against a REAL in-memory sqlite (`sqflite_common_ffi`) exactly like the
/// A2 store tests, so the graph writes/edges are exercised as they run on-device.
void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    writer = MemoryWriter(store);
  });

  tearDown(() async => db.close());

  Future<List<GraphNodeRecord>> facts() => store.listNodesByKind('fact');
  Future<List<GraphNodeRecord>> people() => store.listNodesByKind('person');

  group('writeFact', () {
    test('creates a fact node + hub, wired by an "about" edge', () async {
      final fact = await writer.writeFact(
        domain: 'health',
        label: 'presión 110/81, pulso 51',
        occurredAt: DateTime.utc(2026, 7, 20),
      );

      expect(fact, isNotNull);
      expect(fact!.kind, 'fact');
      expect(fact.domain, 'health');
      expect((await facts()).length, 1);

      // The user hub was auto-created (role marker, not name).
      final hubs = await people();
      expect(hubs.length, 1);
      expect(hubs.first.data['role'], 'user');

      // hub --about--> fact
      final edges = await store.edgesForNode(fact.uuid, relation: 'about');
      expect(edges.length, 1);
      expect(edges.first.srcUuid, hubs.first.uuid);
      expect(edges.first.dstUuid, fact.uuid);
    });

    test('reuses one hub across many facts', () async {
      await writer.writeFact(domain: 'health', label: 'presión 120/80');
      await writer.writeFact(domain: 'finance', label: 'gasté 450 en super');
      expect((await people()).length, 1);
      expect((await facts()).length, 2);
    });

    test('maps calendar domain to lifeos-events for wire-compat', () async {
      final fact = await writer.writeFact(
        domain: 'calendar',
        label: 'viaje a Oaxaca 15 de agosto',
      );
      expect(fact!.domain, 'lifeos-events');
    });

    test('skips a low-value (bare keyword) entry -> null, no node', () async {
      final result = await writer.writeFact(domain: 'health', label: 'salud');
      expect(result, isNull);
      expect(await facts(), isEmpty);
      // No hub either — nothing was written.
      expect(await people(), isEmpty);
    });

    test('keeps a bare keyword when it carries a numeric field', () async {
      final result = await writer.writeFact(
        domain: 'finance',
        label: 'gasto',
        data: <String, dynamic>{'amount': 0},
      );
      expect(result, isNotNull);
    });

    test('dedupes by deterministic data.entryId', () async {
      final first = await writer.writeFact(
        domain: 'health',
        label: 'presión 110/81',
        data: <String, dynamic>{'entryId': 'health:42'},
      );
      final second = await writer.writeFact(
        domain: 'health',
        label: 'presión 110/81 (dupe)',
        data: <String, dynamic>{'entryId': 'health:42'},
      );

      expect(first!.uuid, second!.uuid); // same node returned
      expect((await facts()).length, 1); // no duplicate written
    });

    test('links to a family person node when subject is set', () async {
      final fact = await writer.writeFact(
        domain: 'health',
        label: 'presión 121/79 pulso 61',
        subject: 'esposa',
      );

      // subject persisted on the fact.
      expect(fact!.data['subject'], 'esposa');

      // A non-hub person node was created and linked via "involves".
      final person =
          (await people()).firstWhere((p) => p.data['role'] != 'user');
      expect(person.label, 'esposa');
      final involves = await store.edgesForNode(fact.uuid, relation: 'involves');
      expect(involves.single.dstUuid, person.uuid);
    });
  });

  group('writeConversationTurn', () {
    test('creates a conversation node linked to the hub', () async {
      final turn = await writer.writeConversationTurn(
        userText: 'hola Axi',
        axiText: '¡Hola! ¿En qué te ayudo?',
      );
      expect(turn.kind, 'conversation');
      expect(turn.data['userText'], 'hola Axi');
      final edges = await store.edgesForNode(turn.uuid, relation: 'about');
      expect(edges.length, 1);
    });
  });

  group('isLowValue', () {
    test('empty / blank label is low value', () {
      expect(isLowValue('', null), isTrue);
      expect(isLowValue('   ', null), isTrue);
    });

    test('anything with a digit is kept', () {
      expect(isLowValue('presión 120/80', null), isFalse);
      expect(isLowValue('7', null), isFalse);
    });

    test('bare short single keyword with no content is low value', () {
      expect(isLowValue('salud', null), isTrue);
      expect(isLowValue('nota', const <String, dynamic>{'entryId': 'x'}), isTrue);
    });

    test('multi-word label is kept', () {
      expect(isLowValue('dolor de cabeza', null), isFalse);
    });

    test('single keyword with raw_utterance content is kept', () {
      expect(
        isLowValue('salud', const <String, dynamic>{'raw_utterance': 'me siento mal'}),
        isFalse,
      );
    });
  });

  group('renderLabel priority', () {
    test('raw_utterance wins over title and structured', () {
      expect(
        renderLabel(rawUtterance: 'raw', title: 't', structured: 's'),
        'raw',
      );
    });

    test('falls back title -> structured -> null', () {
      expect(renderLabel(title: 't', structured: 's'), 't');
      expect(renderLabel(structured: 's'), 's');
      expect(renderLabel(rawUtterance: '   '), isNull);
    });

    test('caps at 120 chars', () {
      final long = 'a' * 200;
      expect(renderLabel(rawUtterance: long)!.length, 120);
    });
  });
}
