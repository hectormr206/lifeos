// Proves HttpBriefingsRepository parses the REAL engine shape read from
// axi/src/axi/dashboard.py: `GET /api/v1/briefings` (:5825
// `api_briefings_list`) -> {"briefings": [{id, message, action_prompt,
// recurrence, status, when_ts, last_result_at, result}...]} (`_briefing_to_dict`,
// :5784). No live engine: a hand-written HttpClientAdapter fake, same
// pattern as organs_repository_test.dart.
//
// Also covers the offline read cache (M3 slice 1 pattern): write-through to
// the cache on success, read-through fallback on network failure, and
// connectivity reporting.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/briefings/data/briefings_repository.dart';

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
  group('HttpBriefingsRepository.list', () {
    test('parses the real /api/v1/briefings shape, including a fired result', () async {
      final fixture = jsonEncode({
        'briefings': [
          {
            'id': '7',
            'message': 'Resumen semanal de finanzas',
            'action_prompt': 'Resume mis gastos de la semana',
            'recurrence': '0 8 * * 1',
            'status': 'pending',
            'when_ts': '2026-07-20T08:00:00+00:00',
            'last_result_at': '2026-07-13T08:00:00+00:00',
            'result': {
              'title': 'Finanzas de la semana',
              'summary': 'Gastaste 1200 MXN, 10% menos que la semana pasada.',
              'items': ['Comida: 500', 'Transporte: 300'],
              'ok': true,
              'markdown': '**Finanzas de la semana**\n\nGastaste 1200 MXN...',
            },
          },
          {
            'id': '9',
            'message': 'Chequeo diario de salud',
            'action_prompt': null,
            'recurrence': '0 7 * * *',
            'status': 'pending',
            'when_ts': '2026-07-15T07:00:00+00:00',
            'last_result_at': null,
            'result': null,
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpBriefingsRepository(dio);

      final briefings = await repo.list();

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/briefings');
      expect(briefings, hasLength(2));
      expect(briefings[0].id, '7');
      expect(briefings[0].message, 'Resumen semanal de finanzas');
      expect(briefings[0].result, isNotNull);
      expect(briefings[0].result!.title, 'Finanzas de la semana');
      expect(briefings[0].result!.items, ['Comida: 500', 'Transporte: 300']);
      expect(briefings[0].result!.markdown, contains('Finanzas de la semana'));
      expect(briefings[1].id, '9');
      expect(briefings[1].result, isNull);
    });

    test('a non-2xx response throws BriefingsException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'internal error'}));
      final repo = HttpBriefingsRepository(dio);

      await expectLater(() => repo.list(), throwsA(isA<BriefingsException>()));
    });

    test('an unexpected/malformed response body degrades to an empty list', () async {
      final dio = _dioWith(200, jsonEncode({'unexpected': 'shape'}));
      final repo = HttpBriefingsRepository(dio);

      final briefings = await repo.list();

      expect(briefings, isEmpty);
    });
  });

  group('HttpBriefingsRepository offline read cache', () {
    test('on success, writes the response through to "briefings:list" and reports online', () async {
      final fixture = jsonEncode({
        'briefings': [
          {
            'id': '1',
            'message': 'Boletín',
            'action_prompt': null,
            'recurrence': null,
            'status': 'pending',
            'when_ts': '2026-07-14T08:00:00+00:00',
            'last_result_at': null,
            'result': null,
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpBriefingsRepository(dio, cache: cache, connectivity: connectivity);

      await repo.list();

      expect(await cache.get('briefings:list'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached value, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('briefings:list', [
        {
          'id': '1',
          'message': 'Boletín en caché',
          'action_prompt': null,
          'recurrence': null,
          'status': 'pending',
          'when_ts': '2026-07-14T08:00:00+00:00',
          'last_result_at': null,
          'result': null,
        },
      ]);
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpBriefingsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final briefings = await repo.list();

      expect(briefings, hasLength(1));
      expect(briefings[0].message, 'Boletín en caché');
      expect(connectivity.calls, ['offlineWithCache']);
      expect(connectivity.lastFetchedAt, isNotNull);
    });

    test('on network failure with no cached value, still throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpBriefingsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.list(), throwsA(isA<BriefingsException>()));
      expect(connectivity.calls, ['offline']);
    });
  });
}
