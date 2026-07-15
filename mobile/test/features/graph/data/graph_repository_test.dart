// Proves HttpGraphRepository parses the REAL engine shapes read from
// axi/src/axi/dashboard.py:
//   GET /api/v1/graph/search?q=&limit=        (`graph_search`, :2384)
//     -> [{id, label, kind, domain, aliases}]
//   GET /api/v1/graph/node/{id}                (`graph_node_detail`, :2488)
//     -> {node: {id, kind, label, domain, created_at, occurred_at, data},
//         facts: [{id, label, created_at}],
//         relations: [{edge_id, other_id, other_label, other_kind, kind, direction}],
//         conversations: [{id, ts, user_text_snippet}]}
//   GET /api/v1/graph/node/{id}/neighborhood   (`graph_node_neighborhood`, :2724)
//     -> {nodes: [{id, label, kind, domain, created_at, occurred_at, has_embedding}],
//         edges: [{id, source, target, kind}], truncated}
// No live engine — hand-written HttpClientAdapter fake (same pattern as
// insights_repository_test.dart).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/graph/data/graph_repository.dart';

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;
  int callCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    lastRequest = options;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

class _UnreachableAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(requestOptions: options, reason: 'no route to host');
  }
}

Dio _dioWith(int statusCode, String body) {
  final adapter = _FixedResponseAdapter(statusCode, body);
  return Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;
}

Dio _unreachableDio() => Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = _UnreachableAdapter();

class _FakeConnectivityReporter implements ConnectivityReporter {
  final List<String> calls = [];
  DateTime? lastFetchedAt;

  @override
  void reportOnline() => calls.add('online');

  @override
  void reportOfflineWithCache(DateTime fetchedAt) {
    calls.add('offlineWithCache');
    lastFetchedAt = fetchedAt;
  }

  @override
  void reportOffline() => calls.add('offline');
}

void main() {
  group('HttpGraphRepository.search', () {
    test('parses the real /api/v1/graph/search shape', () async {
      final fixture = jsonEncode([
        {
          'id': 42,
          'label': 'García',
          'kind': 'person',
          'domain': 'relationships',
          'aliases': ['mi esposa'],
        },
        {'id': 7, 'label': 'Presión arterial', 'kind': 'fact', 'domain': '', 'aliases': <String>[]},
      ]);
      final dio = _dioWith(200, fixture);
      final repo = HttpGraphRepository(dio);

      final results = await repo.search('garcia');

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/graph/search');
      expect(adapter.lastRequest?.queryParameters['q'], 'garcia');
      expect(results, hasLength(2));
      expect(results[0].id, 42);
      expect(results[0].label, 'García');
      expect(results[0].kind, 'person');
      expect(results[0].domain, 'relationships');
      expect(results[0].aliases, ['mi esposa']);
      expect(results[1].domain, '');
    });

    test('an empty (or blank) query returns [] without hitting the network', () async {
      final dio = _dioWith(200, jsonEncode([]));
      final repo = HttpGraphRepository(dio);

      final results = await repo.search('   ');

      expect(results, isEmpty);
      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.callCount, 0);
    });

    test('a non-2xx response throws GraphException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'internal error'}));
      final repo = HttpGraphRepository(dio);

      await expectLater(() => repo.search('garcia'), throwsA(isA<GraphException>()));
    });
  });

  group('HttpGraphRepository.node', () {
    Map<String, Object?> nodeFixture() => {
          'node': {
            'id': 42,
            'kind': 'person',
            'label': 'García',
            'domain': 'relationships',
            'created_at': '2026-01-01T08:00:00+00:00',
            'occurred_at': null,
            'data': {'role': 'family'},
          },
          'facts': [
            {'id': 100, 'label': 'Le gusta el café', 'created_at': '2026-02-01T08:00:00+00:00'},
          ],
          'relations': [
            {
              'edge_id': 5,
              'other_id': 9,
              'other_label': 'Héctor',
              'other_kind': 'person',
              'kind': 'married_to',
              'direction': 'out',
            },
          ],
          'conversations': [
            {'id': 1, 'ts': '2026-03-01T08:00:00+00:00', 'user_text_snippet': 'hablé con García ayer'},
          ],
        };

    test('parses the real /api/v1/graph/node/{id} shape (node/facts/relations/provenance)', () async {
      final dio = _dioWith(200, jsonEncode(nodeFixture()));
      final repo = HttpGraphRepository(dio);

      final detail = await repo.node(42);

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/graph/node/42');
      expect(detail.node.id, 42);
      expect(detail.node.kind, 'person');
      expect(detail.node.label, 'García');
      expect(detail.node.domain, 'relationships');
      expect(detail.node.data['role'], 'family');
      expect(detail.facts, hasLength(1));
      expect(detail.facts.single.label, 'Le gusta el café');
      expect(detail.relations, hasLength(1));
      expect(detail.relations.single.otherId, 9);
      expect(detail.relations.single.otherLabel, 'Héctor');
      expect(detail.relations.single.kind, 'married_to');
      expect(detail.relations.single.direction, 'out');
      expect(detail.conversations, hasLength(1));
      expect(detail.conversations.single.userTextSnippet, 'hablé con García ayer');
    });

    test('on success, writes through to "graph:node:42" and reports online', () async {
      final dio = _dioWith(200, jsonEncode(nodeFixture()));
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpGraphRepository(dio, cache: cache, connectivity: connectivity);

      await repo.node(42);

      expect(await cache.get('graph:node:42'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached node, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('graph:node:42', nodeFixture());
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpGraphRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final detail = await repo.node(42);

      expect(detail.node.label, 'García');
      expect(connectivity.calls, ['offlineWithCache']);
    });

    test('on network failure with no cached node, throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpGraphRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.node(42), throwsA(isA<GraphException>()));
      expect(connectivity.calls, ['offline']);
    });
  });

  group('HttpGraphRepository.neighborhood', () {
    test('parses the real /api/v1/graph/node/{id}/neighborhood shape', () async {
      final fixture = jsonEncode({
        'nodes': [
          {
            'id': 42,
            'label': 'García',
            'kind': 'person',
            'domain': 'relationships',
            'created_at': '2026-01-01T08:00:00+00:00',
            'occurred_at': null,
            'has_embedding': true,
          },
          {
            'id': 9,
            'label': 'Héctor',
            'kind': 'person',
            'domain': 'relationships',
            'created_at': '2026-01-01T08:00:00+00:00',
            'occurred_at': null,
            'has_embedding': false,
          },
        ],
        'edges': [
          {'id': 5, 'source': 42, 'target': 9, 'kind': 'married_to'},
        ],
        'truncated': false,
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpGraphRepository(dio);

      final neighborhood = await repo.neighborhood(42);

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/graph/node/42/neighborhood');
      expect(neighborhood.nodes, hasLength(2));
      expect(neighborhood.nodes.first.hasEmbedding, isTrue);
      expect(neighborhood.edges, hasLength(1));
      expect(neighborhood.edges.single.source, 42);
      expect(neighborhood.edges.single.target, 9);
      expect(neighborhood.truncated, isFalse);
    });
  });
}
