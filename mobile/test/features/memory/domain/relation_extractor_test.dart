// Proves the OPEN-ENDED (model-based) relation extractor: valid strict JSON is
// written through the existing memory path with occurred_at stamped; malformed
// JSON is a no-op no-crash; logged vitals are dropped (deterministic path wins);
// and relations resolve to the correct person hub / generic entity nodes.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:lifeos/features/memory/domain/relation_extractor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;

  final now = DateTime.utc(2026, 7, 22, 10, 0);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    writer = MemoryWriter(store);
  });

  tearDown(() async => db.close());

  RelationExtractor extractorWith(String json) => RelationExtractor(
        engine: FakeLocalLlmEngine(reply: (_) => json),
        writer: writer,
        store: store,
        now: () => now,
      );

  Future<List<GraphNodeRecord>> facts() => store.listNodesByKind('fact');
  Future<List<GraphNodeRecord>> people() => store.listNodesByKind('person');
  Future<List<GraphNodeRecord>> entities() => store.listNodesByKind('entity');

  group('parseExtraction (pure)', () {
    test('valid JSON parses facts + relations', () {
      final ex = parseExtraction(
        '{"facts":[{"label":"Prefiere café sin azúcar","domain":"personal"}],'
        '"relations":[{"subject":"yo","predicate":"esposa","object":"Celia"}]}',
      );
      expect(ex, isNotNull);
      expect(ex!.facts.single.label, 'Prefiere café sin azúcar');
      expect(ex.facts.single.domain, 'personal');
      expect(ex.relations.single.predicate, 'esposa');
      expect(ex.relations.single.object, 'Celia');
    });

    test('recovers JSON wrapped in markdown fences + prose', () {
      final ex = parseExtraction(
        'Claro:\n```json\n{"facts":[{"label":"Trabaja en Acme"}],'
        '"relations":[]}\n```\n',
      );
      expect(ex!.facts.single.label, 'Trabaja en Acme');
    });

    test('malformed / empty JSON → null', () {
      expect(parseExtraction('lo siento, no hay JSON aquí'), isNull);
      expect(parseExtraction(''), isNull);
      expect(parseExtraction('{ not: valid'), isNull);
    });

    test('accepts the laptop "relation" key as an alias of "predicate"', () {
      final ex = parseExtraction(
        '{"facts":[],"relations":[{"subject":"yo","relation":"primo",'
        '"object":"Rodrigo"}]}',
      );
      expect(ex!.relations.single.predicate, 'primo');
    });
  });

  group('isLoggedVital', () {
    test('true for pure numeric vitals, false for prose', () {
      expect(isLoggedVital('presión 120/80'), isTrue);
      expect(isLoggedVital('glucosa 95'), isTrue);
      expect(isLoggedVital('120/80'), isTrue);
      expect(isLoggedVital('Hipertensión diagnosticada hace 2 años'), isFalse);
      expect(isLoggedVital('losartán'), isFalse);
    });
  });

  group('extractAndWrite', () {
    test('valid JSON → facts + relations written, occurred_at stamped',
        () async {
      await extractorWith(
        '{"facts":[{"label":"Prefiere café sin azúcar","domain":"personal"}],'
        '"relations":[{"subject":"yo","predicate":"esposa","object":"Celia",'
        '"object_kind":"person","aliases":["Cel"]}]}',
      ).extractAndWrite('mi esposa Celia y yo tomamos café sin azúcar', 'ok');

      // Fact written, temporally stamped to now.
      final f = (await facts()).single;
      expect(f.label, 'Prefiere café sin azúcar');
      expect(f.occurredAt, now);
      expect(f.data['source'], 'relation_extractor');

      // Relation resolved to the esposa person hub, named + aliased.
      final person = (await people()).firstWhere((p) => p.data['role'] != 'user');
      expect(person.label, 'Celia');
      expect(person.data['relation'], 'esposa');
      expect((person.data['aliases'] as List), contains('Cel'));

      final hub = (await people()).firstWhere((p) => p.data['role'] == 'user');
      final esposaEdges =
          await store.edgesForNode(hub.uuid, relation: 'esposa');
      expect(esposaEdges.single.dstUuid, person.uuid);
    });

    test('entity-to-entity relation creates generic entity nodes + edge',
        () async {
      await extractorWith(
        '{"facts":[],"relations":[{"subject":"hipertensión",'
        '"predicate":"tratada_con","object":"losartán",'
        '"subject_kind":"condition","object_kind":"medication"}]}',
      ).extractAndWrite('me tratan la hipertensión con losartán', 'ok');

      final ents = await entities();
      final labels = ents.map((e) => e.label).toSet();
      expect(labels, containsAll(<String>{'hipertensión', 'losartán'}));
      // Generic entities are temporally stamped too.
      expect(ents.every((e) => e.occurredAt == now), isTrue);

      final src = ents.firstWhere((e) => e.label == 'hipertensión');
      final dst = ents.firstWhere((e) => e.label == 'losartán');
      final edges =
          await store.edgesForNode(src.uuid, relation: 'tratada_con');
      expect(edges.single.dstUuid, dst.uuid);
    });

    test('a DETERMINISTIC segment subject files the fact under that person',
        () async {
      // Regression: model-extracted facts were written with NO subject, so a
      // family member's medication became the USER's own health fact.
      await extractorWith(
        '{"facts":[{"label":"mi esposa toma losartán 50 mg","domain":"health"}],'
        '"relations":[]}',
      ).extractAndWrite(
        'mi esposa empezó a tomar losartán, corrí 5 km',
        'ok',
        subject: 'esposa',
      );

      final f = (await facts()).single;
      expect(f.data['subject'], 'esposa');
      // fact --involves--> the esposa person node (not just the user hub).
      final person = (await people()).firstWhere((p) => p.data['role'] != 'user');
      expect(person.data['relation'], 'esposa');
      final involves = await store.edgesForNode(f.uuid, relation: 'involves');
      expect(involves.single.dstUuid, person.uuid);
    });

    test('no segment subject → user attribution unchanged', () async {
      await extractorWith(
        '{"facts":[{"label":"Prefiere café sin azúcar","domain":"personal"}],'
        '"relations":[]}',
      ).extractAndWrite('me gusta el café sin azúcar', 'ok');

      final f = (await facts()).single;
      expect(f.data.containsKey('subject'), isFalse);
      final involves = await store.edgesForNode(f.uuid, relation: 'involves');
      expect(involves, isEmpty);
    });

    test('malformed JSON → no-op, no crash', () async {
      await extractorWith('no hay json que valga').extractAndWrite('hola', 'ok');
      expect(await facts(), isEmpty);
      expect((await people()).where((p) => p.data['role'] != 'user'), isEmpty);
    });

    test('empty extraction → nothing written', () async {
      await extractorWith('{"facts":[],"relations":[]}')
          .extractAndWrite('hola', 'ok');
      expect(await facts(), isEmpty);
    });

    test('logged vitals are dropped (deterministic path owns them)', () async {
      await extractorWith(
        '{"facts":[{"label":"presión 120/80","domain":"health"},'
        '{"label":"Diagnosticado con hipertensión","domain":"health"}],'
        '"relations":[{"subject":"yo","predicate":"tiene","object":"120/80"}]}',
      ).extractAndWrite('mi presión fue 120/80', 'ok');

      final f = await facts();
      // The narrative fact is kept; the bare vital is NOT re-logged.
      expect(f.length, 1);
      expect(f.single.label, 'Diagnosticado con hipertensión');
      // The vital-valued relation object never minted an entity.
      expect(await entities(), isEmpty);
    });

    test('model failure → no-op, no crash', () async {
      final extractor = RelationExtractor(
        engine: FakeLocalLlmEngine(generateShouldFail: true),
        writer: writer,
        store: store,
        now: () => now,
      );
      await extractor.extractAndWrite('cualquier cosa', 'ok');
      expect(await facts(), isEmpty);
    });
  });
}
