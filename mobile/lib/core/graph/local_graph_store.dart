import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:lifeos/core/sync/stamping.dart';
import 'package:lifeos/features/sync/data/sync_auto_runner.dart';

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

  // ── Vector recall (roadmap SLICE B1) ──────────────────────────────────────
  //
  // The vector side of the store. The store does the storage + math only; the
  // EMBEDDING step lives OUTSIDE (the caller/`RagService` embeds the text and
  // hands raw vectors in/out). Vectors are LOCAL-ONLY: sync transfers node text
  // (label/data) but NEVER these vectors — each device re-embeds locally, so
  // vectors from different models/devices are never mixed (caveat R8).

  /// Store (insert-or-replace) the embedding for [nodeUuid] under [model].
  ///
  /// [dim] is the vector length and [vec] its float32 values (stored as a
  /// little-endian BLOB). One row per (node, model): re-upserting the same pair
  /// overwrites. [model] + [dim] are persisted on the row so [recall] can filter
  /// to a single model and NEVER compare across models (caveat R8).
  Future<void> upsertNodeVector(
    String nodeUuid,
    String model,
    int dim,
    Float32List vec,
  );

  /// Remove every stored vector for [nodeUuid] (all models). Call when a node is
  /// deleted or re-indexed. Vectors are hard-deleted (never tombstoned): they are
  /// local-only and never synced, and [recall] already hides tombstoned nodes.
  Future<void> deleteNodeVector(String nodeUuid);

  /// Brute-force cosine top-[k] recall over the LIVE (`deleted_at IS NULL`)
  /// vectors of one [model]. Returns the matching nodes, most-similar first.
  ///
  /// The cosine math runs in Dart over every candidate row (fine at on-device
  /// scale; an ANN index is a later slice). [model] filters to a single model —
  /// pass it explicitly. If [model] is null and the store holds vectors from
  /// more than one model, this throws (never silently compares across models —
  /// caveat R8). Rows whose stored `dim` differs from [queryVec]'s length are
  /// skipped as incomparable.
  Future<List<GraphNodeRecord>> recall(
    Float32List queryVec, {
    int k = 5,
    String? model,
  });

  /// Live `fact` nodes that have NO stored vector under [model], oldest-created
  /// first (roadmap SLICE B1b backfill). Used to index pre-existing facts once
  /// the embedder becomes available; a fact indexed under a DIFFERENT model
  /// still counts as missing (caveat R8 — each model needs its own vectors).
  Future<List<GraphNodeRecord>> listFactNodesMissingVector(
    String model, {
    int limit = 32,
  });
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
    // Stamped HERE and not by the sync engine: a row that reaches the table
    // unstamped is invisible to `lamport > cursor` for ever, and no later pass
    // can rescue it because nothing knows it was missed.
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
      originNode: originNode ?? await localOrigin(_db),
      lamport: await nextLamport(_db),
    );
    final id = await _db.insert(kNodesTable, node.toColumns());
    // Tell sync there is something to send, so a note written here travels in
    // seconds instead of waiting out the poll interval.
    syncChangeSignal.changed();
    return node.copyWith(localId: id);
  }

  @override
  Future<GraphNodeRecord> upsertNode(GraphNodeRecord node) async {
    // Bump updated_at on every upsert; preserve created_at/uuid.
    final touched = node.copyWith(
      updatedAt: _now(),
      // An edit is a new authorship by THIS device, so the origin is REPLACED,
      // not defaulted. Keeping the previous author made a genuine two-device
      // disagreement look like one device overwriting its own row: `isConflict`
      // compares origins, so the losing revision was never recorded and the
      // user silently lost an edit.
      originNode: await localOrigin(_db),
      lamport: await nextLamport(_db),
    );
    await _db.insert(
      kNodesTable,
      touched.toColumns(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    syncChangeSignal.changed();
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
      originNode: originNode ?? await localOrigin(_db),
      lamport: await nextLamport(_db),
    );
    final id = await _db.insert(kEdgesTable, edge.toColumns());
    // Tell sync there is something to send, so a note written here travels in
    // seconds instead of waiting out the poll interval.
    syncChangeSignal.changed();
    return edge.copyWith(localId: id);
  }

  @override
  Future<GraphEdgeRecord> upsertEdge(GraphEdgeRecord edge) async {
    final touched = edge.copyWith(
      updatedAt: _now(),
      originNode: await localOrigin(_db),
      lamport: await nextLamport(_db),
    );
    await _db.insert(
      kEdgesTable,
      touched.toColumns(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    syncChangeSignal.changed();
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
    // A GLOBAL next, not `lamport + 1`: a per-row bump can land at or below the
    // graph's high-water mark, and a tombstone that does not clear the peer's
    // cursor never ships — the delete stays local and the row lives on
    // elsewhere for ever.
    final tombstone = await nextLamport(_db);
    final origin = await localOrigin(_db);
    final affected = await _db.rawUpdate(
      'UPDATE $kNodesTable SET deleted_at = ?, updated_at = ?, lamport = ?, '
      'origin_node = ? WHERE uuid = ? AND deleted_at IS NULL',
      [now, now, tombstone, origin, uuid],
    );
    if (affected == 0) return false;
    syncChangeSignal.changed();
    // Tombstone incident edges so a deleted node leaves no dangling live edges.
    await _db.rawUpdate(
      'UPDATE $kEdgesTable SET deleted_at = ?, updated_at = ?, lamport = ?, '
      'origin_node = ? WHERE (src_uuid = ? OR dst_uuid = ?) AND deleted_at IS NULL',
      [now, now, await nextLamport(_db), origin, uuid, uuid],
    );
    return true;
  }

  @override
  Future<bool> softDeleteEdge(String uuid) async {
    final now = _epoch(_now());
    final affected = await _db.rawUpdate(
      'UPDATE $kEdgesTable SET deleted_at = ?, updated_at = ?, lamport = ?, '
      'origin_node = ? WHERE uuid = ? AND deleted_at IS NULL',
      [now, now, await nextLamport(_db), await localOrigin(_db), uuid],
    );
    if (affected > 0) syncChangeSignal.changed();
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

  @override
  Future<void> upsertNodeVector(
    String nodeUuid,
    String model,
    int dim,
    Float32List vec,
  ) async {
    await _db.insert(
      kVecNodesTable,
      <String, Object?>{
        'node_uuid': nodeUuid,
        'model': model,
        'dim': dim,
        'vec': _encodeVector(vec, dim),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteNodeVector(String nodeUuid) async {
    await _db.delete(
      kVecNodesTable,
      where: 'node_uuid = ?',
      whereArgs: [nodeUuid],
    );
  }

  @override
  Future<List<GraphNodeRecord>> recall(
    Float32List queryVec, {
    int k = 5,
    String? model,
  }) async {
    if (k <= 0) return const [];
    // Join to nodes so we (a) skip tombstoned nodes and (b) hydrate full records
    // in one round-trip. Extra vec columns are aliased so they never collide
    // with node columns; GraphNodeRecord.fromRow ignores them.
    final where = StringBuffer('n.deleted_at IS NULL');
    final args = <Object?>[];
    if (model != null) {
      where.write(' AND v.model = ?');
      args.add(model);
    }
    final rows = await _db.rawQuery(
      'SELECT n.*, v.vec AS __vec, v.dim AS __dim, v.model AS __model '
      'FROM $kVecNodesTable v '
      'JOIN $kNodesTable n ON n.uuid = v.node_uuid '
      'WHERE $where',
      args,
    );
    if (rows.isEmpty) return const [];

    // Caveat R8: never compare across models. Without an explicit filter, all
    // candidates must belong to ONE model, else it is a misuse.
    if (model == null) {
      final models = rows.map((r) => r['__model']).toSet();
      if (models.length > 1) {
        throw ArgumentError(
          'recall() spans multiple embedding models ($models). Pass `model:` to '
          'pick one — vectors from different models are not comparable (R8).',
        );
      }
    }

    final scored = <_ScoredRow>[];
    for (final row in rows) {
      final dim = (row['__dim'] as num).toInt();
      if (dim != queryVec.length) continue; // incomparable dimensionality
      final vec = _decodeVector(row['__vec'] as Uint8List, dim);
      scored.add(_ScoredRow(_cosine(queryVec, vec), row));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored
        .take(k)
        .map((s) => GraphNodeRecord.fromRow(s.row))
        .toList();
  }

  @override
  Future<List<GraphNodeRecord>> listFactNodesMissingVector(
    String model, {
    int limit = 32,
  }) async {
    final rows = await _db.rawQuery(
      'SELECT n.* FROM $kNodesTable n '
      "WHERE n.kind = 'fact' AND n.deleted_at IS NULL "
      'AND NOT EXISTS (SELECT 1 FROM $kVecNodesTable v '
      'WHERE v.node_uuid = n.uuid AND v.model = ?) '
      'ORDER BY n.created_at ASC LIMIT ?',
      [model, limit],
    );
    return rows.map(GraphNodeRecord.fromRow).toList();
  }

  /// Encode [vec] (its first [dim] values) as a little-endian float32 BLOB.
  static Uint8List _encodeVector(Float32List vec, int dim) {
    final n = dim <= vec.length ? dim : vec.length;
    final bytes = Uint8List(n * 4);
    final view = ByteData.view(bytes.buffer);
    for (var i = 0; i < n; i++) {
      view.setFloat32(i * 4, vec[i], Endian.little);
    }
    return bytes;
  }

  /// Decode a little-endian float32 BLOB of [dim] values back to a Float32List.
  static Float32List _decodeVector(Uint8List bytes, int dim) {
    final view = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final n = dim * 4 <= bytes.lengthInBytes ? dim : bytes.lengthInBytes ~/ 4;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = view.getFloat32(i * 4, Endian.little);
    }
    return out;
  }

  /// Cosine similarity in `[-1, 1]`; 0 for a zero-magnitude vector.
  static double _cosine(Float32List a, Float32List b) {
    final n = a.length < b.length ? a.length : b.length;
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < n; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
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

/// A candidate node row paired with its cosine score, for in-Dart ranking.
class _ScoredRow {
  const _ScoredRow(this.score, this.row);
  final double score;
  final Map<String, Object?> row;
}
