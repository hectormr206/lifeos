import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
import '../../../core/graph/graph_records.dart';

/// Presentation layer for the ON-DEVICE graph browser (roadmap SLICE C5).
///
/// Unlike [GraphSearchNotifier] / [GraphNodeNotifier] (which talk to the paired
/// laptop engine over HTTP), everything here reads the local encrypted graph
/// store via [localGraphStoreProvider] — so the user can browse the memory
/// graph that C1 writes on-device, fully offline and WITHOUT pairing.
///
/// It only ever CONSUMES the read side of `LocalGraphStore`
/// (`listNodesByKind` / `searchNodes` / `getNodeByUuid` / `edgesForNode`).

/// The node kinds C1 currently writes on-device, in the order they are offered
/// as filter chips. `null` (Todos) merges across all of them.
// TODO(i18n): these Spanish labels are hardcoded pending the i18n sweep.
const List<({String kind, String label})> kLocalGraphKinds = [
  (kind: 'fact', label: 'Hechos'),
  (kind: 'conversation', label: 'Conversaciones'),
  (kind: 'person', label: 'Personas'),
  (kind: 'event', label: 'Eventos'),
];

/// Immutable UI state for the local browser list: the active [kind] filter
/// (`null` = all), the last submitted [query] (`''` = browse, not search), and
/// the resolved [nodes].
class LocalGraphListState {
  const LocalGraphListState({this.kind, this.query = '', this.nodes = const []});

  /// Active kind filter; `null` means "all kinds" (Todos).
  final String? kind;

  /// Last submitted search text; blank means browse-by-kind, not a search.
  final String query;

  /// Nodes currently shown.
  final List<GraphNodeRecord> nodes;

  bool get isSearching => query.trim().isNotEmpty;

  LocalGraphListState copyWith({
    Object? kind = _sentinel,
    String? query,
    List<GraphNodeRecord>? nodes,
  }) =>
      LocalGraphListState(
        kind: kind == _sentinel ? this.kind : kind as String?,
        query: query ?? this.query,
        nodes: nodes ?? this.nodes,
      );

  static const _sentinel = Object();
}

/// Loads and filters the on-device node list. Browsing by kind uses
/// [LocalGraphStore.listNodesByKind]; submitting a query switches to
/// [LocalGraphStore.searchNodes] (a real substring scan over label + data).
class LocalGraphListNotifier extends AsyncNotifier<LocalGraphListState> {
  @override
  Future<LocalGraphListState> build() =>
      _fetch(const LocalGraphListState());

  /// Fetch the nodes matching [base]'s kind + query and return the completed
  /// state. Merges across all known kinds when no kind filter is set.
  Future<LocalGraphListState> _fetch(LocalGraphListState base) async {
    final store = await ref.read(localGraphStoreProvider.future);
    final query = base.query.trim();

    if (query.isNotEmpty) {
      final results = await store.searchNodes(query, limit: 100);
      final nodes = base.kind == null
          ? results
          : results.where((n) => n.kind == base.kind).toList();
      return base.copyWith(nodes: nodes);
    }

    if (base.kind != null) {
      final nodes = await store.listNodesByKind(base.kind!, limit: 200);
      return base.copyWith(nodes: nodes);
    }

    // Todos: merge every known kind, newest-created first.
    final merged = <GraphNodeRecord>[];
    for (final entry in kLocalGraphKinds) {
      merged.addAll(await store.listNodesByKind(entry.kind, limit: 200));
    }
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return base.copyWith(nodes: merged);
  }

  /// Switch the active kind filter (keeps the current query).
  Future<void> setKind(String? kind) async {
    final current = state.value ?? const LocalGraphListState();
    final next = current.copyWith(kind: kind);
    state = const AsyncLoading<LocalGraphListState>();
    state = await AsyncValue.guard(() => _fetch(next));
  }

  /// Submit a search (blank clears back to browse-by-kind).
  Future<void> search(String query) async {
    final current = state.value ?? const LocalGraphListState();
    final next = current.copyWith(query: query);
    state = const AsyncLoading<LocalGraphListState>();
    state = await AsyncValue.guard(() => _fetch(next));
  }
}

final localGraphListProvider =
    AsyncNotifierProvider<LocalGraphListNotifier, LocalGraphListState>(
  LocalGraphListNotifier.new,
);

/// One in/out relation of a node, resolved to its far endpoint so the detail
/// screen can show a human label and navigate one hop.
class LocalGraphRelation {
  const LocalGraphRelation({
    required this.relation,
    required this.outgoing,
    required this.otherUuid,
    required this.otherLabel,
    required this.otherKind,
  });

  final String relation;

  /// True when the current node is the edge's source (node → other).
  final bool outgoing;
  final String otherUuid;
  final String otherLabel;
  final String otherKind;
}

/// A node plus its resolved relations, for the detail screen.
class LocalGraphNodeDetail {
  const LocalGraphNodeDetail({required this.node, required this.relations});

  final GraphNodeRecord node;
  final List<LocalGraphRelation> relations;
}

/// Loads one node (by uuid) and its relations for the detail screen. A family
/// keyed by uuid so relation-tap navigation to another node gets its own
/// independent instance (same shape as [GraphNodeNotifier]).
class LocalGraphNodeNotifier extends AsyncNotifier<LocalGraphNodeDetail?> {
  LocalGraphNodeNotifier(this.nodeUuid);

  final String nodeUuid;

  @override
  Future<LocalGraphNodeDetail?> build() async {
    final store = await ref.read(localGraphStoreProvider.future);
    final node = await store.getNodeByUuid(nodeUuid);
    if (node == null) return null;

    final edges =
        await store.edgesForNode(nodeUuid, direction: EdgeDirection.both);
    final relations = <LocalGraphRelation>[];
    final seenEdges = <String>{};
    for (final edge in edges) {
      if (!seenEdges.add(edge.uuid)) continue;
      final outgoing = edge.srcUuid == nodeUuid;
      final otherUuid = outgoing ? edge.dstUuid : edge.srcUuid;
      if (otherUuid == nodeUuid) continue; // ignore self-loops
      final other = await store.getNodeByUuid(otherUuid);
      if (other == null) continue; // far endpoint missing/tombstoned
      relations.add(LocalGraphRelation(
        relation: edge.relation,
        outgoing: outgoing,
        otherUuid: otherUuid,
        otherLabel: other.label,
        otherKind: other.kind,
      ));
    }
    return LocalGraphNodeDetail(node: node, relations: relations);
  }
}

final localGraphNodeProvider = AsyncNotifierProvider.family<
    LocalGraphNodeNotifier, LocalGraphNodeDetail?, String>(
  LocalGraphNodeNotifier.new,
);
