import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../../graph/presentation/local_graph_notifier.dart' show kLocalGraphKinds;
import '../../memory/data/memory_writer.dart' show isLowValue;
import '../../memory/domain/subject.dart' show foldAccents;

/// Maximum nodes rendered on the phone. The laptop's /brain3d loads ~500 as
/// well; beyond that a phone GPU (and the force layout) starts to crawl.
const int kBrain3dMaxNodes = 500;

/// Chat plumbing kinds EXCLUDED from the Cerebro 3D. The 3D view is the "brain
/// of your life" — what Axi KNOWS (facts, people, events, domain readings), not
/// the raw chat log: `conversation` containers ("Chat con Axi") and per-turn
/// `chat_message`/greeting nodes ("Hola") only clutter it.
const Set<String> kBrain3dExcludedKinds = <String>{'conversation', 'chat_message'};

/// Trivial greeting / filler phrases (accent-folded, lowercased, ≤ ~2 words)
/// that carry no informational content. A `fact` node whose whole label is one
/// of these is dropped from the view. Complements [isLowValue], which only
/// catches SINGLE-token noise — this also covers 2-word greetings.
const Set<String> _kGreetingStopList = <String>{
  'hola', 'holi', 'hey', 'ola', 'buenas', 'buenos dias', 'buen dia',
  'buenas tardes', 'buenas noches', 'gracias', 'muchas gracias', 'mil gracias',
  'de nada', 'ok', 'okay', 'vale', 'listo', 'perfecto', 'genial', 'adios',
  'chao', 'nos vemos', 'hasta luego', 'si', 'no', 'claro',
};

/// True when [label] is nothing but a greeting/filler phrase (≤ 2 words).
bool _isGreetingFiller(String label) {
  final normalized = foldAccents(label.trim().toLowerCase())
      .replaceAll(RegExp(r'[^\w\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return false;
  if (normalized.split(' ').length > 2) return false;
  return _kGreetingStopList.contains(normalized);
}

/// True when a node is meaningful knowledge worth rendering in the 3D view.
/// The user hub (`person` with `data.role == 'user'`, "Yo") and all
/// non-`fact` knowledge (people, events, domain data) are always kept; only
/// `fact` nodes are screened for low-value greeting/filler noise.
bool _isKnowledgeNode(GraphNodeRecord n) {
  if (kBrain3dExcludedKinds.contains(n.kind)) return false;
  if (n.kind != 'fact') return true;
  if (isLowValue(n.label, n.data)) return false;
  if (_isGreetingFiller(n.label)) return false;
  return true;
}

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
    // Skip chat plumbing (conversation/chat_message) — the 3D view shows
    // KNOWLEDGE, not the chat log.
    if (kBrain3dExcludedKinds.contains(entry.kind)) continue;
    // +1 so "did we truncate?" is detectable even when one single kind
    // holds more than maxNodes rows.
    merged.addAll(await store.listNodesByKind(entry.kind, limit: maxNodes + 1));
  }
  // Drop trivial greeting/filler facts; keep the hub and all real knowledge.
  merged.retainWhere(_isKnowledgeNode);
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
