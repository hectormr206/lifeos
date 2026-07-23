/// Application service composing the on-device [TextEmbedder] with the graph
/// [LocalGraphStore] vector side (roadmap SLICE B1: local embeddings + RAG).
///
/// It owns the ONE place that embeds text, keeping the store math-only and the
/// embedder storage-agnostic:
///   * [indexNode]  — embeds a node's text (document task) and upserts its vector.
///   * [recallByText] — embeds a query (query task) and cosine-recalls top-k nodes.
///
/// The embedder's [TextEmbedder.model] is threaded onto every vector row and
/// used as the recall filter, so recall NEVER compares vectors across models
/// (graph caveat R8). This service does NOT inject anything into the chat prompt
/// — wiring recalled memories into a turn is a later slice (C1).
library;

import 'dart:typed_data';

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import 'text_embedder.dart';

class RagService {
  RagService({required this.embedder, required this.store});

  final TextEmbedder embedder;
  final LocalGraphStore store;

  /// Embed [node]'s text (label + data) as a DOCUMENT and store its vector so it
  /// becomes recallable. Re-indexing the same node overwrites its vector. Skips
  /// tombstoned nodes (a deleted node has nothing to recall; callers should
  /// [LocalGraphStore.deleteNodeVector] on delete instead).
  Future<void> indexNode(GraphNodeRecord node) async {
    if (node.isDeleted) return;
    final vec = await embedder.embed(_nodeText(node), isQuery: false);
    await store.upsertNodeVector(
      node.uuid,
      embedder.model,
      embedder.dimension,
      vec,
    );
  }

  /// Embed [queryText] as a QUERY and return the top-[k] most similar live nodes
  /// (cosine), restricted to this embedder's model. Blank query → `[]`.
  Future<List<GraphNodeRecord>> recallByText(String queryText, {int k = 5}) async {
    if (queryText.trim().isEmpty) return const [];
    final Float32List vec = await embedder.embed(queryText, isQuery: true);
    return store.recall(vec, k: k, model: embedder.model);
  }

  /// Index every live `fact` node that has no vector under this embedder's
  /// model yet (roadmap SLICE B1b backfill: facts recorded while semantic
  /// recall was dormant become recallable once the model lands). Runs in
  /// [batchSize] batches up to [maxNodes] per call so it stays off the critical
  /// path; the caller re-invokes on a later warmup for anything left. Returns
  /// the number of nodes indexed. Throws on an embed failure — callers treat
  /// the whole pass as best-effort.
  Future<int> backfillMissingVectors({int batchSize = 16, int maxNodes = 256}) async {
    var indexed = 0;
    while (indexed < maxNodes) {
      final missing = await store.listFactNodesMissingVector(
        embedder.model,
        limit: batchSize,
      );
      if (missing.isEmpty) break;
      for (final node in missing) {
        await indexNode(node);
        indexed++;
        if (indexed >= maxNodes) break;
      }
      if (missing.length < batchSize) break;
    }
    return indexed;
  }

  /// Flat, human-readable text for a node: its label plus the scalar values of
  /// its `data` map. Mirrors what the model would "read" about the node; keeps
  /// embeddings stable and independent of JSON key ordering.
  static String _nodeText(GraphNodeRecord node) {
    final parts = <String>[node.label];
    for (final value in node.data.values) {
      if (value == null) continue;
      final s = value.toString().trim();
      if (s.isNotEmpty) parts.add(s);
    }
    return parts.join('\n');
  }
}
