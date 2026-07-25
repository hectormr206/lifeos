// Proves the NAMED-PERSON hub: a family subject creates a typed
// hub --relation--> person edge, name-learning upgrades the relation-labelled
// node to a real named node (Celia, alias Cely), aliasing merges a duplicate
// into one node, synonyms resolve, and subject resolution reaches the NAMED node.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  Future<List<GraphNodeRecord>> otherPeople() async =>
      (await store.listNodesByKind('person'))
          .where((p) => p.data['role'] != 'user')
          .toList();

  test('ensurePerson wires a typed hub --relation--> person edge', () async {
    final uuid = await writer.ensurePerson('esposa');
    final person = (await otherPeople()).single;
    expect(person.uuid, uuid);
    expect(person.label, 'esposa');
    expect(person.data['relation'], 'esposa');

    // The hub relates to her by the typed relation edge.
    final hub = (await store.listNodesByKind('person'))
        .firstWhere((p) => p.data['role'] == 'user');
    final edges = await store.edgesForNode(hub.uuid, relation: 'esposa');
    expect(edges.single.dstUuid, uuid);
  });

  test('name-learning upgrades the relation node to a NAMED node + alias', () async {
    await writer.ensurePerson('esposa'); // relation-labelled first
    await writer.learnPersonName('esposa', name: 'Celia', alias: 'Cely');

    final people = await otherPeople();
    expect(people.length, 1, reason: 'still ONE person — renamed, not duplicated');
    final celia = people.single;
    expect(celia.label, 'Celia');
    expect(celia.data['relation'], 'esposa');
    expect(celia.data['aliases'], contains('Cely'));
  });

  test('subject resolves to the NAMED node via the typed hub edge', () async {
    await writer.learnPersonName('esposa', name: 'Celia');

    // A later reading tagged with the bare relation attributes to Celia.
    final fact = await writer.writeFact(
      domain: 'health',
      label: 'presión 120/60, pulso 49',
      subject: 'esposa',
    );
    final involves = await store.edgesForNode(fact!.uuid, relation: 'involves');
    final celia = (await otherPeople()).single;
    expect(involves.single.dstUuid, celia.uuid);
    expect(celia.label, 'Celia'); // NAMED node, not a bare "esposa" duplicate
  });

  test('synonym resolves: subject "mujer" reaches the "esposa" person', () async {
    await writer.learnPersonName('esposa', name: 'Celia');
    final fact = await writer.writeFact(
      domain: 'health',
      label: 'presión 118/79',
      subject: 'mujer', // synonym of esposa
    );
    final involves = await store.edgesForNode(fact!.uuid, relation: 'involves');
    expect((await otherPeople()).length, 1);
    expect(involves.single.dstUuid, (await otherPeople()).single.uuid);
  });

  test('registerAlias merges a SEPARATE node labelled with the alias', () async {
    final celia = await writer.learnPersonName('esposa', name: 'Celia');
    // A stray node exists for the nickname (e.g. from an earlier path).
    final stray = await store.createNode(kind: 'person', label: 'Cely');

    await writer.registerAlias(celia, 'Cely');

    expect((await otherPeople()).length, 1, reason: 'stray merged into Celia');
    expect(await store.getNodeByUuid(stray.uuid), isNull); // tombstoned
    final one = (await otherPeople()).single;
    expect(one.label, 'Celia');
    expect(one.data['aliases'], contains('Cely'));
  });

  test('coref NEVER merges two relatives with DIFFERENT relations sharing a name',
      () async {
    // "mi hija se llama Ana" → daughter node named Ana.
    final hija = await writer.learnPersonName('hija', name: 'Ana');
    // The sister exists unnamed from an earlier reading ("de mi hermana …").
    await writer.ensurePerson('hermana');
    // "mi hermana se llama Ana" — SAME first name, DIFFERENT relation: the
    // daughter must survive as her own person (names repeat in a family).
    final hermana = await writer.learnPersonName('hermana', name: 'Ana');

    final people = await otherPeople();
    expect(people.length, 2, reason: 'hija and hermana are two real people');
    expect(hermana, isNot(hija));
    final byUuid = {for (final p in people) p.uuid: p};
    expect(byUuid[hija]!.data['relation'], 'hija');
    expect(byUuid[hermana]!.data['relation'], 'hermana');

    // The typed hub edges still point at the RIGHT nodes.
    final hub = (await store.listNodesByKind('person'))
        .firstWhere((p) => p.data['role'] == 'user');
    expect((await store.edgesForNode(hub.uuid, relation: 'hija')).single.dstUuid, hija);
    expect(
      (await store.edgesForNode(hub.uuid, relation: 'hermana')).single.dstUuid,
      hermana,
    );
  });

  test('registerAlias NEVER swallows a person with a DIFFERENT relation', () async {
    // "mi hermano se llama Beto" → brother named Beto.
    final hermano = await writer.learnPersonName('hermano', name: 'Beto');
    // "a mi papá le decimos Beto" — same nickname, different relation.
    await writer.ensurePerson('papá');
    final papa = await writer.learnPersonName('papá', alias: 'Beto');

    expect((await otherPeople()).length, 2,
        reason: 'the brother must not be merged into papá over a shared alias');
    expect(papa, isNot(hermano));
  });

  test('coref still merges an UNANCHORED node (no relation) into the named one',
      () async {
    final celia = await writer.learnPersonName('esposa', name: 'Celia');
    // A stray extractor-created person with NO relation — a true alias node.
    await store.createNode(kind: 'person', label: 'Celia');

    await writer.learnPersonName('esposa', name: 'Celia');

    expect((await otherPeople()).length, 1,
        reason: 'an unanchored same-name node is a legitimate coref merge');
    expect((await otherPeople()).single.uuid, celia);
  });

  test('fuzzy coref (≥0.9) auto-merges a near-duplicate name', () async {
    final celia = await writer.learnPersonName('esposa', name: 'Celia');
    await store.createNode(kind: 'person', label: 'Celiaa'); // 1-char dup

    // Re-learning the name runs the deterministic coref merge.
    await writer.learnPersonName('esposa', name: 'Celia');

    expect((await otherPeople()).length, 1, reason: 'near-dup auto-merged');
    expect((await otherPeople()).single.uuid, celia);
  });
}
