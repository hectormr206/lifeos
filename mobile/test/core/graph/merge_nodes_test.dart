// Merging two nodes that are the same person, from the Cerebro's "Fusionar
// con…".
//
// A graph built from conversation WILL hold duplicates: "Ana" typed on Monday
// and "ana" dictated on Tuesday are two nodes about one person, and every
// relationship the user cares about is split across both. The desktop Cerebro
// let you join them; that is the whole reason it felt like a brain and not a
// list.
//
// The dangerous part is not the join, it is the EDGES. A merge that drops them
// silently deletes relationships the user never asked to lose — and since the
// merge syncs, it deletes them on every device at once.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
  });
  tearDown(() async => db.close());

  test('the loser is gone and the winner remains', () async {
    final keep = await store.createNode(kind: 'person', label: 'Ana');
    final dupe = await store.createNode(kind: 'person', label: 'ana');

    expect(await store.mergeNodes(loserUuid: dupe.uuid, winnerUuid: keep.uuid),
        isTrue);

    expect(await store.getNodeByUuid(dupe.uuid), isNull);
    expect(await store.getNodeByUuid(keep.uuid), isNotNull);
  });

  test('every relationship of the loser survives on the winner', () async {
    // The reason this operation is worth writing carefully.
    final keep = await store.createNode(kind: 'person', label: 'Ana');
    final dupe = await store.createNode(kind: 'person', label: 'ana');
    final walk = await store.createNode(kind: 'event', label: 'caminata');
    final city = await store.createNode(kind: 'place', label: 'Puebla');

    await store.createEdge(
        srcUuid: dupe.uuid, dstUuid: walk.uuid, relation: 'participo');
    await store.createEdge(
        srcUuid: city.uuid, dstUuid: dupe.uuid, relation: 'vive');

    await store.mergeNodes(loserUuid: dupe.uuid, winnerUuid: keep.uuid);

    final around = await store.neighbors(keep.uuid, direction: EdgeDirection.both);
    expect([for (final n in around) n.label]..sort(), ['Puebla', 'caminata'],
        reason: 'a merge that loses edges silently deletes relationships');
  });

  test('the direction of each relationship is kept', () async {
    // "Ana vive en Puebla" is not "Puebla vive en Ana".
    final keep = await store.createNode(kind: 'person', label: 'Ana');
    final dupe = await store.createNode(kind: 'person', label: 'ana');
    final city = await store.createNode(kind: 'place', label: 'Puebla');
    await store.createEdge(
        srcUuid: dupe.uuid, dstUuid: city.uuid, relation: 'vive');

    await store.mergeNodes(loserUuid: dupe.uuid, winnerUuid: keep.uuid);

    final out =
        await store.neighbors(keep.uuid, direction: EdgeDirection.outgoing);
    final into =
        await store.neighbors(keep.uuid, direction: EdgeDirection.incoming);
    expect([for (final n in out) n.label], ['Puebla']);
    expect(into, isEmpty);
  });

  test('an edge BETWEEN the two never becomes a loop on the winner', () async {
    // "ana es la misma que Ana" would re-point to "Ana → Ana": a node related
    // to itself, which the renderer draws as a stray dot and means nothing.
    final keep = await store.createNode(kind: 'person', label: 'Ana');
    final dupe = await store.createNode(kind: 'person', label: 'ana');
    await store.createEdge(
        srcUuid: dupe.uuid, dstUuid: keep.uuid, relation: 'misma');

    await store.mergeNodes(loserUuid: dupe.uuid, winnerUuid: keep.uuid);

    expect(await store.edgesForNode(keep.uuid), isEmpty);
  });

  test('a relationship both already had is not duplicated', () async {
    final keep = await store.createNode(kind: 'person', label: 'Ana');
    final dupe = await store.createNode(kind: 'person', label: 'ana');
    final city = await store.createNode(kind: 'place', label: 'Puebla');
    await store.createEdge(
        srcUuid: keep.uuid, dstUuid: city.uuid, relation: 'vive');
    await store.createEdge(
        srcUuid: dupe.uuid, dstUuid: city.uuid, relation: 'vive');

    await store.mergeNodes(loserUuid: dupe.uuid, winnerUuid: keep.uuid);

    expect(await store.edgesForNode(keep.uuid), hasLength(1));
  });

  test('merging a node into itself changes nothing and says so', () async {
    final keep = await store.createNode(kind: 'person', label: 'Ana');
    final city = await store.createNode(kind: 'place', label: 'Puebla');
    await store.createEdge(
        srcUuid: keep.uuid, dstUuid: city.uuid, relation: 'vive');

    expect(await store.mergeNodes(loserUuid: keep.uuid, winnerUuid: keep.uuid),
        isFalse);

    // And above all it did NOT delete the node — the same uuid twice is a
    // plausible slip in a picker, and answering it with "your node is gone"
    // would be the worst possible outcome.
    expect(await store.getNodeByUuid(keep.uuid), isNotNull);
    expect(await store.edgesForNode(keep.uuid), hasLength(1));
  });

  test('a node that does not exist is refused, not half-applied', () async {
    final keep = await store.createNode(kind: 'person', label: 'Ana');

    expect(
      await store.mergeNodes(loserUuid: 'no-existe', winnerUuid: keep.uuid),
      isFalse,
    );
    expect(
      await store.mergeNodes(loserUuid: keep.uuid, winnerUuid: 'no-existe'),
      isFalse,
    );
    expect(await store.getNodeByUuid(keep.uuid), isNotNull,
        reason: 'a refused merge must not have deleted anything');
  });

  test('the merge is stamped so it reaches the other devices', () async {
    // A merge that stays local means the phone shows one Ana and the laptop
    // shows two, for ever. Every write here goes through the same lamport
    // stamping as an ordinary edit.
    final keep = await store.createNode(kind: 'person', label: 'Ana');
    final dupe = await store.createNode(kind: 'person', label: 'ana');
    final city = await store.createNode(kind: 'place', label: 'Puebla');
    await store.createEdge(
        srcUuid: dupe.uuid, dstUuid: city.uuid, relation: 'vive');
    final before = await store.getNodeByUuid(dupe.uuid);

    await store.mergeNodes(loserUuid: dupe.uuid, winnerUuid: keep.uuid);

    final tomb =
        await store.getNodeByUuid(dupe.uuid, includeDeleted: true);
    expect(tomb!.lamport, greaterThan(before!.lamport));
    for (final e in await store.edgesForNode(keep.uuid)) {
      expect(e.lamport, greaterThan(0));
      expect(e.originNode, isNotNull);
    }
  });
}
