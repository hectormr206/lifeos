/// One graph node's full detail. Shape read directly from
/// `axi/src/axi/dashboard.py` (`graph_node_detail`,
/// `GET /api/graph/node/{node_id}`, aliased as `/api/v1/graph/node/{id}`):
/// `{node: {id, kind, label, domain, created_at, occurred_at, data},
///   facts: [{id, label, created_at}],
///   relations: [{edge_id, other_id, other_label, other_kind, kind, direction}],
///   conversations: [{id, ts, user_text_snippet}]}`.
library;

/// The node's own fields (the `node` key of the detail response).
class GraphNodeInfo {
  const GraphNodeInfo({
    required this.id,
    required this.kind,
    required this.label,
    this.domain,
    this.createdAt,
    this.occurredAt,
    this.data = const {},
  });

  final int id;
  final String kind;
  final String label;

  /// Nullable here (unlike [GraphNode.domain]'s `''` coalescing) — this
  /// endpoint returns the raw DB column verbatim.
  final String? domain;
  final DateTime? createdAt;
  final DateTime? occurredAt;
  final Map<String, Object?> data;
}

/// A fact-kind neighbor connected via a `mentions`/`about` edge.
class GraphFact {
  const GraphFact({required this.id, required this.label, this.createdAt});

  final int id;
  final String label;
  final DateTime? createdAt;
}

/// A typed human edge (structural edge kinds are already filtered out
/// server-side). [direction] is `'out'` when this node is the edge's
/// `from_id`, `'in'` when it is `to_id` — kept as the engine's own string so
/// no client-side remapping is needed.
class GraphRelation {
  const GraphRelation({
    required this.edgeId,
    required this.otherId,
    required this.otherLabel,
    required this.otherKind,
    required this.kind,
    required this.direction,
  });

  final int edgeId;

  /// The related node's id — what relation-tap navigation pushes to
  /// (`/graph/$otherId`).
  final int otherId;
  final String otherLabel;
  final String otherKind;
  final String kind;
  final String direction;
}

/// Provenance: a conversation that mentioned this node (engine key
/// `conversations` — kept verbatim; the UI labels this section "Origen").
class GraphProvenance {
  const GraphProvenance({required this.id, this.ts, required this.userTextSnippet});

  final int id;
  final DateTime? ts;
  final String userTextSnippet;
}

class GraphNodeDetail {
  const GraphNodeDetail({
    required this.node,
    this.facts = const [],
    this.relations = const [],
    this.conversations = const [],
  });

  final GraphNodeInfo node;
  final List<GraphFact> facts;
  final List<GraphRelation> relations;
  final List<GraphProvenance> conversations;
}
