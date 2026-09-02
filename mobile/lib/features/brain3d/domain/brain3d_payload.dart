import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../../memory/data/memory_writer.dart' show isLowValue;
import '../../memory/domain/subject.dart' show foldAccents;

/// Maximum nodes rendered on the phone. The laptop's /brain3d loads ~500 as
/// well; beyond that a phone GPU (and the force layout) starts to crawl.
const int kBrain3dMaxNodes = 500;

/// The node kinds the Cerebro 3D LOADS, newest-first, in no particular order.
///
/// Deliberately the 3D's own list, not the memory browser's `kLocalGraphKinds`:
/// that constant is a filter-chip taxonomy for a list screen, and borrowing it
/// here is exactly what hid `entity` nodes — the places, medications, orgs and
/// things `MemoryWriter.ensureEntity` writes, and the far endpoint of most
/// extracted relations. Because an edge survives only when BOTH endpoints do,
/// not loading them silently deleted whole relationships from the drawing
/// ("Tere --vive_en--> Monterrey" existed in the store and never appeared).
///
/// Adding a kind here changes ONE screen. That is the point.
const List<String> kBrain3dKinds = <String>[
  'fact',
  'person',
  'event',
  'entity',
];

/// Chat plumbing kinds EXCLUDED from the Cerebro 3D. The 3D view is the "brain
/// of your life" — what Axi KNOWS (facts, people, events, domain readings), not
/// the raw chat log: `conversation` containers ("Chat con Axi") and per-turn
/// `chat_message`/greeting nodes ("Hola") only clutter it.
/// Not in [kBrain3dKinds], so nothing loads them in the first place; kept as a
/// guard on the records themselves, in case they arrive by another door.
const Set<String> kBrain3dExcludedKinds = <String>{'conversation', 'chat_message'};

/// Trivial greeting / filler phrases (accent-folded, lowercased, ≤ ~2 words)
/// that carry no informational content. A `fact` or `entity` node whose whole
/// label is one of these is dropped. Complements [isLowValue], which only
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
///
/// The user hub (`person` with `data.role == 'user'`, "Yo"), people and events
/// are always kept. Two kinds are screened for noise, with DIFFERENT rules:
///
///  * `fact` — full screening. A fact carries its content in `data`, so a bare
///    short label with nothing behind it is filler ([isLowValue]).
///  * `entity` — greetings and blanks only. An entity's whole content IS its
///    label: "Monterrey" is a single short token with an empty `data`, which
///    [isLowValue] would call worthless. Running it here would delete almost
///    every entity and re-open the bug this list exists to close. What is left
///    to catch is a bad extraction that made a node out of "hola".
bool _isKnowledgeNode(GraphNodeRecord n) {
  if (kBrain3dExcludedKinds.contains(n.kind)) return false;
  if (n.kind == 'fact') {
    if (isLowValue(n.label, n.data)) return false;
    return !_isGreetingFiller(n.label);
  }
  if (n.kind == 'entity') {
    if (n.label.trim().isEmpty) return false;
    return !_isGreetingFiller(n.label);
  }
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
///  1. Merge every kind in [kBrain3dKinds], newest-created first.
///  2. Cap at [maxNodes] (phone performance — see [kBrain3dMaxNodes]).
///  3. Keep only edges connecting two surviving nodes, deduped by uuid.
Future<Brain3dPayload> buildBrain3dPayload(
  LocalGraphStore store, {
  int maxNodes = kBrain3dMaxNodes,
}) async {
  final merged = <GraphNodeRecord>[];
  for (final kind in kBrain3dKinds) {
    // +1 so "did we truncate?" is detectable even when one single kind
    // holds more than maxNodes rows.
    merged.addAll(await store.listNodesByKind(kind, limit: maxNodes + 1));
  }
  // Drop trivial greeting/filler noise; keep the hub and all real knowledge.
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
