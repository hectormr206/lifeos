import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'graph_records.dart';
import 'local_graph_schema.dart';

/// Domain-facing API over the on-device property-graph (roadmap SLICE A2).
///
/// This is the foundation later slices build on — memory, RAG, domains, the
/// graph browser (C5), and sync. It intentionally hides SQL behind a typed
/// surface of [GraphNodeRecord] / [GraphEdgeRecord]. It is NOT a UI layer:
/// A2 is the data layer only.
///
/// Deletes are always soft (tombstone via `deleted_at`) so a delete can later
/// propagate to other replicas rather than resurrecting on sync. Every read
/// hides tombstoned rows unless `includeDeleted: true` is passed (sync needs
/// to see tombstones; product code does not).
abstract class LocalGraphStore {
  /// Create a brand-new node with a freshly-minted [GraphNodeRecord.uuid].
  Future<GraphNodeRecord> createNode({
    required String kind,
    required String label,
    Map<String, Object?> data = const <String, Object?>{},
    String? domain,
    DateTime? occurredAt,
    String? createdTz,
    String? originNode,
  });

  /// Insert-or-update a node by its [GraphNodeRecord.uuid]. Used by sync and
  /// by callers that already own a uuid. Bumps `updated_at`.
  Future<GraphNodeRecord> upsertNode(GraphNodeRecord node);

  /// Create a directed edge between two existing nodes (by their uuids).
  Future<GraphEdgeRecord> createEdge({
    required String srcUuid,
    required String dstUuid,
    required String relation,
    Map<String, Object?> data = const <String, Object?>{},
    String? originNode,
  });

  /// Insert-or-update an edge by its [GraphEdgeRecord.uuid].
  Future<GraphEdgeRecord> upsertEdge(GraphEdgeRecord edge);

  /// Fetch a node by its stable sync uuid. Tombstoned rows return null unless
  /// [includeDeleted].
  Future<GraphNodeRecord?> getNodeByUuid(String uuid, {bool includeDeleted = false});

  /// Fetch a node by its local autoincrement rowid.
  Future<GraphNodeRecord?> getNodeByLocalId(int localId, {bool includeDeleted = false});

  /// All live nodes of a given [kind], newest-created first.
  Future<List<GraphNodeRecord>> listNodesByKind(String kind, {int? limit, bool includeDeleted = false});

  /// Edges touching [nodeUuid], filtered by [direction] and optionally
  /// [relation].
  Future<List<GraphEdgeRecord>> edgesForNode(
    String nodeUuid, {
    EdgeDirection direction = EdgeDirection.both,
    String? relation,
    bool includeDeleted = false,
  });

  /// The nodes reachable from [nodeUuid] via one edge hop, filtered the same
  /// way as [edgesForNode]. Skips edges whose far endpoint is missing or
  /// tombstoned.
  Future<List<GraphNodeRecord>> neighbors(
    String nodeUuid, {
    EdgeDirection direction = EdgeDirection.outgoing,
    String? relation,
  });

  /// Soft-delete a node and tombstone every edge incident to it. Returns
  /// true if a live node row was found and tombstoned.
  Future<bool> softDeleteNode(String uuid);

  /// Soft-delete a single edge. Returns true if a live edge was tombstoned.
  Future<bool> softDeleteEdge(String uuid);

  /// Lexical substring search over node `label` + `data`, newest-created
  /// first. A stand-in until the FTS5 slice (B1); a blank query returns `[]`.
  Future<List<GraphNodeRecord>> searchNodes(String query, {int limit = 20, bool includeDeleted = false});
}

/// sqflite-backed [LocalGraphStore]. Works identically against an on-device
/// SQLCipher database (production) and a host-side standard-sqlite database
/// (`sqflite_common_ffi`, tests): all SQL is portable between the two.
class SqfliteLocalGraphStore implements LocalGraphStore {
  SqfliteLocalGraphStore(
    this._db, {
    Uuid? uuidGen,
    DateTime Function()? clock,
  })  : _uuid = uuidGen ?? const Uuid(),
        _now = clock ?? DateTime.now;

  final DatabaseExecutor _db;
  final Uuid _uuid;
  final DateTime Function() _now;

  double _epoch(DateTime t) => t.toUtc().millisecondsSinceEpoch / 1000.0;

  @override
  Future<GraphNodeRecord> createNode({
    required String kind,
    required String label,
    Map<String, Object?> data = const <String, Object?>{},
    String? domain,
    DateTime? occurredAt,
    String? createdTz,
    String? originNode,
  }) async {
    final now = _now();
    final node = GraphNodeRecord(
      uuid: _uuid.v4(),
      kind: kind,
      label: label,
      data: data,
      domain: domain,
      occurredAt: occurredAt,
      createdAt: now,
      updatedAt: now,
      createdTz: createdTz,
      originNode: originNode,
    );
    final id = await _db.insert(kNodesTable, node.toColumns());
    return node.copyWith(localId: id);
  }

  @override
  Future<GraphNodeRecord> upsertNode(GraphNodeRecord node) async {
    // Bump updated_at on every upsert; preserve created_at/uuid.
    final touched = node.copyWith(updatedAt: _now());
    await _db.insert(
      kNodesTable,
      touched.toColumns(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    final stored = await getNodeByUuid(node.uuid, includeDeleted: true);
    return stored ?? touched;
  }

  @override
  Future<GraphEdgeRecord> createEdge({
    required String srcUuid,
    required String dstUuid,
    required String relation,
    Map<String, Object?> data = const <String, Object?>{},
    String? originNode,
  }) async {
    final now = _now();
    final edge = GraphEdgeRecord(
      uuid: _uuid.v4(),
      srcUuid: srcUuid,
      dstUuid: dstUuid,
      relation: relation,
      data: data,
      createdAt: now,
      updatedAt: now,
      originNode: originNode,
    );
    final id = await _db.insert(kEdgesTable, edge.toColumns());
    return edge.copyWith(localId: id);
  }

  @override
  Future<GraphEdgeRecord> upsertEdge(GraphEdgeRecord edge) async {
    final touched = edge.copyWith(updatedAt: _now());
    await _db.insert(
      kEdgesTable,
      touched.toColumns(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    final stored = await _edgeByUuid(edge.uuid, includeDeleted: true);
    return stored ?? touched;
  }

  @override
  Future<GraphNodeRecord?> getNodeByUuid(String uuid, {bool includeDeleted = false}) async {
    final rows = await _db.query(
      kNodesTable,
      where: includeDeleted ? 'uuid = ?' : 'uuid = ? AND deleted_at IS NULL',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return GraphNodeRecord.fromRow(rows.first);
  }

  @override
  Future<GraphNodeRecord?> getNodeByLocalId(int localId, {bool includeDeleted = false}) async {
    final rows = await _db.query(
      kNodesTable,
      where: includeDeleted ? 'id = ?' : 'id = ? AND deleted_at IS NULL',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return GraphNodeRecord.fromRow(rows.first);
  }

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind, {int? limit, bool includeDeleted = false}) async {
    final rows = await _db.query(
      kNodesTable,
      where: includeDeleted ? 'kind = ?' : 'kind = ? AND deleted_at IS NULL',
      whereArgs: [kind],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(GraphNodeRecord.fromRow).toList();
  }

  @override
  Future<List<GraphEdgeRecord>> edgesForNode(
    String nodeUuid, {
    EdgeDirection direction = EdgeDirection.both,
    String? relation,
    bool includeDeleted = false,
  }) async {
    final clauses = <String>[];
    final args = <Object?>[];

    switch (direction) {
      case EdgeDirection.outgoing:
        clauses.add('src_uuid = ?');
        args.add(nodeUuid);
      case EdgeDirection.incoming:
        clauses.add('dst_uuid = ?');
        args.add(nodeUuid);
      case EdgeDirection.both:
        clauses.add('(src_uuid = ? OR dst_uuid = ?)');
        args..add(nodeUuid)..add(nodeUuid);
    }
    if (relation != null) {
      clauses.add('relation = ?');
      args.add(relation);
    }
    if (!includeDeleted) {
      clauses.add('deleted_at IS NULL');
    }

    final rows = await _db.query(
      kEdgesTable,
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
    return rows.map(GraphEdgeRecord.fromRow).toList();
  }

  @override
  Future<List<GraphNodeRecord>> neighbors(
    String nodeUuid, {
    EdgeDirection direction = EdgeDirection.outgoing,
    String? relation,
  }) async {
    final edges = await edgesForNode(nodeUuid, direction: direction, relation: relation);
    final result = <GraphNodeRecord>[];
    final seen = <String>{};
    for (final edge in edges) {
      final otherUuid = edge.srcUuid == nodeUuid ? edge.dstUuid : edge.srcUuid;
      if (otherUuid == nodeUuid || !seen.add(otherUuid)) continue;
      final node = await getNodeByUuid(otherUuid);
      if (node != null) result.add(node);
    }
    return result;
  }

  @override
  Future<bool> softDeleteNode(String uuid) async {
    final now = _epoch(_now());
    final affected = await _db.rawUpdate(
      'UPDATE $kNodesTable SET deleted_at = ?, updated_at = ?, lamport = lamport + 1 '
      'WHERE uuid = ? AND deleted_at IS NULL',
      [now, now, uuid],
    );
    if (affected == 0) return false;
    // Tombstone incident edges so a deleted node leaves no dangling live edges.
    await _db.rawUpdate(
      'UPDATE $kEdgesTable SET deleted_at = ?, updated_at = ?, lamport = lamport + 1 '
      'WHERE (src_uuid = ? OR dst_uuid = ?) AND deleted_at IS NULL',
      [now, now, uuid, uuid],
    );
    return true;
  }

  @override
  Future<bool> softDeleteEdge(String uuid) async {
    final now = _epoch(_now());
    final affected = await _db.rawUpdate(
      'UPDATE $kEdgesTable SET deleted_at = ?, updated_at = ?, lamport = lamport + 1 '
      'WHERE uuid = ? AND deleted_at IS NULL',
      [now, now, uuid],
    );
    return affected > 0;
  }

  @override
  Future<List<GraphNodeRecord>> searchNodes(String query, {int limit = 20, bool includeDeleted = false}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final like = '%${_escapeLike(trimmed)}%';
    final deletedClause = includeDeleted ? '' : ' AND deleted_at IS NULL';
    final rows = await _db.query(
      kNodesTable,
      where: "(label LIKE ? ESCAPE '\\' OR data LIKE ? ESCAPE '\\')$deletedClause",
      whereArgs: [like, like],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(GraphNodeRecord.fromRow).toList();
  }

  Future<GraphEdgeRecord?> _edgeByUuid(String uuid, {bool includeDeleted = false}) async {
    final rows = await _db.query(
      kEdgesTable,
      where: includeDeleted ? 'uuid = ?' : 'uuid = ? AND deleted_at IS NULL',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return GraphEdgeRecord.fromRow(rows.first);
  }

  /// Escape LIKE wildcards so a user's `%`/`_`/`\` are matched literally.
  static String _escapeLike(String input) => input
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
