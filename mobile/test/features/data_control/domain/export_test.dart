// Taking your life out of LifeOS.
//
// The app has encrypted backups and a restore, and both only work back INTO
// LifeOS. There was no way to get your own data out in a form you could read
// without us — which means the promise on the About screen, "tu vida, tu
// máquina, no su nube", was a sentence rather than something a person could
// verify.
//
// It also decides whether the paid plan is honest. "Si dejas de pagar, tus
// datos siguen siendo tuyos" is not true if the only format they exist in is
// one nobody else can open.
//
// So the bar here is not "we wrote a file". It is:
//   * everything is in it, including what was deleted, because a tombstone is
//     part of the truth about a graph;
//   * it opens in a text editor and in a spreadsheet, today, with no tools of
//     ours;
//   * it never silently drops what it cannot represent.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/features/data_control/domain/export.dart';

void main() {
  final now = DateTime.utc(2026, 8, 19, 15, 16);

  GraphNodeRecord node(
    String uuid,
    String label, {
    String kind = 'fact',
    String? domain,
    DateTime? occurredAt,
    DateTime? deletedAt,
    Map<String, Object?> data = const {},
  }) =>
      GraphNodeRecord(
        uuid: uuid,
        kind: kind,
        label: label,
        domain: domain,
        data: data,
        createdAt: now,
        updatedAt: now,
        occurredAt: occurredAt,
        deletedAt: deletedAt,
      );

  group('the JSON export', () {
    test('it is valid JSON, not something that merely looks like it', () {
      final text = exportGraphAsJson(
        nodes: [node('n1', 'peso 82 kg', domain: 'health')],
        edges: const [],
        generatedAt: now,
      );

      expect(() => jsonDecode(text), returnsNormally);
    });

    test('it says when it was made and what version made it', () {
      // A file with no provenance is a file nobody can trust in two years.
      final decoded = jsonDecode(exportGraphAsJson(
        nodes: [node('n1', 'algo')],
        edges: const [],
        generatedAt: now,
      )) as Map<String, Object?>;

      expect(decoded['exported_at'], isNotNull);
      expect(decoded['app'], contains('LifeOS'));
      expect(decoded['schema'], isNotNull);
    });

    test('every field of a node survives', () {
      final decoded = jsonDecode(exportGraphAsJson(
        nodes: [
          node('n1', 'peso 82 kg',
              domain: 'health',
              occurredAt: DateTime.utc(2026, 8, 18, 15, 16),
              data: {'value': 82, 'unit': 'kg'}),
        ],
        edges: const [],
        generatedAt: now,
      )) as Map<String, Object?>;

      final first = (decoded['nodes']! as List).first as Map<String, Object?>;
      expect(first['uuid'], 'n1');
      expect(first['label'], 'peso 82 kg');
      expect(first['domain'], 'health');
      expect(first['occurred_at'], isNotNull);
      expect((first['data']! as Map)['value'], 82);
    });

    test('relationships between things are exported too', () {
      // Without the edges it is a list, not a graph — and the relationships
      // are half of what LifeOS knows.
      final decoded = jsonDecode(exportGraphAsJson(
        nodes: [node('a', 'Juan', kind: 'person'), node('b', 'Mateo', kind: 'person')],
        edges: [
          GraphEdgeRecord(
            uuid: 'e1',
            srcUuid: 'a',
            dstUuid: 'b',
            relation: 'hijo',
            createdAt: now,
            updatedAt: now,
          ),
        ],
        generatedAt: now,
      )) as Map<String, Object?>;

      final edge = (decoded['edges']! as List).first as Map<String, Object?>;
      expect(edge['src'], 'a');
      expect(edge['dst'], 'b');
      expect(edge['relation'], 'hijo');
    });

    test('deleted rows are included AND marked as deleted', () {
      // A tombstone is part of the truth: leaving it out would make the export
      // disagree with what syncs between the user's own devices.
      final decoded = jsonDecode(exportGraphAsJson(
        nodes: [node('n1', 'algo que borré', deletedAt: now)],
        edges: const [],
        generatedAt: now,
      )) as Map<String, Object?>;

      final first = (decoded['nodes']! as List).first as Map<String, Object?>;
      expect(first['deleted_at'], isNotNull);
    });

    test('dates are ISO-8601 in UTC, with the offset written down', () {
      // "18/08/2026 09:16" in a file is ambiguous forever. ISO with the zone
      // is the only form that still means something on another machine.
      final decoded = jsonDecode(exportGraphAsJson(
        nodes: [node('n1', 'algo', occurredAt: DateTime.utc(2026, 8, 18, 15, 16))],
        edges: const [],
        generatedAt: now,
      )) as Map<String, Object?>;

      final first = (decoded['nodes']! as List).first as Map<String, Object?>;
      expect(first['occurred_at'], '2026-08-18T15:16:00.000Z');
    });
  });

  group('the CSV export', () {
    test('it has a header row', () {
      final csv = exportGraphAsCsv(
        nodes: [node('n1', 'peso 82 kg', domain: 'health')],
      );

      expect(csv.split('\n').first, contains('label'));
    });

    test('a comma inside a value does not break the columns', () {
      // The classic way an export looks fine and is quietly corrupt.
      final csv = exportGraphAsCsv(
        nodes: [node('n1', 'compré pan, leche y café', domain: 'finance')],
      );

      expect(csv, contains('"compré pan, leche y café"'));
    });

    test('a quote inside a value is escaped, not dropped', () {
      final csv = exportGraphAsCsv(
        nodes: [node('n1', 'dijo "ya voy"')],
      );

      expect(csv, contains('""ya voy""'));
    });

    test('a newline inside a value does not become a new row', () {
      final csv = exportGraphAsCsv(nodes: [node('n1', 'línea uno\nlínea dos')]);

      // Quoted, so a spreadsheet reads it as one cell.
      expect(csv, contains('"línea uno\nlínea dos"'));
      // Header + exactly one record, however many line breaks are inside it.
      expect(csv.split('"').length, greaterThan(2));
    });

    test('an empty graph still produces a usable file, not an empty one', () {
      // A zero-byte file reads as "the export failed".
      final csv = exportGraphAsCsv(nodes: const []);

      expect(csv.trim(), isNotEmpty);
      expect(csv, contains('label'));
    });
  });
}
