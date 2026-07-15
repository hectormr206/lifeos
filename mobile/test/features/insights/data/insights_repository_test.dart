// Proves HttpInsightsRepository parses the REAL engine shape read from
// axi/src/axi/dashboard.py: `GET /api/v1/insights/preview?cadence=`
// (:6906 `api_insights_preview`) -> {cadence, body, sections_count,
// patterns_count, correlations_count, generated_at} — composes the digest
// WITHOUT dispatching push (unlike run-daily/run-weekly, which are
// mutating actions, not a read). No live engine — hand-written
// HttpClientAdapter fake.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/insights/data/insights_repository.dart';

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

/// Simulates the engine being unreachable (M3 slice 1's offline read cache
/// fallback path) — dio wraps this in a [DioException] with no `.response`.
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
  group('HttpInsightsRepository.preview', () {
    test('parses the real /api/v1/insights/preview shape (cadence=daily default)', () async {
      final fixture = jsonEncode({
        'cadence': 'daily',
        'body': 'Hoy dormiste 7h y gastaste 350 MXN. Vas bien con tu racha de ejercicio.',
        'sections_count': 3,
        'patterns_count': 1,
        'correlations_count': 0,
        'generated_at': '2026-07-14T08:00:00+00:00',
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpInsightsRepository(dio);

      final digest = await repo.preview();

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/insights/preview');
      expect(adapter.lastRequest?.queryParameters['cadence'], 'daily');
      expect(digest.cadence, 'daily');
      expect(digest.body, contains('dormiste 7h'));
      expect(digest.sectionsCount, 3);
      expect(digest.patternsCount, 1);
      expect(digest.correlationsCount, 0);
    });

    test('preview(cadence: "weekly") passes the cadence query param through', () async {
      final fixture = jsonEncode({
        'cadence': 'weekly',
        'body': 'Semana estable.',
        'sections_count': 5,
        'patterns_count': 2,
        'correlations_count': 1,
        'generated_at': '2026-07-13T20:00:00+00:00',
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpInsightsRepository(dio);

      final digest = await repo.preview(cadence: 'weekly');

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.queryParameters['cadence'], 'weekly');
      expect(digest.cadence, 'weekly');
    });

    test('a non-2xx response throws InsightsException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'internal error'}));
      final repo = HttpInsightsRepository(dio);

      await expectLater(() => repo.preview(), throwsA(isA<InsightsException>()));
    });

    test('an unexpected/malformed response body degrades to an empty digest', () async {
      final dio = _dioWith(200, jsonEncode({'unexpected': 'shape'}));
      final repo = HttpInsightsRepository(dio);

      final digest = await repo.preview();

      expect(digest.body, isEmpty);
      expect(digest.sectionsCount, 0);
    });
  });

  group('HttpInsightsRepository offline read cache (M3 slice 1)', () {
    test('on success, writes through to "insights:daily" and reports online', () async {
      final fixture = jsonEncode({
        'cadence': 'daily',
        'body': 'Resumen del día.',
        'sections_count': 2,
        'patterns_count': 0,
        'correlations_count': 0,
        'generated_at': '2026-07-14T08:00:00+00:00',
      });
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpInsightsRepository(dio, cache: cache, connectivity: connectivity);

      await repo.preview();

      expect(await cache.get('insights:daily'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached digest, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('insights:daily', {
        'cadence': 'daily',
        'body': 'Resumen en caché.',
        'sections_count': 1,
        'patterns_count': 0,
        'correlations_count': 0,
        'generated_at': '2026-07-13T08:00:00+00:00',
      });
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpInsightsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final digest = await repo.preview();

      expect(digest.body, 'Resumen en caché.');
      expect(connectivity.calls, ['offlineWithCache']);
    });

    test('on network failure with no cached digest, still throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpInsightsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.preview(), throwsA(isA<InsightsException>()));
      expect(connectivity.calls, ['offline']);
    });

    test('daily and weekly cadences use different cache keys', () async {
      final fixture = jsonEncode({
        'cadence': 'weekly',
        'body': 'Semana.',
        'sections_count': 1,
        'patterns_count': 0,
        'correlations_count': 0,
        'generated_at': '2026-07-13T08:00:00+00:00',
      });
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final repo = HttpInsightsRepository(dio, cache: cache);

      await repo.preview(cadence: 'weekly');

      expect(await cache.get('insights:weekly'), isNotNull);
      expect(await cache.get('insights:daily'), isNull);
    });
  });
}
