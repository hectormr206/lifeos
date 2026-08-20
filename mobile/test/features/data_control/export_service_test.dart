// The export contains what the user actually has.
//
// The format is pinned in domain/export_test.dart. This checks the part that
// reads the graph: that nothing is quietly left behind, which is the failure
// nobody notices until they need the file.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/data_control/data/export_service.dart';

class _FakeStore implements LocalGraphStore {
  _FakeStore(this.nodes, [this.edges = const []]);

  final List<GraphNodeRecord> nodes;
  final List<GraphEdgeRecord> edges;

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind,
      {int? limit, bool includeDeleted = false}) async {
    return [
      for (final n in nodes)
        if (n.kind == kind && (includeDeleted || !n.isDeleted)) n,
    ];
  }

  @override
  Future<List<GraphEdgeRecord>> edgesForNode(String nodeUuid,
      {EdgeDirection direction = EdgeDirection.both,
      String? relation,
      bool includeDeleted = false}) async {
    return [
      for (final e in edges)
        if (e.srcUuid == nodeUuid || e.dstUuid == nodeUuid) e,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<List<GraphNodeRecord>> recall(Float32List queryVec,
          {int k = 5, String? model}) =>
      throw UnimplementedError();
}

void main() {
  final now = DateTime.utc(2026, 8, 19, 12);

  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('lifeos-x-'));
  tearDown(() async => temp.delete(recursive: true));

  ExportService service(LocalGraphStore store) =>
      ExportService(store, now: () => now, directory: () async => temp);

  GraphNodeRecord node(String uuid, String kind, String label,
          {DateTime? deletedAt}) =>
      GraphNodeRecord(
        uuid: uuid,
        kind: kind,
        label: label,
        createdAt: now,
        updatedAt: now,
        deletedAt: deletedAt,
      );

  test('every kind of thing is exported, not just facts', () async {
    // People and conversations are as much "your data" as a weight reading.
    final store = _FakeStore([
      node('f1', 'fact', 'peso 82 kg'),
      node('p1', 'person', 'Juan'),
      node('c1', 'conversation', 'hola'),
      node('r1', 'reminder', 'comprar pan'),
    ]);

    final file = await service(store).writeExport(ExportFormat.json);
    final text = await file.readAsString();

    for (final expected in ['peso 82 kg', 'Juan', 'hola', 'comprar pan']) {
      expect(text, contains(expected), reason: '$expected quedó fuera');
    }
  });

  test('deleted rows are in the file, marked', () async {
    final store = _FakeStore([
      node('f1', 'fact', 'algo que borré', deletedAt: now),
    ]);

    final text = await (await service(store).writeExport(ExportFormat.json))
        .readAsString();

    expect(text, contains('algo que borré'));
    expect(text, contains('deleted_at'));
  });

  test('the CSV carries the same entries', () async {
    final store = _FakeStore([node('f1', 'fact', 'peso 82 kg')]);

    final text = await (await service(store).writeExport(ExportFormat.csv))
        .readAsString();

    expect(text, contains('peso 82 kg'));
  });

  test('the file is named with the date, so two exports do not collide',
      () async {
    final file = await service(_FakeStore(const [])).writeExport(ExportFormat.csv);

    expect(file.path, contains('20260819'));
    expect(file.path, endsWith('.csv'));
  });

  test('an empty graph still produces a file', () async {
    // Someone who exports on day one gets a header, not a crash.
    final file = await service(_FakeStore(const [])).writeExport(ExportFormat.csv);

    expect(await file.exists(), isTrue);
    expect((await file.readAsString()).trim(), isNotEmpty);
  });
}
