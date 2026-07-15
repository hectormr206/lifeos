/// One node's 1-hop neighborhood. Shape read directly from
/// `axi/src/axi/dashboard.py` (`graph_node_neighborhood`,
/// `GET /api/graph/node/{node_id}/neighborhood`, aliased as
/// `/api/v1/graph/node/{id}/neighborhood`):
/// `{nodes: [{id, label, kind, domain, created_at, occurred_at,
///   has_embedding}], edges: [{id, source, target, kind}], truncated}`.
///
/// FORK DECISION: NOT rendered by `GraphNodeScreen` this slice —
/// [GraphNodeDetail.relations] already carries `other_id`/`other_label`/
/// `other_kind` for every typed edge, which is everything the mobile
/// browser's relation-tap navigation needs, so wiring this endpoint too
/// would duplicate the same neighbor list in two places. This endpoint's
/// real audience is the laptop's 3D fly-to-node injection (it includes
/// structural edges and `has_embedding`, neither relevant to a list-based
/// browser) — kept here (typed model + repository method) for API
/// parity/completeness and available to a future dedicated neighbors view.
library;

class GraphNeighborNode {
  const GraphNeighborNode({
    required this.id,
    required this.label,
    required this.kind,
    required this.domain,
    required this.hasEmbedding,
    this.createdAt,
    this.occurredAt,
  });

  final int id;
  final String label;
  final String kind;
  final String domain;
  final bool hasEmbedding;
  final DateTime? createdAt;
  final DateTime? occurredAt;
}

class GraphEdge {
  const GraphEdge({required this.id, required this.source, required this.target, required this.kind});

  final int id;
  final int source;
  final int target;
  final String kind;
}

class GraphNeighborhood {
  const GraphNeighborhood({this.nodes = const [], this.edges = const [], this.truncated = false});

  final List<GraphNeighborNode> nodes;
  final List<GraphEdge> edges;
  final bool truncated;
}
