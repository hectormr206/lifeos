/// Typed, domain-facing rows of the on-device graph store (roadmap SLICE A2).
///
/// These mirror the `nodes` / `edges` tables in `local_graph_schema.dart`
/// (themselves ported from `axi/src/axi/store.py`). Timestamps are Dart
/// [DateTime]s at the API boundary; on disk they are Unix-epoch REALs
/// (seconds, UTC) — exactly store.py's `time.time()` convention — so the two
/// graphs stay wire-compatible for the eventual sync.
library;

import 'dart:convert';

double _toEpoch(DateTime t) => t.toUtc().millisecondsSinceEpoch / 1000.0;

DateTime _fromEpoch(num seconds) =>
    DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round(), isUtc: true);

DateTime? _fromEpochOrNull(Object? seconds) =>
    seconds is num ? _fromEpoch(seconds) : null;

Map<String, Object?> _decodeData(Object? raw) {
  if (raw is! String || raw.isEmpty) return const <String, Object?>{};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
  } catch (_) {
    // A single malformed JSON blob must never break decoding the rest of the
    // graph (same corruption-tolerance stance as core/outbox).
    return const <String, Object?>{};
  }
}

/// A stored graph node (entity/fact/event/conversation/…).
class GraphNodeRecord {
  const GraphNodeRecord({
    required this.uuid,
    required this.kind,
    required this.label,
    this.data = const <String, Object?>{},
    this.domain,
    this.occurredAt,
    required this.createdAt,
    required this.updatedAt,
    this.createdTz,
    this.originNode,
    this.lamport = 0,
    this.deletedAt,
    this.localId,
  });

  /// Local autoincrement rowid — null before the row is persisted.
  final int? localId;

  /// Stable, globally-unique sync id. The identity used by edges and sync.
  final String uuid;

  final String kind;
  final String label;
  final Map<String, Object?> data;
  final String? domain;
  final DateTime? occurredAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdTz;

  /// Sync provenance: which replica/device authored this row.
  final String? originNode;

  /// Sync logical clock (last-writer-wins).
  final int lamport;

  /// Tombstone: non-null once soft-deleted.
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  GraphNodeRecord copyWith({
    int? localId,
    String? kind,
    String? label,
    Map<String, Object?>? data,
    String? domain,
    DateTime? occurredAt,
    DateTime? updatedAt,
    String? createdTz,
    String? originNode,
    int? lamport,
    DateTime? deletedAt,
  }) =>
      GraphNodeRecord(
        localId: localId ?? this.localId,
        uuid: uuid,
        kind: kind ?? this.kind,
        label: label ?? this.label,
        data: data ?? this.data,
        domain: domain ?? this.domain,
        occurredAt: occurredAt ?? this.occurredAt,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        createdTz: createdTz ?? this.createdTz,
        originNode: originNode ?? this.originNode,
        lamport: lamport ?? this.lamport,
        deletedAt: deletedAt ?? this.deletedAt,
      );

  /// Column map for an INSERT/UPDATE (excludes the autoincrement `id`).
  Map<String, Object?> toColumns() => <String, Object?>{
        'uuid': uuid,
        'kind': kind,
        'label': label,
        'data': jsonEncode(data),
        'domain': domain,
        'occurred_at': occurredAt == null ? null : _toEpoch(occurredAt!),
        'created_at': _toEpoch(createdAt),
        'updated_at': _toEpoch(updatedAt),
        'created_tz': createdTz,
        'origin_node': originNode,
        'lamport': lamport,
        'deleted_at': deletedAt == null ? null : _toEpoch(deletedAt!),
      };

  static GraphNodeRecord fromRow(Map<String, Object?> row) => GraphNodeRecord(
        localId: (row['id'] as num?)?.toInt(),
        uuid: row['uuid'] as String,
        kind: row['kind'] as String? ?? '',
        label: row['label'] as String? ?? '',
        data: _decodeData(row['data']),
        domain: row['domain'] as String?,
        occurredAt: _fromEpochOrNull(row['occurred_at']),
        createdAt: _fromEpoch((row['created_at'] as num?) ?? 0),
        updatedAt: _fromEpoch((row['updated_at'] as num?) ?? 0),
        createdTz: row['created_tz'] as String?,
        originNode: row['origin_node'] as String?,
        lamport: (row['lamport'] as num?)?.toInt() ?? 0,
        deletedAt: _fromEpochOrNull(row['deleted_at']),
      );

  @override
  String toString() => 'GraphNodeRecord(uuid: $uuid, kind: $kind, label: $label)';
}

/// A stored directed edge between two nodes, referenced by their `uuid`s.
class GraphEdgeRecord {
  const GraphEdgeRecord({
    required this.uuid,
    required this.srcUuid,
    required this.dstUuid,
    required this.relation,
    this.data = const <String, Object?>{},
    required this.createdAt,
    required this.updatedAt,
    this.originNode,
    this.lamport = 0,
    this.deletedAt,
    this.localId,
  });

  final int? localId;
  final String uuid;
  final String srcUuid;
  final String dstUuid;
  final String relation;
  final Map<String, Object?> data;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? originNode;
  final int lamport;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  GraphEdgeRecord copyWith({
    int? localId,
    String? relation,
    Map<String, Object?>? data,
    DateTime? updatedAt,
    String? originNode,
    int? lamport,
    DateTime? deletedAt,
  }) =>
      GraphEdgeRecord(
        localId: localId ?? this.localId,
        uuid: uuid,
        srcUuid: srcUuid,
        dstUuid: dstUuid,
        relation: relation ?? this.relation,
        data: data ?? this.data,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        originNode: originNode ?? this.originNode,
        lamport: lamport ?? this.lamport,
        deletedAt: deletedAt ?? this.deletedAt,
      );

  Map<String, Object?> toColumns() => <String, Object?>{
        'uuid': uuid,
        'src_uuid': srcUuid,
        'dst_uuid': dstUuid,
        'relation': relation,
        'data': jsonEncode(data),
        'created_at': _toEpoch(createdAt),
        'updated_at': _toEpoch(updatedAt),
        'origin_node': originNode,
        'lamport': lamport,
        'deleted_at': deletedAt == null ? null : _toEpoch(deletedAt!),
      };

  static GraphEdgeRecord fromRow(Map<String, Object?> row) => GraphEdgeRecord(
        localId: (row['id'] as num?)?.toInt(),
        uuid: row['uuid'] as String,
        srcUuid: row['src_uuid'] as String,
        dstUuid: row['dst_uuid'] as String,
        relation: row['relation'] as String? ?? '',
        data: _decodeData(row['data']),
        createdAt: _fromEpoch((row['created_at'] as num?) ?? 0),
        updatedAt: _fromEpoch((row['updated_at'] as num?) ?? 0),
        originNode: row['origin_node'] as String?,
        lamport: (row['lamport'] as num?)?.toInt() ?? 0,
        deletedAt: _fromEpochOrNull(row['deleted_at']),
      );

  @override
  String toString() =>
      'GraphEdgeRecord(uuid: $uuid, $srcUuid -[$relation]-> $dstUuid)';
}

/// Direction filter for edge traversal.
enum EdgeDirection {
  /// Edges whose `src_uuid` is the node (node → other).
  outgoing,

  /// Edges whose `dst_uuid` is the node (other → node).
  incoming,

  /// Either direction.
  both,
}
