import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../../graph/presentation/local_graph_notifier.dart' show kLocalGraphKinds;

/// Maximum nodes rendered on the phone. The laptop's /brain3d loads ~500 as
/// well; beyond that a phone GPU (and the force layout) starts to crawl.
const int kBrain3dMaxNodes = 500;

/// The Cerebro 3D scene data: the most recent local nodes plus every edge
/// whose BOTH endpoints made the cut. Serializes to the exact JSON shape
/// assets/brain3d/brain3d.html's `axiLoadGraph` expects (mirroring the
/// laptop's /api/graph/full contract: nodes[] + edges[] with epoch dates).
class Brain3dPayload {
  const Brain3dPayload({
    required this.nodes,
    required this.edges,
    required this.truncated,
  });

  final List<GraphNodeRecord> nodes;
  final List<GraphEdgeRecord> edges;

  /// True when the store held more nodes than [kBrain3dMaxNodes].
  final bool truncated;

  Map<String, Object?> toJson() => <String, Object?>{
        'nodes': [
          for (final n in nodes)
            <String, Object?>{
              'id': n.uuid,
              'label': n.label,
              'kind': n.kind,
              'domain': n.domain,
              'created_at': n.createdAt.millisecondsSinceEpoch ~/ 1000,
              'occurred_at': n.occurredAt == null
                  ? null
                  : n.occurredAt!.millisecondsSinceEpoch ~/ 1000,
            },
        ],
        'edges': [
          for (final e in edges)
            <String, Object?>{
              'source': e.srcUuid,
              'target': e.dstUuid,
              'kind': e.relation,
            },
        ],
        'truncated': truncated,
      };
}

/// Builds the Cerebro 3D payload from the ON-DEVICE graph, read-only and
/// fully offline. Consumes only the store's read API (`listNodesByKind` +
/// `edgesForNode`), like the local graph browser does:
///
///  1. Merge every kind C1 writes on-device, newest-created first.
///  2. Cap at [maxNodes] (phone performance — see [kBrain3dMaxNodes]).
///  3. Keep only edges connecting two surviving nodes, deduped by uuid.
Future<Brain3dPayload> buildBrain3dPayload(
  LocalGraphStore store, {
  int maxNodes = kBrain3dMaxNodes,
}) async {
  final merged = <GraphNodeRecord>[];
  for (final entry in kLocalGraphKinds) {
    // +1 so "did we truncate?" is detectable even when one single kind
    // holds more than maxNodes rows.
    merged.addAll(await store.listNodesByKind(entry.kind, limit: maxNodes + 1));
  }
  merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  final truncated = merged.length > maxNodes;
  final nodes = truncated ? merged.sublist(0, maxNodes) : merged;
  final ids = <String>{for (final n in nodes) n.uuid};

  final edges = <GraphEdgeRecord>[];
  final seenEdges = <String>{};
  for (final node in nodes) {
    for (final edge in await store.edgesForNode(node.uuid)) {
      if (!seenEdges.add(edge.uuid)) continue;
      if (ids.contains(edge.srcUuid) && ids.contains(edge.dstUuid)) {
        edges.add(edge);
      }
    }
  }
  return Brain3dPayload(nodes: nodes, edges: edges, truncated: truncated);
}
