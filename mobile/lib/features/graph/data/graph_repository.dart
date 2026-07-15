import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../domain/graph_neighborhood.dart';
import '../domain/graph_node.dart';
import '../domain/graph_node_detail.dart';

/// Raised when a graph endpoint fails (non-2xx, network error). [message]
/// is user-facing (Spanish).
class GraphException implements Exception {
  GraphException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's knowledge-graph browser endpoints
/// (`axi/src/axi/dashboard.py`: `graph_search`, `graph_node_detail`,
/// `graph_node_neighborhood`). Abstract so the notifiers/tests can depend on
/// a fake without a live engine.
abstract class GraphRepository {
  /// GET `/api/v1/graph/search?q=&limit=` -> `[{id, label, kind, domain,
  /// aliases}]`. A blank [query] returns `[]` without hitting the network
  /// (mirrors the engine, which already returns `[]` for an empty `q`).
  Future<List<GraphNode>> search(String query, {int limit = 20});

  /// GET `/api/v1/graph/node/{id}` -> `{node, facts, relations,
  /// conversations}`. Offline read-through cached under `graph:node:{id}`.
  Future<GraphNodeDetail> node(int id);

  /// GET `/api/v1/graph/node/{id}/neighborhood` -> `{nodes, edges,
  /// truncated}`. See [GraphNeighborhood]'s fork-decision doc comment —
  /// kept for API parity, not wired into the browser UI this slice.
  Future<GraphNeighborhood> neighborhood(int id);
}

class HttpGraphRepository implements GraphRepository {
  HttpGraphRepository(this._dio, {ResponseCache? cache, ConnectivityReporter? connectivity})
      : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter();

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;

  /// Offline read cache key (M3 slice 1 convention) — one per node id.
  String _nodeCacheKeyFor(int id) => 'graph:node:$id';

  @override
  Future<List<GraphNode>> search(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    try {
      final response = await _dio.get<List<Object?>>(
        '/api/v1/graph/search',
        queryParameters: {'q': trimmed, 'limit': limit},
      );
      final rows = response.data ?? const [];
      return rows.whereType<Map>().map((row) => _parseNode(Map<String, Object?>.from(row))).toList();
    } on DioException catch (error) {
      throw GraphException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  @override
  Future<GraphNodeDetail> node(int id) async {
    final cacheKey = _nodeCacheKeyFor(id);
    try {
      final response = await _dio.get<Map<String, Object?>>('/api/v1/graph/node/$id');
      final body = response.data ?? const <String, Object?>{};
      _connectivity.reportOnline();
      await _cache.put(cacheKey, body);
      return _parseNodeDetail(body);
    } on DioException catch (error) {
      final cached = await _cache.get(cacheKey);
      if (cached is Map) {
        final fetchedAt = await _cache.fetchedAt(cacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return _parseNodeDetail(Map<String, Object?>.from(cached));
      }
      _connectivity.reportOffline();
      throw GraphException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  @override
  Future<GraphNeighborhood> neighborhood(int id) async {
    try {
      final response = await _dio.get<Map<String, Object?>>('/api/v1/graph/node/$id/neighborhood');
      final body = response.data ?? const <String, Object?>{};
      return _parseNeighborhood(body);
    } on DioException catch (error) {
      throw GraphException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  GraphNode _parseNode(Map<String, Object?> row) => GraphNode(
        id: (row['id'] as num?)?.toInt() ?? 0,
        label: row['label'] as String? ?? '',
        kind: row['kind'] as String? ?? '',
        domain: row['domain'] as String? ?? '',
        aliases: (row['aliases'] as List?)?.whereType<String>().toList() ?? const [],
      );

  GraphNodeDetail _parseNodeDetail(Map<String, Object?> body) {
    final nodeRow = Map<String, Object?>.from((body['node'] as Map?) ?? const {});
    final dataRaw = nodeRow['data'];
    final node = GraphNodeInfo(
      id: (nodeRow['id'] as num?)?.toInt() ?? 0,
      kind: nodeRow['kind'] as String? ?? '',
      label: nodeRow['label'] as String? ?? '',
      domain: nodeRow['domain'] as String?,
      createdAt: DateTime.tryParse(nodeRow['created_at'] as String? ?? ''),
      occurredAt: DateTime.tryParse(nodeRow['occurred_at'] as String? ?? ''),
      data: dataRaw is Map ? Map<String, Object?>.from(dataRaw) : const {},
    );

    final facts = ((body['facts'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (row) => GraphFact(
            id: (row['id'] as num?)?.toInt() ?? 0,
            label: row['label'] as String? ?? '',
            createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
          ),
        )
        .toList();

    final relations = ((body['relations'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (row) => GraphRelation(
            edgeId: (row['edge_id'] as num?)?.toInt() ?? 0,
            otherId: (row['other_id'] as num?)?.toInt() ?? 0,
            otherLabel: row['other_label'] as String? ?? '',
            otherKind: row['other_kind'] as String? ?? '',
            kind: row['kind'] as String? ?? '',
            direction: row['direction'] as String? ?? '',
          ),
        )
        .toList();

    final conversations = ((body['conversations'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (row) => GraphProvenance(
            id: (row['id'] as num?)?.toInt() ?? 0,
            ts: DateTime.tryParse(row['ts'] as String? ?? ''),
            userTextSnippet: row['user_text_snippet'] as String? ?? '',
          ),
        )
        .toList();

    return GraphNodeDetail(node: node, facts: facts, relations: relations, conversations: conversations);
  }

  GraphNeighborhood _parseNeighborhood(Map<String, Object?> body) {
    final nodes = ((body['nodes'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (row) => GraphNeighborNode(
            id: (row['id'] as num?)?.toInt() ?? 0,
            label: row['label'] as String? ?? '',
            kind: row['kind'] as String? ?? '',
            domain: row['domain'] as String? ?? '',
            hasEmbedding: row['has_embedding'] as bool? ?? false,
            createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
            occurredAt: DateTime.tryParse(row['occurred_at'] as String? ?? ''),
          ),
        )
        .toList();

    final edges = ((body['edges'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (row) => GraphEdge(
            id: (row['id'] as num?)?.toInt() ?? 0,
            source: (row['source'] as num?)?.toInt() ?? 0,
            target: (row['target'] as num?)?.toInt() ?? 0,
            kind: row['kind'] as String? ?? '',
          ),
        )
        .toList();

    return GraphNeighborhood(nodes: nodes, edges: edges, truncated: body['truncated'] as bool? ?? false);
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudo consultar el cerebro (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
