// Proves HttpOrgansRepository parses the REAL engine shape read from
// axi/src/axi/organs.py: `GET /api/v1/organs` (dashboard.py:1204
// `api_organs`) -> {"organs": [{key, name, state, detail, description}...]}
// (organs.all_organs(), :297). No live engine: a hand-written
// HttpClientAdapter fake, same pattern as domain_repository_test.dart.
//
// Also covers the offline read cache (M3 slice 1): write-through to the
// cache on success, read-through fallback on network failure, and
// connectivity reporting.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/body/data/organs_repository.dart';

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

/// Simulates the engine being unreachable (connection refused/timeout):
/// dio wraps this in a [DioException] with no [DioException.response] set.
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
  group('HttpOrgansRepository.list', () {
    test('parses the real /api/v1/organs shape across the state palette', () async {
      final fixture = jsonEncode({
        'organs': [
          {
            'key': 'heart',
            'name': 'corazón',
            'state': 'ok',
            'detail': 'latido de auto-sanación activo',
            'description': 'El latido de auto-sanación: vigila los servicios vitales de Axi.',
          },
          {
            'key': 'lungs',
            'name': 'pulmones',
            'state': 'degraded',
            'detail': 'VRAM al 92%',
            'description': 'Siente las constantes vitales del cuerpo de Axi.',
          },
          {
            'key': 'hands',
            'name': 'manos',
            'state': 'down',
            'detail': 'ydotoold inactivo',
            'description': 'Actúan sobre el escritorio.',
          },
          {
            'key': 'mouth',
            'name': 'boca',
            'state': 'off',
            'detail': 'voz desactivada',
            'description': 'La voz de Axi.',
          },
          {
            'key': 'immune',
            'name': 'sistema inmune',
            'state': 'planned',
            'detail': 'en desarrollo',
            'description': 'Aprenderá de los patrones del olfato para prevenir fallas.',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpOrgansRepository(dio);

      final organs = await repo.list();

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/organs');
      expect(organs, hasLength(5));
      expect(organs[0].key, 'heart');
      expect(organs[0].name, 'corazón');
      expect(organs[0].state, 'ok');
      expect(organs[0].detail, 'latido de auto-sanación activo');
      expect(organs[1].state, 'degraded');
      expect(organs[2].state, 'down');
      expect(organs[3].state, 'off');
      expect(organs[4].state, 'planned');
      expect(organs[4].description, contains('Aprenderá'));
    });

    test('a non-2xx response throws OrgansException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'internal error'}));
      final repo = HttpOrgansRepository(dio);

      await expectLater(() => repo.list(), throwsA(isA<OrgansException>()));
    });

    test('an unexpected/malformed response body degrades to an empty list', () async {
      final dio = _dioWith(200, jsonEncode({'unexpected': 'shape'}));
      final repo = HttpOrgansRepository(dio);

      final organs = await repo.list();

      expect(organs, isEmpty);
    });
  });

  group('HttpOrgansRepository offline read cache (M3 slice 1)', () {
    test('on success, writes the response through to the cache and reports online', () async {
      final fixture = jsonEncode({
        'organs': [
          {'key': 'heart', 'name': 'corazón', 'state': 'ok', 'detail': 'd', 'description': 'desc'},
        ],
      });
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpOrgansRepository(dio, cache: cache, connectivity: connectivity);

      await repo.list();

      expect(await cache.get('body:organs'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached value, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('body:organs', [
        {'key': 'heart', 'name': 'corazón', 'state': 'ok', 'detail': 'cached', 'description': 'desc'},
      ]);
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpOrgansRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final organs = await repo.list();

      expect(organs, hasLength(1));
      expect(organs[0].detail, 'cached');
      expect(connectivity.calls, ['offlineWithCache']);
      expect(connectivity.lastFetchedAt, isNotNull);
    });

    test('on network failure with no cached value, still throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpOrgansRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.list(), throwsA(isA<OrgansException>()));
      expect(connectivity.calls, ['offline']);
    });
  });
}
