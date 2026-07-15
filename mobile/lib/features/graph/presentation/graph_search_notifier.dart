import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../data/graph_repository.dart';
import '../domain/graph_node.dart';

/// Real [GraphRepository] used app-wide; overridden with a fake in tests.
/// Wired with the offline read cache + connectivity reporter (M3 slice 1
/// convention), same as [domainRepositoryProvider]/[insightsRepositoryProvider].
final graphRepositoryProvider = Provider<GraphRepository>((ref) => HttpGraphRepository(
      ref.watch(dioProvider),
      cache: ref.watch(responseCacheProvider),
      connectivity: ref.watch(connectivityStatusProvider.notifier),
    ));

/// The graph browser's search UI state. [query] is the last SUBMITTED
/// query (not necessarily the text field's current contents) — `''` means
/// "nothing searched yet", distinct from a submitted-but-empty [results]
/// list (`searched == true`).
class GraphSearchUiState {
  const GraphSearchUiState({this.query = '', this.results = const [], this.loading = false, this.error});

  final String query;
  final List<GraphNode> results;
  final bool loading;
  final String? error;

  /// Whether a (non-blank) search has been submitted at least once —
  /// distinguishes the "type to search" hint from a genuine "no results".
  bool get searched => query.isNotEmpty;

  GraphSearchUiState copyWith({String? query, List<GraphNode>? results, bool? loading, String? error}) =>
      GraphSearchUiState(
        query: query ?? this.query,
        results: results ?? this.results,
        loading: loading ?? this.loading,
        error: error,
      );
}

/// Manages the graph browser's search box lifecycle: search-on-submit
/// (deliberately NOT search-as-you-type — the engine query is a real HTTP
/// round trip, not a local filter), clearing back to the initial state on a
/// blank query.
class GraphSearchNotifier extends Notifier<GraphSearchUiState> {
  @override
  GraphSearchUiState build() => const GraphSearchUiState();

  Future<void> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      state = const GraphSearchUiState();
      return;
    }
    state = state.copyWith(query: trimmed, loading: true, error: null);
    try {
      final results = await ref.read(graphRepositoryProvider).search(trimmed);
      state = state.copyWith(results: results, loading: false, error: null);
    } on GraphException catch (error) {
      state = state.copyWith(loading: false, error: error.message, results: const []);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudo buscar: $error', results: const []);
    }
  }
}

final graphSearchNotifierProvider = NotifierProvider<GraphSearchNotifier, GraphSearchUiState>(GraphSearchNotifier.new);
