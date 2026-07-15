import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/graph_repository.dart';
import '../domain/graph_node_detail.dart';
import 'graph_search_notifier.dart' show graphRepositoryProvider;

/// One node's detail screen state.
class GraphNodeUiState {
  const GraphNodeUiState({this.detail, this.loading = true, this.error});

  final GraphNodeDetail? detail;
  final bool loading;
  final String? error;

  GraphNodeUiState copyWith({GraphNodeDetail? detail, bool? loading, String? error}) => GraphNodeUiState(
        detail: detail ?? this.detail,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages one node's detail lifecycle. ONE notifier class, instantiated
/// per node id via [graphNodeNotifierProvider]'s family (same pattern as
/// `DomainNotifier`'s per-[DomainDescriptor] family) — relation-tap
/// navigation to a different node id gets its own independent instance.
class GraphNodeNotifier extends Notifier<GraphNodeUiState> {
  GraphNodeNotifier(this.nodeId);

  final int nodeId;

  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  GraphNodeUiState build() {
    _bootstrapFuture = _load();
    return const GraphNodeUiState();
  }

  Future<void> _load() async {
    try {
      final detail = await ref.read(graphRepositoryProvider).node(nodeId);
      state = state.copyWith(detail: detail, loading: false, error: null);
    } on GraphException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudo cargar el nodo: $error');
    }
  }

  Future<void> refresh() => _load();
}

final graphNodeNotifierProvider = NotifierProvider.family<GraphNodeNotifier, GraphNodeUiState, int>(
  GraphNodeNotifier.new,
);
