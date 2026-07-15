// Proves GraphSearchNotifier's lifecycle: empty initial state (no query
// yet), search() loads results from the repository, an empty/blank query
// resets to the initial state without calling the repository, and error
// surfacing. No live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/graph/data/graph_repository.dart';
import 'package:lifeos/features/graph/domain/graph_neighborhood.dart';
import 'package:lifeos/features/graph/domain/graph_node.dart';
import 'package:lifeos/features/graph/domain/graph_node_detail.dart';
import 'package:lifeos/features/graph/presentation/graph_search_notifier.dart';

class _FakeGraphRepository implements GraphRepository {
  _FakeGraphRepository({this.results = const [], this.error});

  final List<GraphNode> results;
  final GraphException? error;
  int searchCalls = 0;
  String? lastQuery;

  @override
  Future<List<GraphNode>> search(String query, {int limit = 20}) async {
    searchCalls++;
    lastQuery = query;
    if (error != null) throw error!;
    return results;
  }

  @override
  Future<GraphNodeDetail> node(int id) => throw UnimplementedError();

  @override
  Future<GraphNeighborhood> neighborhood(int id) => throw UnimplementedError();
}

void main() {
  group('GraphSearchNotifier', () {
    test('initial state has no query and no results', () {
      final repo = _FakeGraphRepository();
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final state = container.read(graphSearchNotifierProvider);

      expect(state.query, isEmpty);
      expect(state.results, isEmpty);
      expect(state.searched, isFalse);
      expect(repo.searchCalls, 0);
    });

    test('search("garcia") loads results from the repository', () async {
      final node = const GraphNode(id: 42, label: 'García', kind: 'person', domain: 'relationships');
      final repo = _FakeGraphRepository(results: [node]);
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      await container.read(graphSearchNotifierProvider.notifier).search('garcia');

      final state = container.read(graphSearchNotifierProvider);
      expect(state.query, 'garcia');
      expect(state.searched, isTrue);
      expect(state.results, [node]);
      expect(repo.lastQuery, 'garcia');
    });

    test('searching a blank query resets to the initial state without calling the repository', () async {
      final repo = _FakeGraphRepository();
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      await container.read(graphSearchNotifierProvider.notifier).search('   ');

      final state = container.read(graphSearchNotifierProvider);
      expect(state.searched, isFalse);
      expect(state.results, isEmpty);
      expect(repo.searchCalls, 0);
    });

    test('a search that returns no results yields an empty (but searched) state', () async {
      final repo = _FakeGraphRepository(results: const []);
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      await container.read(graphSearchNotifierProvider.notifier).search('nadie');

      final state = container.read(graphSearchNotifierProvider);
      expect(state.searched, isTrue);
      expect(state.results, isEmpty);
      expect(state.loading, isFalse);
    });

    test('error path surfaces the error message', () async {
      final repo = _FakeGraphRepository(error: GraphException('boom'));
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      await container.read(graphSearchNotifierProvider.notifier).search('garcia');

      final state = container.read(graphSearchNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.error, 'boom');
    });
  });
}
