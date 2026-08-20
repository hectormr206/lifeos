// Taking your life OUT of LifeOS.
//
// The app already had encrypted backups and a restore, and both only work back
// INTO LifeOS. There was no way to get your own data out in a form you can
// read without us — which left "tu vida, tu máquina, no su nube" as a sentence
// on the About screen rather than something a person can check.
//
// It also decides whether the paid plan is honest: "si dejas de pagar, tus
// datos siguen siendo tuyos" is not true when the only format they exist in is
// one nobody else can open.
//
// TWO FORMATS, on purpose:
//   * JSON keeps EVERYTHING — the graph, the relationships, the tombstones —
//     and is what another program can import.
//   * CSV is what a person opens in a spreadsheet on a Tuesday without asking
//     anyone for help. Most people will only ever use this one.
library;

import 'dart:convert';

import '../../../core/graph/graph_records.dart';

/// Bumped when the shape changes, so a file exported today still says what it
/// is in two years.
const int kExportSchemaVersion = 1;

/// The whole graph as JSON: nodes, edges, tombstones and all.
String exportGraphAsJson({
  required List<GraphNodeRecord> nodes,
  required List<GraphEdgeRecord> edges,
  required DateTime generatedAt,
}) {
  // ISO-8601 in UTC. "18/08/2026 09:16" in a file is ambiguous forever; the
  // offset is the only thing that keeps it meaning the same on another
  // machine, in another country, years from now.
  String? iso(DateTime? t) => t?.toUtc().toIso8601String();

  final payload = <String, Object?>{
    'app': 'LifeOS',
    'schema': kExportSchemaVersion,
    'exported_at': iso(generatedAt),
    'nodes': [
      for (final n in nodes)
        <String, Object?>{
          'uuid': n.uuid,
          'kind': n.kind,
          'label': n.label,
          'domain': n.domain,
          'data': n.data,
          'created_at': iso(n.createdAt),
          'updated_at': iso(n.updatedAt),
          'occurred_at': iso(n.occurredAt),
          // Tombstones are part of the truth about a graph: leaving them out
          // would make this file disagree with what syncs between the user's
          // own devices.
          'deleted_at': iso(n.deletedAt),
        },
    ],
    'edges': [
      for (final e in edges)
        <String, Object?>{
          'uuid': e.uuid,
          'src': e.srcUuid,
          'dst': e.dstUuid,
          'relation': e.relation,
          'data': e.data,
          'created_at': iso(e.createdAt),
          'deleted_at': iso(e.deletedAt),
        },
    ],
  };
  // Indented: the file is meant to be OPENED and read, not just parsed.
  return const JsonEncoder.withIndent('  ').convert(payload);
}

/// One row per entry, for a spreadsheet.
String exportGraphAsCsv({required List<GraphNodeRecord> nodes}) {
  final buffer = StringBuffer()
    // Header always, even with no rows: a zero-byte file reads as "the export
    // failed".
    ..writeln('fecha,hora,tipo,dominio,label,notas,borrado');

  String cell(Object? value) {
    final text = (value ?? '').toString();
    // Quote anything that would otherwise break the columns. A comma inside a
    // value is the classic way an export looks fine and is quietly corrupt.
    if (!text.contains(RegExp(r'[",\n\r]'))) return text;
    return '"${text.replaceAll('"', '""')}"';
  }

  String two(int n) => n.toString().padLeft(2, '0');

  for (final node in nodes) {
    final at = (node.occurredAt ?? node.createdAt).toUtc();
    buffer.writeln([
      '${at.year}-${two(at.month)}-${two(at.day)}',
      '${two(at.hour)}:${two(at.minute)}',
      cell(node.kind),
      cell(node.domain),
      cell(node.label),
      cell(node.data.isEmpty ? '' : jsonEncode(node.data)),
      node.deletedAt == null ? '' : 'sí',
    ].join(','));
  }
  return buffer.toString();
}
