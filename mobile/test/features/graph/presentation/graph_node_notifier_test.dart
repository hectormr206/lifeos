// Proves GraphNodeNotifier's lifecycle: loads the node detail on init
// (family keyed by node id, mirrors DomainNotifier), error surfacing, and
// refresh. No live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/graph/data/graph_repository.dart';
import 'package:lifeos/features/graph/domain/graph_neighborhood.dart';
import 'package:lifeos/features/graph/domain/graph_node.dart';
import 'package:lifeos/features/graph/domain/graph_node_detail.dart';
import 'package:lifeos/features/graph/presentation/graph_node_notifier.dart';
import 'package:lifeos/features/graph/presentation/graph_search_notifier.dart' show graphRepositoryProvider;

GraphNodeDetail _detail(int id, {String label = 'García'}) => GraphNodeDetail(
      node: GraphNodeInfo(id: id, kind: 'person', label: label, domain: 'relationships'),
      facts: const [],
      relations: const [],
      conversations: const [],
    );

class _FakeGraphRepository implements GraphRepository {
  _FakeGraphRepository({this.detail, this.error});

  GraphNodeDetail? detail;
  final GraphException? error;
  int nodeCalls = 0;
  int? lastId;

  @override
  Future<List<GraphNode>> search(String query, {int limit = 20}) => throw UnimplementedError();

  @override
  Future<GraphNodeDetail> node(int id) async {
    nodeCalls++;
    lastId = id;
    if (error != null) throw error!;
    return detail ?? _detail(id);
  }

  @override
  Future<GraphNeighborhood> neighborhood(int id) => throw UnimplementedError();
}

void main() {
  group('GraphNodeNotifier', () {
    test('loads the node detail on init', () async {
      final repo = _FakeGraphRepository(detail: _detail(42));
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(graphNodeNotifierProvider(42).notifier);
      await notifier.ready;

      final state = container.read(graphNodeNotifierProvider(42));
      expect(state.loading, isFalse);
      expect(state.detail?.node.label, 'García');
      expect(repo.lastId, 42);
    });

    test('error path surfaces the error message', () async {
      final repo = _FakeGraphRepository(error: GraphException('boom'));
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(graphNodeNotifierProvider(42).notifier);
      await notifier.ready;

      final state = container.read(graphNodeNotifierProvider(42));
      expect(state.loading, isFalse);
      expect(state.detail, isNull);
      expect(state.error, 'boom');
    });

    test('refresh reloads the node', () async {
      final repo = _FakeGraphRepository(detail: _detail(42));
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(graphNodeNotifierProvider(42).notifier);
      await notifier.ready;
      expect(repo.nodeCalls, 1);

      await notifier.refresh();

      expect(repo.nodeCalls, 2);
    });

    test('different node ids each load independently', () async {
      final repo = _FakeGraphRepository();
      final container = ProviderContainer(overrides: [graphRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      await container.read(graphNodeNotifierProvider(42).notifier).ready;
      await container.read(graphNodeNotifierProvider(9).notifier).ready;

      expect(container.read(graphNodeNotifierProvider(42)).detail?.node.id, 42);
      expect(container.read(graphNodeNotifierProvider(9)).detail?.node.id, 9);
    });
  });
}
