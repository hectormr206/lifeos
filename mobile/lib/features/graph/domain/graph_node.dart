/// A knowledge-graph search result. Shape read directly from
/// `axi/src/axi/dashboard.py` (`graph_search`, `GET /api/graph/search`,
/// aliased as `/api/v1/graph/search`): `[{id, label, kind, domain,
/// aliases}]`, already ordered by relevance server-side (label/alias
/// exact/prefix/substring, entity kinds first).
class GraphNode {
  const GraphNode({
    required this.id,
    required this.label,
    required this.kind,
    required this.domain,
    this.aliases = const [],
  });

  final int id;
  final String label;

  /// The node's kind (e.g. `'person'`, `'place'`, `'fact'`). Named `kind` —
  /// not `type` — to match the engine's own field verbatim.
  final String kind;

  /// `''` when the node has no domain (matches the engine, which coalesces
  /// `null` to `''` in this endpoint specifically).
  final String domain;
  final List<String> aliases;

  @override
  bool operator ==(Object other) =>
      other is GraphNode && other.id == id && other.label == label && other.kind == kind && other.domain == domain;

  @override
  int get hashCode => Object.hash(id, label, kind, domain);

  @override
  String toString() => 'GraphNode(id: $id, label: $label, kind: $kind)';
}
